#include "AudioBridgeRealtime.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct ABRing {
    float *samples;
    uint32_t capacity;
    _Atomic uint32_t write;
    _Atomic uint32_t read;
};
ABRing *ABRingCreate(uint32_t capacity) {
    if (capacity < 2 || capacity > 65536 || (capacity & (capacity - 1))) return NULL;
    ABRing *ring = calloc(1, sizeof(*ring));
    if (!ring) return NULL;
    ring->samples = calloc((size_t)capacity * 2, sizeof(float));
    if (!ring->samples) { free(ring); return NULL; }
    ring->capacity = capacity;
    atomic_init(&ring->write, 0); atomic_init(&ring->read, 0);
    if (!atomic_is_lock_free(&ring->write) || !atomic_is_lock_free(&ring->read)) {
        ABRingDestroy(ring); return NULL;
    }
    return ring;
}
void ABRingDestroy(ABRing *ring) {
    if (ring) { free(ring->samples); free(ring); }
}
uint32_t ABRingAvailable(const ABRing *ring) {
    // UI snapshots are approximate. Clamp a mixed-generation read/write pair.
    uint32_t read = atomic_load_explicit(&ring->read, memory_order_acquire);
    uint32_t write = atomic_load_explicit(&ring->write, memory_order_acquire);
    uint32_t available = write - read;
    return available > ring->capacity ? ring->capacity : available;
}
uint32_t ABRingWrite(ABRing *ring, const float *stereo, uint32_t frames) {
    uint32_t write = atomic_load_explicit(&ring->write, memory_order_relaxed);
    uint32_t read = atomic_load_explicit(&ring->read, memory_order_acquire);
    uint32_t space = ring->capacity - (write - read);
    uint32_t count = frames < space ? frames : space;
    for (uint32_t i = 0; i < count; ++i) {
        uint32_t slot = ((write + i) & (ring->capacity - 1)) * 2;
        ring->samples[slot] = stereo[i * 2];
        ring->samples[slot + 1] = stereo[i * 2 + 1];
    }
    atomic_store_explicit(&ring->write, write + count, memory_order_release);
    return count;
}
uint32_t ABRingRead(ABRing *ring, float *stereo, uint32_t frames) {
    uint32_t read = atomic_load_explicit(&ring->read, memory_order_relaxed);
    uint32_t write = atomic_load_explicit(&ring->write, memory_order_acquire);
    uint32_t available = write - read;
    uint32_t count = frames < available ? frames : available;
    for (uint32_t i = 0; i < count; ++i) {
        uint32_t slot = ((read + i) & (ring->capacity - 1)) * 2;
        stereo[i * 2] = ring->samples[slot]; stereo[i * 2 + 1] = ring->samples[slot + 1];
    }
    // Starvation never exposes old samples from the caller scratch buffer.
    if (count < frames) memset(stereo + count * 2, 0, (size_t)(frames - count) * 2 * sizeof(float));
    atomic_store_explicit(&ring->read, read + count, memory_order_release);
    return count;
}

struct ABEngine {
    AudioDeviceID inputDevice, outputDevice;
    AudioDeviceIOProcID inputProc, outputProc;
    ABLayout inputLayout, outputLayout;
    ABRing *ring;
    float *inputScratch, *outputScratch;
    uint32_t scratchFrames, prefill;
    bool inputStarted, outputStarted;
    _Atomic bool enabled, primed;
    _Atomic uint32_t inFlight;
    _Atomic uint64_t inputCallbacks, outputCallbacks, inputFrames, outputFrames;
    _Atomic uint64_t underrunFrames, overrunFrames, formatFaults;
};

