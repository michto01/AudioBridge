#ifndef AUDIO_BRIDGE_REALTIME_H
#define AUDIO_BRIDGE_REALTIME_H
#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

typedef struct ABRing ABRing;
ABRing *ABRingCreate(uint32_t capacity);
void ABRingDestroy(ABRing *ring);
uint32_t ABRingWrite(ABRing *ring, const float *stereo, uint32_t frames);
uint32_t ABRingRead(ABRing *ring, float *stereo, uint32_t frames);
uint32_t ABRingAvailable(const ABRing *ring);

typedef struct {
    uint32_t channels;
    uint32_t lane1; // Zero-based within the single selected stream.
    uint32_t lane2;
    bool planar;
} ABLayout;

typedef struct ABEngine ABEngine;
typedef struct {
    uint64_t inputCallbacks;
    uint64_t outputCallbacks;
    uint64_t inputFrames;
    uint64_t outputFrames;
    uint64_t underrunFrames;
    uint64_t overrunFrames;
    uint64_t formatFaults;
    uint32_t bufferedFrames;
    bool primed;
} ABMetrics;

// Lifecycle functions are exclusively called on the owning non-realtime serial queue.
// Both formats must have been validated as packed native-endian Float32 PCM.
ABEngine *ABEngineCreate(AudioDeviceID input, AudioDeviceID output,
                         ABLayout inputLayout, ABLayout outputLayout,
                         uint32_t capacity, uint32_t prefill);
OSStatus ABEngineStart(ABEngine *engine);
OSStatus ABEngineStop(ABEngine *engine);
// Returns false and retains memory if HAL cannot detach callbacks safely.
bool ABEngineDestroy(ABEngine *engine);
ABMetrics ABEngineMetrics(const ABEngine *engine);
#endif
