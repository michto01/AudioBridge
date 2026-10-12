#include "AUTransport.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <mach/mach_time.h>
#include <mach/mach.h>
#include <mach/thread_policy.h>
#include <semaphore.h>
#include <AudioToolbox/AudioToolbox.h>
#include <os/workgroup.h>

static _Thread_local char transport_error[256];
const char *ABAUTransportLastError(void) { return transport_error; }
static void failure(const char *operation, int code) {
    snprintf(transport_error, sizeof(transport_error), "%s: %s (errno %d)", operation, strerror(code), code);
}

#define AB_SHARED_VERSION 7
uint32_t ABAUTransportProtocolVersion(void) { return AB_SHARED_VERSION; }
#define AB_SHARED_CAPACITY 65536
typedef struct { _Atomic uint32_t write, read; float samples[AB_SHARED_CAPACITY * 2]; } SharedRing;
typedef struct { _Atomic uint64_t identity, blocks, total, maximum, overBudget; } StageTiming;
typedef struct {
    uint32_t version, capacity;
    _Atomic bool ready, stopped, bypass, effectsProcessingEnabled, latencyChanged;
    _Atomic int32_t fault;
    _Atomic uint32_t latency;
    _Atomic uint64_t heartbeat, processedFrames;
    _Atomic uint32_t inFlightFrames;
    _Atomic uint64_t renderBlocks, renderNanoseconds, lastRenderNanoseconds, maxRenderNanoseconds;
    _Atomic uint64_t blockBudgetNanoseconds, renderOverBudgetBlocks;
    _Atomic uint64_t workerWaits, workerLateWakeups, maxWorkerWakeLatenessNanoseconds;
    _Atomic bool workerWaiting;
    _Atomic uint32_t workerBlockFrames;
    _Atomic uint64_t workerSignalTime;
    _Atomic int32_t schedulingStatus, workgroupStatus;
    _Atomic uint64_t workgroupIntervalFailures;
    _Atomic int32_t renderingStage;
    _Atomic uint64_t lastWakeNanoseconds;
    StageTiming stages[8];
    _Atomic uint64_t lossSequence, lostFrames, lossRender, lossWake;
    _Atomic uint32_t lossCapture, lossReady, lossInFlight;
    _Atomic int32_t lossStage;
    SharedRing input, output;
} Shared;
struct ABAUTransport { Shared *shared; char name[32], eventName[32]; sem_t *event; bool owner; mach_timebase_info_data_t timebase;
    os_workgroup_interval_t workgroup;
    os_workgroup_join_token_s joinToken;
    uint64_t budgetTicks;
    bool joined, intervalActive;
};

