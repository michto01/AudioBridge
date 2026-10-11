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

static _Thread_local char transport_error[256];
const char *ABAUTransportLastError(void) { return transport_error; }
static void failure(const char *operation, int code) {
    snprintf(transport_error, sizeof(transport_error), "%s: %s (errno %d)", operation, strerror(code), code);
}

#define AB_SHARED_VERSION 4
#define AB_SHARED_CAPACITY 65536
typedef struct { _Atomic uint32_t write, read; float samples[AB_SHARED_CAPACITY * 2]; } SharedRing;
typedef struct {
    uint32_t version, capacity;
    _Atomic bool ready, stopped, bypass;
    _Atomic int32_t fault;
    _Atomic uint32_t latency;
    _Atomic uint64_t heartbeat, processedFrames;
    _Atomic uint32_t inFlightFrames;
    _Atomic uint64_t renderBlocks, renderNanoseconds, lastRenderNanoseconds, maxRenderNanoseconds;
    _Atomic uint64_t blockBudgetNanoseconds, renderOverBudgetBlocks;
    _Atomic uint64_t workerWaits, workerLateWakeups, maxWorkerWakeLatenessNanoseconds;
    SharedRing input, output;
} Shared;
struct ABAUTransport { Shared *shared; char name[32]; bool owner; mach_timebase_info_data_t timebase; };

