#ifndef AB_ADAPTIVE_DSP_H
#define AB_ADAPTIVE_DSP_H
#include <stdbool.h>
#include <stdint.h>
typedef struct { double filtered, integral, ppm; bool initialized; } ABDriftController;
double ABDriftStep(ABDriftController *controller, double occupancy, double target, double sampleRate, uint32_t outputFrames);
typedef struct ABResampler ABResampler;
typedef uint32_t (*ABReadStereo)(void *context, float *samples, uint32_t frames);
ABResampler *ABResamplerCreate(void);
void ABResamplerDestroy(ABResampler *resampler);
void ABResamplerReset(ABResampler *resampler);
uint32_t ABResamplerLookahead(void);
bool ABResamplerStarved(const ABResampler *resampler);
uint32_t ABResamplerProcess(ABResampler *resampler, ABReadStereo read, void *context, float *output, uint32_t frames, double ratio);
#endif
