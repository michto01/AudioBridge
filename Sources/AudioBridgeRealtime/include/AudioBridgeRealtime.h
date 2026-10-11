#ifndef AUDIO_BRIDGE_REALTIME_H
#define AUDIO_BRIDGE_REALTIME_H
#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>
#include "AUTransport.h"
#include "AdaptiveDSP.h"
#include "StereoRouting.h"

typedef struct ABRing ABRing;
ABRing *ABRingCreate(uint32_t capacity);
void ABRingDestroy(ABRing *ring);
uint32_t ABRingWrite(ABRing *ring, const float *stereo, uint32_t frames);
uint32_t ABRingRead(ABRing *ring, float *stereo, uint32_t frames);
uint32_t ABRingAvailable(const ABRing *ring);

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
    float physicalOutputPeak;
    uint64_t physicalOutputClips;
} ABMetrics;

// Lifecycle functions are exclusively called on the owning non-realtime serial queue.
// Both formats must have been validated as packed native-endian Float32 PCM.
ABEngine *ABEngineCreate(AudioDeviceID input, AudioDeviceID output,
                         uint32_t capacity, uint32_t prefill);
// Transfers routing ownership on success, before registration.
bool ABEngineAttachRouting(ABEngine *engine, ABRouting *routing);
bool ABEngineSetRouting(ABEngine *engine, const float *input, uint32_t inputCount, const float *output, uint32_t outputCount);
OSStatus ABEngineStart(ABEngine *engine);
// Borrowed mapping stays alive until callback teardown succeeds.
bool ABEngineAttachAU(ABEngine *engine, ABAUTransport *transport);
// Initial gain is configured only before callback registration; live updates are atomic.
void ABEngineInitialGains(ABEngine *engine, float input, float output, uint32_t rampFrames);
void ABEngineSetGains(ABEngine *engine, float input, float output);
bool ABEngineConfigureDrift(ABEngine *engine, double sampleRate, uint32_t inputBuffer);
OSStatus ABEngineStop(ABEngine *engine);
// Returns false and retains memory if HAL cannot detach callbacks safely.
bool ABEngineDestroy(ABEngine *engine);
ABMetrics ABEngineMetrics(const ABEngine *engine);
#endif