static bool valid_atomics(Shared *s) {
    return atomic_is_lock_free(&s->ready) && atomic_is_lock_free(&s->fault)
        && atomic_is_lock_free(&s->latency) && atomic_is_lock_free(&s->heartbeat)
        && atomic_is_lock_free(&s->inFlightFrames) && atomic_is_lock_free(&s->renderBlocks)
        && atomic_is_lock_free(&s->renderNanoseconds) && atomic_is_lock_free(&s->lastRenderNanoseconds)
        && atomic_is_lock_free(&s->maxRenderNanoseconds)
        && atomic_is_lock_free(&s->blockBudgetNanoseconds) && atomic_is_lock_free(&s->renderOverBudgetBlocks)
        && atomic_is_lock_free(&s->workerWaits) && atomic_is_lock_free(&s->workerLateWakeups)
        && atomic_is_lock_free(&s->maxWorkerWakeLatenessNanoseconds)
        && atomic_is_lock_free(&s->input.write) && atomic_is_lock_free(&s->output.read);
}
static ABAUTransport *map_transport(const char *name, bool create, uint32_t capacity) {
    transport_error[0] = 0;
    if (!name || name[0] != '/' || strlen(name) >= 32) { failure("shared-memory name", EINVAL); return NULL; }
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
        atomic_init(&s->bypass, false);
        atomic_init(&s->latency, 0); atomic_init(&s->heartbeat, 0); atomic_init(&s->processedFrames, 0);
        atomic_init(&s->inFlightFrames, 0); atomic_init(&s->renderBlocks, 0);
        atomic_init(&s->renderNanoseconds, 0); atomic_init(&s->lastRenderNanoseconds, 0); atomic_init(&s->maxRenderNanoseconds, 0);
        atomic_init(&s->blockBudgetNanoseconds, 0); atomic_init(&s->renderOverBudgetBlocks, 0);
        atomic_init(&s->workerWaits, 0); atomic_init(&s->workerLateWakeups, 0); atomic_init(&s->maxWorkerWakeLatenessNanoseconds, 0);
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
    if (mach_timebase_info(&transport->timebase) != KERN_SUCCESS || !transport->timebase.denom) {
        failure("clock timebase", EINVAL); munmap(s, sizeof(*s)); free(transport); if (create) shm_unlink(name); return NULL;
    }
    return transport;
}
ABAUTransport *ABAUTransportCreate(const char *name, uint32_t capacity) { return map_transport(name, true, capacity); }
ABAUTransport *ABAUTransportOpen(const char *name) { return map_transport(name, false, 0); }
void ABAUTransportUnlink(ABAUTransport *t) { if (t && t->owner) { shm_unlink(t->name); t->owner = false; } }
void ABAUTransportClose(ABAUTransport *t) { if (t) { ABAUTransportUnlink(t); munmap(t->shared, sizeof(Shared)); free(t); } }
void ABAUTransportShutdown(ABAUTransport *t) { atomic_store_explicit(&t->shared->stopped, true, memory_order_release); }
bool ABAUTransportStopped(const ABAUTransport *t) { return atomic_load_explicit(&t->shared->stopped, memory_order_acquire); }
uint64_t ABAUTransportProcessedFrames(const ABAUTransport *t) { return atomic_load_explicit(&t->shared->processedFrames, memory_order_relaxed); }
void ABAUTransportSetBypass(ABAUTransport *t, bool bypass) { atomic_store_explicit(&t->shared->bypass, bypass, memory_order_release); }
bool ABAUTransportBypassed(const ABAUTransport *t) { return atomic_load_explicit(&t->shared->bypass, memory_order_acquire); }
void ABAUTransportReady(ABAUTransport *t, float latency) {
    uint32_t bits; memcpy(&bits, &latency, sizeof(bits)); atomic_store(&t->shared->latency, bits);
    atomic_store_explicit(&t->shared->ready, true, memory_order_release);
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
    for (uint32_t i = 0; i < count; ++i) {
        uint32_t slot = ((write + i) & (capacity - 1)) * 2;
        r->samples[slot] = samples[i * 2]; r->samples[slot + 1] = samples[i * 2 + 1];
    }
    atomic_store_explicit(&r->write, write + count, memory_order_release); return count;
}
static uint32_t read_ring(SharedRing *r, uint32_t capacity, float *samples, uint32_t frames) {
    uint32_t read = atomic_load_explicit(&r->read, memory_order_relaxed);
    uint32_t write = atomic_load_explicit(&r->write, memory_order_acquire);
    uint32_t count = frames < write - read ? frames : write - read;
    for (uint32_t i = 0; i < count; ++i) {
        uint32_t slot = ((read + i) & (capacity - 1)) * 2;
        samples[i * 2] = r->samples[slot]; samples[i * 2 + 1] = r->samples[slot + 1];
    }
    if (count < frames) memset(samples + count * 2, 0, (size_t)(frames - count) * 2 * sizeof(float));
    atomic_store_explicit(&r->read, read + count, memory_order_release); return count;
}
uint32_t ABAUCaptureWrite(ABAUTransport *t, const float *s, uint32_t n) { return write_ring(&t->shared->input, t->shared->capacity, s, n); }
uint32_t ABAUOutputRead(ABAUTransport *t, float *s, uint32_t n) { return read_ring(&t->shared->output, t->shared->capacity, s, n); }
uint32_t ABAUWorkerRead(ABAUTransport *t, float *s, uint32_t n) { return read_ring(&t->shared->input, t->shared->capacity, s, n); }
uint32_t ABAUWorkerWrite(ABAUTransport *t, const float *s, uint32_t n) {
    uint32_t written = write_ring(&t->shared->output, t->shared->capacity, s, n);
    atomic_fetch_add_explicit(&t->shared->processedFrames, written, memory_order_relaxed); return written;
}
uint32_t ABAUWorkerSpace(const ABAUTransport *t) { return t->shared->capacity - available(&t->shared->output, t->shared->capacity); }
ABAUQueueMetrics ABAUTransportQueues(const ABAUTransport *t) {
    const Shared *s = t->shared;
    return (ABAUQueueMetrics){ .inputFrames = available(&s->input, s->capacity),
        .outputFrames = available(&s->output, s->capacity),
        .inFlightFrames = atomic_load_explicit(&s->inFlightFrames, memory_order_relaxed) };
}
ABAUTransportMetrics ABAUTransportSnapshot(const ABAUTransport *t) {
    const Shared *s = t->shared; ABAUTransportMetrics result = {0};
    result.ready = atomic_load_explicit(&s->ready, memory_order_acquire);
    result.stopped = atomic_load_explicit(&s->stopped, memory_order_acquire);
    result.bypassed = atomic_load_explicit(&s->bypass, memory_order_acquire);
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
    result.inputFrames = available(&s->input, s->capacity); result.outputFrames = available(&s->output, s->capacity);
    uint32_t bits = atomic_load(&s->latency); memcpy(&result.latencySeconds, &bits, sizeof(bits)); return result;
}
uint64_t ABAUTransportBeginBlock(ABAUTransport *t, uint32_t frames) {
    atomic_store_explicit(&t->shared->inFlightFrames, frames, memory_order_relaxed);
    return mach_absolute_time();
}
void ABAUTransportEndBlock(ABAUTransport *t, uint64_t start) {
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
    atomic_fetch_add_explicit(&s->workerWaits, 1, memory_order_relaxed);
    if (lateness > atomic_load_explicit(&s->maxWorkerWakeLatenessNanoseconds, memory_order_relaxed))
        atomic_store_explicit(&s->maxWorkerWakeLatenessNanoseconds, lateness, memory_order_relaxed);
    uint64_t budget = atomic_load_explicit(&s->blockBudgetNanoseconds, memory_order_relaxed);
    if (budget && lateness > budget)
        atomic_fetch_add_explicit(&s->workerLateWakeups, 1, memory_order_relaxed);
}
void ABAUTransportWorkerWait(ABAUTransport *t, uint32_t microseconds) {
    uint64_t start = mach_absolute_time();
    usleep(microseconds);
    uint64_t elapsed = (uint64_t)((long double)(mach_absolute_time() - start) * t->timebase.numer / t->timebase.denom);
    ABAUTransportRecordWorkerWait(t, (uint64_t)microseconds * 1000, elapsed);
}
