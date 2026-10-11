#include "AUTransport.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

#define AB_SHARED_VERSION 1
#define AB_SHARED_CAPACITY 65536
typedef struct { _Atomic uint32_t write, read; float samples[AB_SHARED_CAPACITY * 2]; } SharedRing;
typedef struct {
    uint32_t version, capacity;
    _Atomic bool ready, stopped;
    _Atomic int32_t fault;
    _Atomic uint32_t latency;
    _Atomic uint64_t heartbeat, processedFrames;
    SharedRing input, output;
} Shared;
struct ABAUTransport { Shared *shared; char name[32]; bool owner; };

static bool valid_atomics(Shared *s) {
    return atomic_is_lock_free(&s->ready) && atomic_is_lock_free(&s->fault)
        && atomic_is_lock_free(&s->latency) && atomic_is_lock_free(&s->heartbeat)
        && atomic_is_lock_free(&s->input.write) && atomic_is_lock_free(&s->output.read);
}
static ABAUTransport *map_transport(const char *name, bool create, uint32_t capacity) {
    if (!name || name[0] != '/' || strlen(name) >= 32) return NULL;
    if (create && (capacity < 2 || capacity > AB_SHARED_CAPACITY || (capacity & (capacity - 1)))) return NULL;
    int fd = shm_open(name, create ? O_CREAT | O_EXCL | O_RDWR : O_RDWR, 0600);
    if (fd < 0) return NULL;
    if (create && ftruncate(fd, sizeof(Shared)) != 0) { close(fd); shm_unlink(name); return NULL; }
    struct stat facts;
    if (fstat(fd, &facts) != 0 || facts.st_size != sizeof(Shared)) { close(fd); if (create) shm_unlink(name); return NULL; }
    Shared *s = mmap(NULL, sizeof(Shared), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (s == MAP_FAILED) { if (create) shm_unlink(name); return NULL; }
    if (create) {
        memset(s, 0, sizeof(*s)); s->version = AB_SHARED_VERSION; s->capacity = capacity;
        atomic_init(&s->ready, false); atomic_init(&s->stopped, false); atomic_init(&s->fault, 0);
        atomic_init(&s->latency, 0); atomic_init(&s->heartbeat, 0); atomic_init(&s->processedFrames, 0);
        atomic_init(&s->input.write, 0); atomic_init(&s->input.read, 0);
        atomic_init(&s->output.write, 0); atomic_init(&s->output.read, 0);
    }
    if (s->version != AB_SHARED_VERSION || s->capacity < 2 || s->capacity > AB_SHARED_CAPACITY
        || (s->capacity & (s->capacity - 1)) || !valid_atomics(s)) {
        munmap(s, sizeof(*s)); if (create) shm_unlink(name); return NULL;
    }
    ABAUTransport *transport = calloc(1, sizeof(*transport));
    if (!transport) { munmap(s, sizeof(*s)); if (create) shm_unlink(name); return NULL; }
    transport->shared = s; transport->owner = create; strcpy(transport->name, name);
    return transport;
}
ABAUTransport *ABAUTransportCreate(const char *name, uint32_t capacity) { return map_transport(name, true, capacity); }
ABAUTransport *ABAUTransportOpen(const char *name) { return map_transport(name, false, 0); }
void ABAUTransportUnlink(ABAUTransport *t) { if (t && t->owner) { shm_unlink(t->name); t->owner = false; } }
void ABAUTransportClose(ABAUTransport *t) { if (t) { ABAUTransportUnlink(t); munmap(t->shared, sizeof(Shared)); free(t); } }
void ABAUTransportShutdown(ABAUTransport *t) { atomic_store_explicit(&t->shared->stopped, true, memory_order_release); }
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
ABAUTransportMetrics ABAUTransportSnapshot(const ABAUTransport *t) {
    const Shared *s = t->shared; ABAUTransportMetrics result = {0};
    result.ready = atomic_load_explicit(&s->ready, memory_order_acquire);
    result.stopped = atomic_load_explicit(&s->stopped, memory_order_acquire);
    result.fault = atomic_load_explicit(&s->fault, memory_order_acquire);
    result.heartbeat = atomic_load_explicit(&s->heartbeat, memory_order_relaxed);
    result.processedFrames = atomic_load_explicit(&s->processedFrames, memory_order_relaxed);
    result.inputFrames = available(&s->input, s->capacity); result.outputFrames = available(&s->output, s->capacity);
    uint32_t bits = atomic_load(&s->latency); memcpy(&result.latencySeconds, &bits, sizeof(bits)); return result;
}
