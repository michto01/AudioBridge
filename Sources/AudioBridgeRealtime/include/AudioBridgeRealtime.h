#ifndef AUDIO_BRIDGE_REALTIME_H
#define AUDIO_BRIDGE_REALTIME_H
#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>
#include "AUTransport.h"
#include "AdaptiveDSP.h"

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
    float peak1, peak2;
    uint64_t clips1, clips2;
} ABLevels;
// Pure finite stereo sample measurement, no allocation; peaks are absolute amplitudes.
ABLevels ABMeasureStereo(const float *stereo, uint32_t frames);
typedef struct { float current, target, step; uint32_t remaining; } ABGainRamp;
void ABGainRetarget(ABGainRamp *ramp, float target, uint32_t frames);
float ABGainNext(ABGainRamp *ramp);
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
    ABLevels inputLevels, outputLevels;
    float driftPPM;
    uint64_t recenterFrames, rebufferEvents;
    uint64_t rawInputClips1, rawInputClips2;
} ABMetrics;

// Lifecycle functions are exclusively called on the owning non-realtime serial queue.
// Both formats must have been validated as packed native-endian Float32 PCM.
ABEngine *ABEngineCreate(AudioDeviceID input, AudioDeviceID output,
                         ABLayout inputLayout, ABLayout outputLayout,
                         uint32_t capacity, uint32_t prefill);
OSStatus ABEngineStart(ABEngine *engine);
// Borrowed mapping stays alive until callback teardown succeeds.
bool ABEngineAttachAU(ABEngine *engine, ABAUTransport *transport);
// Initial gain is configured only before callback registration; live updates are atomic.
void ABEngineInitialGains(ABEngine *engine, float input, float output, uint32_t rampFrames);
void ABEngineSetGains(ABEngine *engine, float input, float output);
bool ABEngineConfigureDrift(ABEngine *engine, double sampleRate, uint32_t inputBuffer);
void ABEngineSetMatrix(ABEngine *engine, float a, float b, float c, float d);
OSStatus ABEngineStop(ABEngine *engine);
// Returns false and retains memory if HAL cannot detach callbacks safely.
bool ABEngineDestroy(ABEngine *engine);
ABMetrics ABEngineMetrics(const ABEngine *engine);
#endif