static bool valid_layout(ABLayout layout) {
    return layout.channels > 0 && layout.channels <= 4096
        && layout.lane1 < layout.channels && layout.lane2 < layout.channels;
}
static bool buffer_frames(const AudioBufferList *list, ABLayout layout, uint32_t *frames) {
    if (!list || list->mNumberBuffers != (layout.planar ? layout.channels : 1)) return false;
    uint32_t expectedChannels = layout.planar ? 1 : layout.channels;
    uint32_t bytesPerFrame = expectedChannels * (uint32_t)sizeof(float);
    uint32_t count = list->mBuffers[0].mDataByteSize / bytesPerFrame;
    for (uint32_t i = 0; i < list->mNumberBuffers; ++i) {
        const AudioBuffer *buffer = &list->mBuffers[i];
        if (!buffer->mData || buffer->mNumberChannels != expectedChannels
            || buffer->mDataByteSize % bytesPerFrame
            || buffer->mDataByteSize / bytesPerFrame != count) return false;
    }
    *frames = count;
    return true;
}
static float sample_at(const AudioBufferList *list, ABLayout layout, uint32_t frame, uint32_t channel) {
    uint32_t buffer = layout.planar ? channel : 0;
    size_t index = layout.planar ? frame : (size_t)frame * layout.channels + channel;
    float sample;
    memcpy(&sample, (const char *)list->mBuffers[buffer].mData + index * sizeof(float), sizeof(float));
    return sample;
}
static void put_sample(AudioBufferList *list, ABLayout layout, uint32_t frame, uint32_t channel, float sample) {
    uint32_t buffer = layout.planar ? channel : 0;
    size_t index = layout.planar ? frame : (size_t)frame * layout.channels + channel;
    memcpy((char *)list->mBuffers[buffer].mData + index * sizeof(float), &sample, sizeof(float));
}
// C-only callbacks: no ARC, Swift exclusivity, allocation, locking, UI, logging or HAL property reads.
static OSStatus input_callback(AudioObjectID device, const AudioTimeStamp *now,
    const AudioBufferList *input, const AudioTimeStamp *inputTime,
    AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    (void)device; (void)now; (void)inputTime; (void)output; (void)outputTime;
    ABEngine *engine = context;
    atomic_fetch_add_explicit(&engine->inFlight, 1, memory_order_acquire);
    if (atomic_load_explicit(&engine->enabled, memory_order_acquire)) {
        uint32_t frames;
        atomic_fetch_add_explicit(&engine->inputCallbacks, 1, memory_order_relaxed);
        if (buffer_frames(input, engine->inputLayout, &frames) && frames <= engine->scratchFrames) {
            for (uint32_t i = 0; i < frames; ++i) {
                engine->inputScratch[i * 2] = sample_at(input, engine->inputLayout, i, engine->inputLayout.lane1);
                engine->inputScratch[i * 2 + 1] = sample_at(input, engine->inputLayout, i, engine->inputLayout.lane2);
            }
            uint32_t written = ABRingWrite(engine->ring, engine->inputScratch, frames);
            atomic_fetch_add_explicit(&engine->inputFrames, written, memory_order_relaxed);
            atomic_fetch_add_explicit(&engine->overrunFrames, frames - written, memory_order_relaxed);
        } else atomic_fetch_add_explicit(&engine->formatFaults, 1, memory_order_relaxed);
    }
    atomic_fetch_sub_explicit(&engine->inFlight, 1, memory_order_release);
    return noErr;
}
static OSStatus output_callback(AudioObjectID device, const AudioTimeStamp *now,
    const AudioBufferList *input, const AudioTimeStamp *inputTime,
    AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    (void)device; (void)now; (void)input; (void)inputTime; (void)outputTime;
    ABEngine *engine = context;
    atomic_fetch_add_explicit(&engine->inFlight, 1, memory_order_acquire);
    // HAL supplies zeroed output buffers (AudioHardware.h). Unselected lanes remain untouched.
    if (atomic_load_explicit(&engine->enabled, memory_order_acquire)) {
        atomic_fetch_add_explicit(&engine->outputCallbacks, 1, memory_order_relaxed);
        uint32_t frames;
        if (buffer_frames(output, engine->outputLayout, &frames) && frames <= engine->scratchFrames) {
            if (!atomic_load_explicit(&engine->primed, memory_order_relaxed)
                && ABRingAvailable(engine->ring) >= engine->prefill)
                atomic_store_explicit(&engine->primed, true, memory_order_release);
            if (atomic_load_explicit(&engine->primed, memory_order_relaxed)) {
                uint32_t read = ABRingRead(engine->ring, engine->outputScratch, frames);
                for (uint32_t i = 0; i < frames; ++i) {
                    put_sample(output, engine->outputLayout, i, engine->outputLayout.lane1, engine->outputScratch[i * 2]);
                    // Explicit duplicate output selection sums both lanes, never silently overwrites one.
                    float second = engine->outputScratch[i * 2 + 1];
                    if (engine->outputLayout.lane1 == engine->outputLayout.lane2) second += engine->outputScratch[i * 2];
                    put_sample(output, engine->outputLayout, i, engine->outputLayout.lane2, second);
                }
                atomic_fetch_add_explicit(&engine->outputFrames, read, memory_order_relaxed);
                atomic_fetch_add_explicit(&engine->underrunFrames, frames - read, memory_order_relaxed);
            }
        } else atomic_fetch_add_explicit(&engine->formatFaults, 1, memory_order_relaxed);
    }
    atomic_fetch_sub_explicit(&engine->inFlight, 1, memory_order_release);
    return noErr;
}
ABEngine *ABEngineCreate(AudioDeviceID input, AudioDeviceID output, ABLayout inputLayout,
                       ABLayout outputLayout, uint32_t capacity, uint32_t prefill) {
    if (!input || !output || input == output || !valid_layout(inputLayout) || !valid_layout(outputLayout)
        || prefill == 0 || prefill >= capacity) return NULL;
    ABEngine *engine = calloc(1, sizeof(*engine));
    if (!engine) return NULL;
    engine->ring = ABRingCreate(capacity);
    engine->inputScratch = calloc((size_t)capacity * 2, sizeof(float));
    engine->outputScratch = calloc((size_t)capacity * 2, sizeof(float));
    engine->scratchFrames = capacity; engine->prefill = prefill;
    engine->inputDevice = input; engine->outputDevice = output;
    engine->inputLayout = inputLayout; engine->outputLayout = outputLayout;
    atomic_init(&engine->enabled, false); atomic_init(&engine->primed, false);
    atomic_init(&engine->inFlight, 0);
    atomic_init(&engine->inputCallbacks, 0); atomic_init(&engine->outputCallbacks, 0);
    atomic_init(&engine->inputFrames, 0); atomic_init(&engine->outputFrames, 0);
    atomic_init(&engine->underrunFrames, 0); atomic_init(&engine->overrunFrames, 0); atomic_init(&engine->formatFaults, 0);
    if (!engine->ring || !engine->inputScratch || !engine->outputScratch
        || !atomic_is_lock_free(&engine->enabled) || !atomic_is_lock_free(&engine->primed)
        || !atomic_is_lock_free(&engine->inFlight) || !atomic_is_lock_free(&engine->inputCallbacks)) {
        ABEngineDestroy(engine); return NULL;
    }
    return engine;
}
OSStatus ABEngineStart(ABEngine *engine) {
    if (!engine || engine->inputProc || engine->outputProc) return kAudioHardwareIllegalOperationError;
    OSStatus status = AudioDeviceCreateIOProcID(engine->inputDevice, input_callback, engine, &engine->inputProc);
    if (status != noErr) return status;
    status = AudioDeviceCreateIOProcID(engine->outputDevice, output_callback, engine, &engine->outputProc);
    if (status != noErr) return status;
    atomic_store_explicit(&engine->enabled, true, memory_order_release);
    status = AudioDeviceStart(engine->inputDevice, engine->inputProc);
    if (status != noErr) { atomic_store_explicit(&engine->enabled, false, memory_order_release); return status; }
    engine->inputStarted = true;
    status = AudioDeviceStart(engine->outputDevice, engine->outputProc);
    if (status != noErr) { atomic_store_explicit(&engine->enabled, false, memory_order_release); return status; }
    engine->outputStarted = true;
    return noErr;
}
OSStatus ABEngineStop(ABEngine *engine) {
    if (!engine) return noErr;
    atomic_store_explicit(&engine->enabled, false, memory_order_release);
    OSStatus first = noErr;
    AudioDeviceIOProcID *procs[] = { &engine->outputProc, &engine->inputProc };
    AudioDeviceID devices[] = { engine->outputDevice, engine->inputDevice };
    bool *started[] = { &engine->outputStarted, &engine->inputStarted };
    for (int i = 0; i < 2; ++i) {
        if (!*procs[i]) continue;
        if (*started[i]) {
            OSStatus status = AudioDeviceStop(devices[i], *procs[i]);
            if (status != noErr && first == noErr) first = status;
            if (status == noErr) *started[i] = false;
        }
        OSStatus status = AudioDeviceDestroyIOProcID(devices[i], *procs[i]);
        if (status == noErr) { *procs[i] = NULL; *started[i] = false; }
        else if (first == noErr) first = status;
    }
    // Wait only on the lifecycle queue, after detaching registrations. Never wait in a callback.
    if (!engine->inputProc && !engine->outputProc) {
        for (int i = 0; i < 1000 && atomic_load_explicit(&engine->inFlight, memory_order_acquire); ++i) usleep(1000);
        if (atomic_load_explicit(&engine->inFlight, memory_order_acquire) && first == noErr)
            first = kAudioHardwareUnspecifiedError;
    }
    return first;
}
bool ABEngineDestroy(ABEngine *engine) {
    if (!engine) return true;
    (void)ABEngineStop(engine);
    if (engine->inputProc || engine->outputProc || atomic_load_explicit(&engine->inFlight, memory_order_acquire))
        return false; // Keep callbacks context alive on failed unregister/teardown.
    ABRingDestroy(engine->ring); free(engine->inputScratch); free(engine->outputScratch); free(engine);
    return true;
}
ABMetrics ABEngineMetrics(const ABEngine *engine) {
    ABMetrics result = {0};
    if (!engine) return result;
#define AB_LOAD(field) result.field = atomic_load_explicit(&engine->field, memory_order_relaxed)
    AB_LOAD(inputCallbacks); AB_LOAD(outputCallbacks); AB_LOAD(inputFrames); AB_LOAD(outputFrames);
    AB_LOAD(underrunFrames); AB_LOAD(overrunFrames); AB_LOAD(formatFaults); AB_LOAD(primed);
#undef AB_LOAD
    result.bufferedFrames = ABRingAvailable(engine->ring);
    return result;
}
