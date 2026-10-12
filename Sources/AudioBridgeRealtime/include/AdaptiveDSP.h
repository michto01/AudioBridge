#ifndef AB_ADAPTIVE_DSP_H
#define AB_ADAPTIVE_DSP_H
#include <stdbool.h>
#include <stdint.h>
typedef struct { double filtered, integral, ppm; bool initialized, saturated; } ABDriftController;
double ABDriftStep(ABDriftController *controller, double occupancy, double target, double sampleRate, uint32_t outputFrames);
void ABDriftReanchor(ABDriftController *controller, double target);
// Hold only when processed delivery is low while conserved backlog is excessive.
bool ABDriftShouldHold(double pending, double target, uint32_t processed, uint32_t needed, uint32_t reserve);
typedef struct ABResampler ABResampler;
typedef uint32_t (*ABReadStereo)(void *context, float *samples, uint32_t frames);
ABResampler *ABResamplerCreate(void);
void ABResamplerDestroy(ABResampler *resampler);
void ABResamplerReset(ABResampler *resampler);
uint32_t ABResamplerLookahead(void);
bool ABResamplerStarved(const ABResampler *resampler);
// Exact input demand for the next call, including partial priming/history.
// UINT32_MAX for invalid arguments; history survives a temporary short read.
uint32_t ABResamplerInputNeeded(const ABResampler *resampler, uint32_t frames, double ratio);
uint32_t ABResamplerProcess(ABResampler *resampler, ABReadStereo read, void *context, float *output, uint32_t frames, double ratio);
#endif
