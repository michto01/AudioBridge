#ifndef AB_STEREO_ROUTING_H
#define AB_STEREO_ROUTING_H
#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

typedef struct { uint32_t buffer, offset, stride; } ABChannelAddress;
typedef struct ABRouting ABRouting;
// Copies all topology and coefficient data before callbacks start. Max 4096 channels/direction.
ABRouting *ABRoutingCreate(const ABChannelAddress *inputs, uint32_t inputCount,
    const uint32_t *inputBuffers, uint32_t inputBufferCount, const float *inputGains,
    const ABChannelAddress *outputs, uint32_t outputCount,
    const uint32_t *outputBuffers, uint32_t outputBufferCount, const float *outputGains);
void ABRoutingDestroy(ABRouting *routing);
// Single lifecycle writer. Initial=true only before callback registration.
bool ABRoutingSetInput(ABRouting *routing, const float *gains, uint32_t count, bool initial);
bool ABRoutingSetOutput(ABRouting *routing, const float *gains, uint32_t count, bool initial);
bool ABRoutingSetBoth(ABRouting *routing, const float *input, uint32_t inputCount,
    const float *output, uint32_t outputCount, bool initial);
bool ABRoutingFrames(const ABRouting *routing, const AudioBufferList *buffers, bool input, uint32_t *frames);
// All scratch/state is owned by the respective callback. No allocation or lock.
void ABRoutingMix(ABRouting *routing, const AudioBufferList *input, float *stereo,
    uint32_t frames, uint32_t rampFrames, uint64_t *faults, uint64_t *rawLeft, uint64_t *rawRight);
void ABRoutingFanout(ABRouting *routing, const float *stereo, AudioBufferList *output,
    uint32_t frames, uint32_t rampFrames, uint64_t *faults, float *physicalPeak, uint64_t *physicalClips);
#endif