static bool valid_atomics(Shared *s) {
    return atomic_is_lock_free(&s->ready) && atomic_is_lock_free(&s->fault)
        && atomic_is_lock_free(&s->effectsProcessingEnabled)
        && atomic_is_lock_free(&s->latency) && atomic_is_lock_free(&s->heartbeat)
        && atomic_is_lock_free(&s->inFlightFrames) && atomic_is_lock_free(&s->renderBlocks)
        && atomic_is_lock_free(&s->renderNanoseconds) && atomic_is_lock_free(&s->lastRenderNanoseconds)
        && atomic_is_lock_free(&s->maxRenderNanoseconds)
        && atomic_is_lock_free(&s->blockBudgetNanoseconds) && atomic_is_lock_free(&s->renderOverBudgetBlocks)
        && atomic_is_lock_free(&s->workerWaits) && atomic_is_lock_free(&s->workerLateWakeups)
        && atomic_is_lock_free(&s->maxWorkerWakeLatenessNanoseconds)
        && atomic_is_lock_free(&s->workerWaiting) && atomic_is_lock_free(&s->workerBlockFrames)
        && atomic_is_lock_free(&s->workerSignalTime) && atomic_is_lock_free(&s->schedulingStatus)
        && atomic_is_lock_free(&s->renderingStage) && atomic_is_lock_free(&s->lossSequence)
        && atomic_is_lock_free(&s->stages[0].blocks) && atomic_is_lock_free(&s->lossCapture)
        && atomic_is_lock_free(&s->input.write) && atomic_is_lock_free(&s->output.read);
}
static ABAUTransport *map_transport(const char *name, bool create, uint32_t capacity) {
    transport_error[0] = 0;
    if (!name || name[0] != '/' || strlen(name) >= 31) { failure("shared-memory name", EINVAL); return NULL; }
    if (create && (capacity < 2 || capacity > AB_SHARED_CAPACITY || (capacity & (capacity - 1)))) { failure("queue capacity", EINVAL); return NULL; }
    int fd = shm_open(name, create ? O_CREAT | O_EXCL | O_RDWR : O_RDWR, 0600);
    if (fd < 0) { failure("shm_open", errno); return NULL; }
    long page = sysconf(_SC_PAGESIZE);
    size_t mappedSize = page > 0 ? ((sizeof(Shared) + page - 1) / page) * page : sizeof(Shared);
    if (create && ftruncate(fd, mappedSize) != 0) { failure("ftruncate", errno); close(fd); shm_unlink(name); return NULL; }
    struct stat facts;
    if (fstat(fd, &facts) != 0) { failure("fstat", errno); close(fd); if (create) shm_unlink(name); return NULL; }
    if (facts.st_size < sizeof(Shared) || facts.st_size > mappedSize) { failure("mapping size", EINVAL); close(fd); if (create) shm_unlink(name); return NULL; }
    Shared *s = mmap(NULL, sizeof(Shared), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    int mapError = errno;
    close(fd);
    if (s == MAP_FAILED) { failure("mmap", mapError); if (create) shm_unlink(name); return NULL; }
    if (create) {
        memset(s, 0, sizeof(*s)); s->version = AB_SHARED_VERSION; s->capacity = capacity;
        atomic_init(&s->ready, false); atomic_init(&s->stopped, false); atomic_init(&s->fault, 0);
        atomic_init(&s->bypass, false); atomic_init(&s->latencyChanged, false);
        atomic_init(&s->effectsProcessingEnabled, true);
        atomic_init(&s->latency, 0); atomic_init(&s->heartbeat, 0); atomic_init(&s->processedFrames, 0);
        atomic_init(&s->inFlightFrames, 0); atomic_init(&s->renderBlocks, 0);
        atomic_init(&s->renderNanoseconds, 0); atomic_init(&s->lastRenderNanoseconds, 0); atomic_init(&s->maxRenderNanoseconds, 0);
        atomic_init(&s->blockBudgetNanoseconds, 0); atomic_init(&s->renderOverBudgetBlocks, 0);
        atomic_init(&s->workerWaits, 0); atomic_init(&s->workerLateWakeups, 0); atomic_init(&s->maxWorkerWakeLatenessNanoseconds, 0);
        atomic_init(&s->workerWaiting, false); atomic_init(&s->workerBlockFrames, 0);
        atomic_init(&s->workerSignalTime, 0); atomic_init(&s->schedulingStatus, -1);
        atomic_init(&s->workgroupStatus, -1); atomic_init(&s->workgroupIntervalFailures, 0);
        atomic_init(&s->renderingStage, -1); atomic_init(&s->lastWakeNanoseconds, 0);
        atomic_init(&s->lossSequence, 0); atomic_init(&s->lostFrames, 0);
        atomic_init(&s->lossRender, 0); atomic_init(&s->lossWake, 0);
        atomic_init(&s->lossCapture, 0); atomic_init(&s->lossReady, 0);
        atomic_init(&s->lossInFlight, 0); atomic_init(&s->lossStage, -1);
        for (uint32_t i = 0; i < 8; i++) {
            atomic_init(&s->stages[i].identity, 0); atomic_init(&s->stages[i].blocks, 0); atomic_init(&s->stages[i].total, 0);
            atomic_init(&s->stages[i].maximum, 0); atomic_init(&s->stages[i].overBudget, 0);
        }
        atomic_init(&s->input.write, 0); atomic_init(&s->input.read, 0);
        atomic_init(&s->output.write, 0); atomic_init(&s->output.read, 0);
    }
    if (s->version != AB_SHARED_VERSION || s->capacity < 2 || s->capacity > AB_SHARED_CAPACITY
        || (s->capacity & (s->capacity - 1)) || !valid_atomics(s)) {
        failure("shared header or lock-free atomics", EINVAL); munmap(s, sizeof(*s)); if (create) shm_unlink(name); return NULL;
    }
    ABAUTransport *transport = calloc(1, sizeof(*transport));
    if (!transport) { failure("transport allocation", ENOMEM); munmap(s, sizeof(*s)); if (create) shm_unlink(name); return NULL; }
    transport->shared = s; transport->owner = create; strcpy(transport->name, name);
    snprintf(transport->eventName, sizeof(transport->eventName), "%se", name);
    transport->event = sem_open(transport->eventName, create ? O_CREAT | O_EXCL : 0, 0600, 0);
    if (transport->event == SEM_FAILED) {
        failure("worker event", errno); munmap(s, sizeof(*s)); free(transport); if (create) shm_unlink(name); return NULL;
    }
    if (mach_timebase_info(&transport->timebase) != KERN_SUCCESS || !transport->timebase.denom) {
        failure("clock timebase", EINVAL); sem_close(transport->event);
        if (create) sem_unlink(transport->eventName);
        munmap(s, sizeof(*s)); free(transport); if (create) shm_unlink(name); return NULL;
    }
    return transport;
}
ABAUTransport *ABAUTransportCreate(const char *name, uint32_t capacity) { return map_transport(name, true, capacity); }
ABAUTransport *ABAUTransportOpen(const char *name) { return map_transport(name, false, 0); }
void ABAUTransportUnlink(ABAUTransport *t) { if (t && t->owner) { shm_unlink(t->name); sem_unlink(t->eventName); t->owner = false; } }
void ABAUTransportClose(ABAUTransport *t) { if (t) { ABAUTransportUnlink(t); sem_close(t->event); munmap(t->shared, sizeof(Shared)); free(t); } }
static void notify_worker(ABAUTransport *t);
void ABAUTransportShutdown(ABAUTransport *t) {
    atomic_store_explicit(&t->shared->stopped, true, memory_order_release); notify_worker(t);
}
bool ABAUTransportStopped(const ABAUTransport *t) { return atomic_load_explicit(&t->shared->stopped, memory_order_acquire); }
uint64_t ABAUTransportProcessedFrames(const ABAUTransport *t) { return atomic_load_explicit(&t->shared->processedFrames, memory_order_relaxed); }
void ABAUTransportSetBypass(ABAUTransport *t, bool bypass) { atomic_store_explicit(&t->shared->bypass, bypass, memory_order_release); }
bool ABAUTransportBypassed(const ABAUTransport *t) { return atomic_load_explicit(&t->shared->bypass, memory_order_acquire); }
void ABAUTransportSetEffectsProcessingEnabled(ABAUTransport *t, bool enabled) {
    atomic_store_explicit(&t->shared->effectsProcessingEnabled, enabled, memory_order_release);
}
bool ABAUTransportEffectsProcessingEnabled(const ABAUTransport *t) {
    return atomic_load_explicit(&t->shared->effectsProcessingEnabled, memory_order_acquire);
}
void ABAUTransportReady(ABAUTransport *t, float latency) {
    ABAUTransportSetLatency(t, latency);
    atomic_store_explicit(&t->shared->ready, true, memory_order_release);
}
void ABAUTransportSetLatency(ABAUTransport *t, float latency) {
    uint32_t bits; memcpy(&bits, &latency, sizeof(bits)); atomic_store(&t->shared->latency, bits);
}
void ABAUTransportFault(ABAUTransport *t, int32_t fault) { atomic_store_explicit(&t->shared->fault, fault ? fault : -1, memory_order_release); }
void ABAUTransportHeartbeat(ABAUTransport *t) { atomic_fetch_add_explicit(&t->shared->heartbeat, 1, memory_order_relaxed); }
static uint32_t available(const SharedRing *r, uint32_t capacity) {
    uint32_t read = atomic_load_explicit(&r->read, memory_order_acquire);
    uint32_t write = atomic_load_explicit(&r->write, memory_order_acquire);
    uint32_t count = write - read; return count > capacity ? capacity : count;
}
static uint32_t write_ring(SharedRing *r, uint32_t capacity, const float *samples, uint32_t frames) {
    uint32_t write = atomic_load_explicit(&r->write, memory_order_relaxed);
    uint32_t read = atomic_load_explicit(&r->read, memory_order_acquire);
    uint32_t space = capacity - (write - read), count = frames < space ? frames : space;
    uint32_t slot = write & (capacity - 1), first = count < capacity - slot ? count : capacity - slot;
    memcpy(r->samples + slot * 2, samples, (size_t)first * 2 * sizeof(float));
    if (count > first) memcpy(r->samples, samples + first * 2, (size_t)(count - first) * 2 * sizeof(float));
    atomic_store_explicit(&r->write, write + count, memory_order_release); return count;
}
static uint32_t read_ring(SharedRing *r, uint32_t capacity, float *samples, uint32_t frames) {
    uint32_t read = atomic_load_explicit(&r->read, memory_order_relaxed);
    uint32_t write = atomic_load_explicit(&r->write, memory_order_acquire);
    uint32_t count = frames < write - read ? frames : write - read;
    uint32_t slot = read & (capacity - 1), first = count < capacity - slot ? count : capacity - slot;
    memcpy(samples, r->samples + slot * 2, (size_t)first * 2 * sizeof(float));
    if (count > first) memcpy(samples + first * 2, r->samples, (size_t)(count - first) * 2 * sizeof(float));
    if (count < frames) memset(samples + count * 2, 0, (size_t)(frames - count) * 2 * sizeof(float));
    atomic_store_explicit(&r->read, read + count, memory_order_release); return count;
}
uint32_t ABAUCaptureWrite(ABAUTransport *t, const float *s, uint32_t n) {
    uint32_t written = write_ring(&t->shared->input, t->shared->capacity, s, n); notify_worker(t); return written;
}
uint32_t ABAUOutputRead(ABAUTransport *t, float *s, uint32_t n) {
    uint32_t read = read_ring(&t->shared->output, t->shared->capacity, s, n); notify_worker(t); return read;
}
uint32_t ABAUWorkerRead(ABAUTransport *t, float *s, uint32_t n) { return read_ring(&t->shared->input, t->shared->capacity, s, n); }
uint32_t ABAUWorkerWrite(ABAUTransport *t, const float *s, uint32_t n) {
    uint32_t written = write_ring(&t->shared->output, t->shared->capacity, s, n);
    atomic_fetch_add_explicit(&t->shared->processedFrames, written, memory_order_relaxed); return written;
}
uint32_t ABAUWorkerSpace(const ABAUTransport *t) { return t->shared->capacity - available(&t->shared->output, t->shared->capacity); }
static bool worker_can_run(const ABAUTransport *t, uint32_t frames) {
    return ABAUTransportStopped(t) || (frames && available(&t->shared->input, t->shared->capacity) >= frames
        && ABAUWorkerSpace(t) >= frames);
}
static void notify_worker(ABAUTransport *t) {
    Shared *s = t->shared;
    // Pair with the worker's arm/recheck fence: without store->load ordering
    // both threads could observe the old state and lose the only wakeup.
    atomic_thread_fence(memory_order_seq_cst);
    if (!atomic_load_explicit(&s->workerWaiting, memory_order_acquire)) return;
    uint32_t frames = atomic_load_explicit(&s->workerBlockFrames, memory_order_relaxed);
    if (!worker_can_run(t, frames)) return;
    if (atomic_exchange_explicit(&s->workerWaiting, false, memory_order_acq_rel)) {
        atomic_store_explicit(&s->workerSignalTime, mach_absolute_time(), memory_order_release);
        // Non-waiting notification only. HAL never waits on this semaphore,
        // allocates it, or acquires a userspace mutex. At most one outstanding
        // signal is allowed by the arm/consume handshake.
        if (sem_post(t->event) != 0) ABAUTransportFault(t, -1);
    }
}
bool ABAUTransportWaitForBlock(ABAUTransport *t, uint32_t frames) {
    if (!frames || frames > t->shared->capacity) return false;
    while (!worker_can_run(t, frames)) {
        atomic_store_explicit(&t->shared->workerBlockFrames, frames, memory_order_relaxed);
        atomic_store_explicit(&t->shared->workerWaiting, true, memory_order_release);
        atomic_thread_fence(memory_order_seq_cst);
        // Recheck after arming: a publication between the first check and arm
        // must not be missed. If a callback already claimed the signal, consume
        // it even if the queue is now ready, before arming another wait.
        if (worker_can_run(t, frames)) {
            bool expected = true;
            if (atomic_compare_exchange_strong_explicit(&t->shared->workerWaiting, &expected, false,
                memory_order_acq_rel, memory_order_acquire)) return !ABAUTransportStopped(t);
        }
        int result;
        do { result = sem_wait(t->event); } while (result != 0 && errno == EINTR);
        if (result != 0) { ABAUTransportFault(t, -1); return false; }
        uint64_t signaled = atomic_load_explicit(&t->shared->workerSignalTime, memory_order_acquire);
        uint64_t now = mach_absolute_time();
        uint64_t late = now >= signaled ? now - signaled : 0;
        late = (uint64_t)((long double)late * t->timebase.numer / t->timebase.denom);
        // Only signal-to-resume delay counts, not legitimate idle time.
        ABAUTransportRecordWorkerWait(t, 0, late);
    }
    return !ABAUTransportStopped(t);
}
int32_t ABAUTransportConfigureRealtimeThread(ABAUTransport *t) {
    uint64_t ns = atomic_load_explicit(&t->shared->blockBudgetNanoseconds, memory_order_relaxed);
    uint64_t ticks = (uint64_t)((long double)ns * t->timebase.denom / t->timebase.numer);
    kern_return_t status = KERN_INVALID_ARGUMENT;
    if (ticks >= 2 && ticks <= UINT32_MAX) {
        thread_time_constraint_policy_data_t policy = {
            .period = (uint32_t)ticks, .computation = (uint32_t)(ticks / 2),
            .constraint = (uint32_t)ticks, .preemptible = TRUE
        };
        thread_t thread = mach_thread_self();
        status = thread_policy_set(thread, THREAD_TIME_CONSTRAINT_POLICY,
            (thread_policy_t)&policy, THREAD_TIME_CONSTRAINT_POLICY_COUNT);
        mach_port_deallocate(mach_task_self(), thread);
    }
    atomic_store_explicit(&t->shared->schedulingStatus, status, memory_order_release);
    t->budgetTicks = ticks;
    // This worker renders ahead through bounded queues, independently of both
    // device IOProcs. Use Apple's asynchronous audio workgroup, not either
    // device's parallel group. Setup is complete before parent starts HAL.
    int groupStatus = status == KERN_SUCCESS ? ENOMEM : EPERM;
    if (status == KERN_SUCCESS) {
        t->workgroup = AudioWorkIntervalCreate("AudioBridge AU processing", OS_CLOCK_MACH_ABSOLUTE_TIME, NULL);
        if (t->workgroup) {
            groupStatus = os_workgroup_join((os_workgroup_t)t->workgroup, &t->joinToken);
            t->joined = groupStatus == 0;
        }
    }
    atomic_store_explicit(&t->shared->workgroupStatus, groupStatus, memory_order_release);
    return status;
}
static uint32_t pending_frames(const Shared *s) {
    // Same frame domain: captures accepted minus source frames consumed/discarded.
    // AU transfer changes neither counter. Unsigned subtraction handles wrap.
    // In the output callback, read cannot advance during this snapshot.
    uint32_t consumed = atomic_load_explicit(&s->output.read, memory_order_acquire);
    uint32_t captured = atomic_load_explicit(&s->input.write, memory_order_acquire);
    uint32_t pending = captured - consumed;
    uint32_t limit = s->capacity * 2 + 1024;
    return pending > limit ? limit : pending; // Third-party UI snapshots may span consumption.
}
ABAUQueueMetrics ABAUTransportQueues(const ABAUTransport *t) {
    const Shared *s = t->shared;
    return (ABAUQueueMetrics){ .inputFrames = available(&s->input, s->capacity),
        .outputFrames = available(&s->output, s->capacity),
        .inFlightFrames = atomic_load_explicit(&s->inFlightFrames, memory_order_relaxed),
        .pendingFrames = pending_frames(s) };
}
ABAUTransportMetrics ABAUTransportSnapshot(const ABAUTransport *t) {
    const Shared *s = t->shared; ABAUTransportMetrics result = {0};
    result.workgroupStatus = atomic_load_explicit(&s->workgroupStatus, memory_order_acquire);
    result.workgroupIntervalFailures = atomic_load_explicit(&s->workgroupIntervalFailures, memory_order_relaxed);
    result.ready = atomic_load_explicit(&s->ready, memory_order_acquire);
    result.stopped = atomic_load_explicit(&s->stopped, memory_order_acquire);
    result.bypassed = atomic_load_explicit(&s->bypass, memory_order_acquire);
    result.effectsProcessingEnabled = atomic_load_explicit(&s->effectsProcessingEnabled, memory_order_acquire);
    result.fault = atomic_load_explicit(&s->fault, memory_order_acquire);
    result.heartbeat = atomic_load_explicit(&s->heartbeat, memory_order_relaxed);
    result.processedFrames = atomic_load_explicit(&s->processedFrames, memory_order_relaxed);
    result.inFlightFrames = atomic_load_explicit(&s->inFlightFrames, memory_order_relaxed);
    result.renderBlocks = atomic_load_explicit(&s->renderBlocks, memory_order_relaxed);
    result.renderNanoseconds = atomic_load_explicit(&s->renderNanoseconds, memory_order_relaxed);
    result.lastRenderNanoseconds = atomic_load_explicit(&s->lastRenderNanoseconds, memory_order_relaxed);
    result.maxRenderNanoseconds = atomic_load_explicit(&s->maxRenderNanoseconds, memory_order_relaxed);
    result.blockBudgetNanoseconds = atomic_load_explicit(&s->blockBudgetNanoseconds, memory_order_relaxed);
    result.renderOverBudgetBlocks = atomic_load_explicit(&s->renderOverBudgetBlocks, memory_order_relaxed);
    result.workerWaits = atomic_load_explicit(&s->workerWaits, memory_order_relaxed);
    result.workerLateWakeups = atomic_load_explicit(&s->workerLateWakeups, memory_order_relaxed);
    result.maxWorkerWakeLatenessNanoseconds = atomic_load_explicit(&s->maxWorkerWakeLatenessNanoseconds, memory_order_relaxed);
    result.schedulingStatus = atomic_load_explicit(&s->schedulingStatus, memory_order_acquire);
    result.inputFrames = available(&s->input, s->capacity); result.outputFrames = available(&s->output, s->capacity);
    result.pendingFrames = pending_frames(s);
    uint32_t bits = atomic_load(&s->latency); memcpy(&result.latencySeconds, &bits, sizeof(bits));
    if (!result.effectsProcessingEnabled || result.bypassed) result.latencySeconds = 0;
    return result;
}
uint64_t ABAUTransportBeginBlock(ABAUTransport *t, uint32_t frames) {
    atomic_store_explicit(&t->shared->inFlightFrames, frames, memory_order_relaxed);
    uint64_t start = mach_absolute_time();
    if (t->joined) {
        int result = os_workgroup_interval_start(t->workgroup, start, start + t->budgetTicks, NULL);
        t->intervalActive = result == 0;
        if (result) atomic_fetch_add_explicit(&t->shared->workgroupIntervalFailures, 1, memory_order_relaxed);
    }
    return start;
}
void ABAUTransportEndBlock(ABAUTransport *t, uint64_t start) {
    if (t->intervalActive) {
        int result = os_workgroup_interval_finish(t->workgroup, NULL);
        if (result) atomic_fetch_add_explicit(&t->shared->workgroupIntervalFailures, 1, memory_order_relaxed);
        t->intervalActive = false;
    }
    uint64_t duration = (uint64_t)((long double)(mach_absolute_time() - start) * t->timebase.numer / t->timebase.denom);
    ABAUTransportRecordRenderDuration(t, duration);
    atomic_store_explicit(&t->shared->inFlightFrames, 0, memory_order_relaxed);
}
void ABAUTransportConfigureTiming(ABAUTransport *t, uint64_t budget) {
    atomic_store_explicit(&t->shared->blockBudgetNanoseconds, budget, memory_order_relaxed);
}
void ABAUTransportRecordRenderDuration(ABAUTransport *t, uint64_t duration) {
    Shared *s = t->shared;
    atomic_store_explicit(&s->lastRenderNanoseconds, duration, memory_order_relaxed);
    if (duration > atomic_load_explicit(&s->maxRenderNanoseconds, memory_order_relaxed))
        atomic_store_explicit(&s->maxRenderNanoseconds, duration, memory_order_relaxed);
    atomic_fetch_add_explicit(&s->renderNanoseconds, duration, memory_order_relaxed);
    atomic_fetch_add_explicit(&s->renderBlocks, 1, memory_order_relaxed);
    uint64_t budget = atomic_load_explicit(&s->blockBudgetNanoseconds, memory_order_relaxed);
    if (budget && duration > budget)
        atomic_fetch_add_explicit(&s->renderOverBudgetBlocks, 1, memory_order_relaxed);
}
void ABAUTransportRecordWorkerWait(ABAUTransport *t, uint64_t requested, uint64_t elapsed) {
    Shared *s = t->shared;
    uint64_t lateness = elapsed > requested ? elapsed - requested : 0;
    atomic_store_explicit(&s->lastWakeNanoseconds, lateness, memory_order_relaxed);
    atomic_fetch_add_explicit(&s->workerWaits, 1, memory_order_relaxed);
    if (lateness > atomic_load_explicit(&s->maxWorkerWakeLatenessNanoseconds, memory_order_relaxed))
        atomic_store_explicit(&s->maxWorkerWakeLatenessNanoseconds, lateness, memory_order_relaxed);
    uint64_t budget = atomic_load_explicit(&s->blockBudgetNanoseconds, memory_order_relaxed);
    if (budget && lateness > budget)
        atomic_fetch_add_explicit(&s->workerLateWakeups, 1, memory_order_relaxed);
}

// Host musical-position callbacks only need these three atomics, not a UI snapshot.
bool ABAUTransportMoving(const ABAUTransport *t) {
    const Shared *s = t->shared;
    return atomic_load_explicit(&s->ready, memory_order_acquire)
        && !atomic_load_explicit(&s->stopped, memory_order_acquire)
        && !atomic_load_explicit(&s->fault, memory_order_acquire);
}
uint64_t ABAUTransportBeginStage(ABAUTransport *t, uint32_t index, uint64_t identity) {
    if (index >= 8) return mach_absolute_time();
    StageTiming *stage = &t->shared->stages[index];
    if (atomic_load_explicit(&stage->identity, memory_order_relaxed) != identity) {
        atomic_store(&stage->identity, 0); // Suppress attribution during replacement.
        atomic_store(&stage->blocks, 0); atomic_store(&stage->total, 0);
        atomic_store(&stage->maximum, 0); atomic_store(&stage->overBudget, 0);
        atomic_store_explicit(&stage->identity, identity, memory_order_release);
    }
    atomic_store_explicit(&t->shared->renderingStage, (int32_t)index, memory_order_relaxed);
    return mach_absolute_time();
}
void ABAUTransportEndStage(ABAUTransport *t, uint32_t index, uint64_t start) {
    if (index >= 8) return;
    uint64_t duration = (uint64_t)((long double)(mach_absolute_time() - start) * t->timebase.numer / t->timebase.denom);
    StageTiming *stage = &t->shared->stages[index];
    atomic_fetch_add_explicit(&stage->blocks, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&stage->total, duration, memory_order_relaxed);
    if (duration > atomic_load_explicit(&stage->maximum, memory_order_relaxed))
        atomic_store_explicit(&stage->maximum, duration, memory_order_relaxed);
    if (duration > atomic_load_explicit(&t->shared->blockBudgetNanoseconds, memory_order_relaxed))
        atomic_fetch_add_explicit(&stage->overBudget, 1, memory_order_relaxed);
    atomic_store_explicit(&t->shared->renderingStage, -1, memory_order_relaxed);
}
ABAUStageMetrics ABAUTransportStageMetrics(const ABAUTransport *t, uint32_t index) {
    if (index >= 8) return (ABAUStageMetrics){0};
    const StageTiming *stage = &t->shared->stages[index];
    uint64_t identity = atomic_load_explicit(&stage->identity, memory_order_acquire);
    ABAUStageMetrics result = { identity, atomic_load(&stage->blocks), atomic_load(&stage->total),
        atomic_load(&stage->maximum), atomic_load(&stage->overBudget) };
    return identity == atomic_load_explicit(&stage->identity, memory_order_acquire) ? result : (ABAUStageMetrics){0};
}
void ABAUTransportRecordStarvation(ABAUTransport *t, uint32_t lost) {
    // Latest bounded event, not a log. All payload fields are atomic: the
    // lifecycle reader can overlap without racing or making HAL wait.
    Shared *s = t->shared;
    atomic_fetch_add_explicit(&s->lossSequence, 1, memory_order_seq_cst);
    atomic_store_explicit(&s->lostFrames, lost, memory_order_seq_cst);
    atomic_store_explicit(&s->lossCapture, available(&s->input, s->capacity), memory_order_seq_cst);
    atomic_store_explicit(&s->lossReady, available(&s->output, s->capacity), memory_order_seq_cst);
    atomic_store_explicit(&s->lossInFlight, atomic_load(&s->inFlightFrames), memory_order_seq_cst);
    atomic_store_explicit(&s->lossStage, atomic_load(&s->renderingStage), memory_order_seq_cst);
    atomic_store_explicit(&s->lossRender, atomic_load(&s->lastRenderNanoseconds), memory_order_seq_cst);
    atomic_store_explicit(&s->lossWake, atomic_load(&s->lastWakeNanoseconds), memory_order_seq_cst);
    atomic_fetch_add_explicit(&s->lossSequence, 1, memory_order_seq_cst);
}
ABAUStarvationMetrics ABAUTransportStarvation(const ABAUTransport *t) {
    const Shared *s = t->shared;
    uint64_t sequence = atomic_load_explicit(&s->lossSequence, memory_order_seq_cst);
    if (sequence & 1) return (ABAUStarvationMetrics){0};
    ABAUStarvationMetrics event = { .sequence = sequence / 2,
        .lostFrames = atomic_load(&s->lostFrames), .captureFrames = atomic_load(&s->lossCapture),
        .readyFrames = atomic_load(&s->lossReady), .inFlightFrames = atomic_load(&s->lossInFlight),
        .renderingStage = atomic_load(&s->lossStage), .lastRenderNanoseconds = atomic_load(&s->lossRender),
        .lastWakeNanoseconds = atomic_load(&s->lossWake) };
    return sequence == atomic_load_explicit(&s->lossSequence, memory_order_seq_cst) ? event : (ABAUStarvationMetrics){0};
}

void ABAUTransportLatencyChanged(ABAUTransport *t) {
    atomic_store_explicit(&t->shared->latencyChanged, true, memory_order_release);
}
bool ABAUTransportTakeLatencyChange(ABAUTransport *t) {
    return atomic_exchange_explicit(&t->shared->latencyChanged, false, memory_order_acq_rel);
}

const void *ABAUTransportWorkgroup(const ABAUTransport *t) {
    return t->joined ? t->workgroup : NULL;
}
void ABAUTransportFinishRealtimeThread(ABAUTransport *t) {
    // Must run on the same dedicated thread that joined, after its last block.
    if (t->intervalActive) { int result = os_workgroup_interval_finish(t->workgroup, NULL); (void)result; }
    if (t->joined) os_workgroup_leave((os_workgroup_t)t->workgroup, &t->joinToken);
    if (t->workgroup) os_release(t->workgroup);
    t->intervalActive = false; t->joined = false; t->workgroup = NULL;
}
