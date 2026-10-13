#include "AudioBridgeRealtime.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
// Identical gain primitive in both builds; no engine, HAL or plugin is linked.
void ABGainRetarget(ABGainRamp *r, float target, uint32_t frames) {
    r->target = target; r->remaining = frames; r->step = frames ? (target - r->current) / frames : 0;
    if (!frames) r->current = target;
}
float ABGainNext(ABGainRamp *r) {
    if (r->remaining) { r->current += r->step; if (--r->remaining == 0) r->current = r->target; }
    return r->current;
}
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec * 1e-9; }
static uint32_t read_signal(void *context, float *samples, uint32_t frames) {
    (void)context;
    for (uint32_t i = 0; i < frames; i++) { samples[i * 2] = 0.25f; samples[i * 2 + 1] = -0.5f; }
    return frames;
}
static void route(uint32_t channels) {
    uint32_t frames = 128, iterations = 1000;
    ABChannelAddress *addresses = calloc(channels, sizeof(*addresses));
    float *gains = calloc(channels * 2, sizeof(float)), *source = calloc(channels * frames, sizeof(float));
    float *output = calloc(channels * frames, sizeof(float)), *stereo = calloc(frames * 2, sizeof(float));
    if (!addresses || !gains || !source || !output || !stereo) exit(2);
    for (uint32_t c = 0; c < channels; c++) addresses[c] = (ABChannelAddress){0, c, channels};
    gains[0] = 1; gains[3] = 1;
    for (uint32_t i = 0; i < channels * frames; i++) source[i] = 0.25f;
    ABRouting *r = ABRoutingCreate(addresses, channels, &channels, 1, gains, addresses, channels, &channels, 1, gains);
    if (!r) exit(2);
    AudioBufferList in = {1, {{channels, channels * frames * sizeof(float), source}}};
    AudioBufferList out = {1, {{channels, channels * frames * sizeof(float), output}}};
    uint64_t faults = 0, rawL = 0, rawR = 0, clips = 0; float peak = 0;
    double start = now();
    for (uint32_t i = 0; i < iterations; i++) {
        ABRoutingMix(r, &in, stereo, frames, 960, &faults, &rawL, &rawR);
        ABRoutingFanout(r, stereo, &out, frames, 960, &faults, &peak, &clips);
    }
    printf("route_%u %.3f us/block faults=%llu peak=%.3f\n", channels, (now() - start) * 1e6 / iterations, (unsigned long long)faults, peak);
    ABRoutingDestroy(r); free(addresses); free(gains); free(source); free(output); free(stereo);
}
static void resample(void) {
    ABResampler *r = ABResamplerCreate(); float out[64];
    if (!r) exit(2);
    uint32_t iterations = 10000; uint64_t checksum = 0; double start = now();
    for (uint32_t i = 0; i < iterations; i++) {
#ifdef PREPARED
        ABResamplerPlan plan = ABResamplerPrepare(r, 32, 1.0002);
        checksum += plan.needed;
        checksum += ABResamplerProcessPrepared(r, read_signal, NULL, out, &plan);
#else
        checksum += ABResamplerInputNeeded(r, 32, 1.0002);
        checksum += ABResamplerProcess(r, read_signal, NULL, out, 32, 1.0002);
#endif
    }
    printf("fir_32 %.3f us/block checksum=%llu\n", (now() - start) * 1e6 / iterations, (unsigned long long)checksum);
    ABResamplerDestroy(r);
}
int main(void) { route(2); route(16); route(256); resample(); return 0; }
