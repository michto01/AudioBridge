#include "AdaptiveDSP.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
#define TAPS 32
#define PHASES 256
static double clamp(double x, double lo, double hi) { return fmin(hi, fmax(lo, x)); }
double ABDriftStep(ABDriftController *c, double occupancy, double target, double rate, uint32_t frames) {
    if (!c || !isfinite(occupancy) || !isfinite(target) || !isfinite(rate) || rate <= 0 || target <= 0 || !frames) return 1;
    double dt = frames / rate;
    if (!c->initialized) { c->filtered = target; c->initialized = true; }
    c->filtered += dt / (2.0 + dt) * (occupancy - c->filtered);
    double error = (c->filtered - target) / rate; // seconds of excess queued audio
    c->integral = clamp(c->integral + error * dt * 10000.0, -800, 800);
    double requested = clamp(c->integral + error * 200000.0, -1000, 1000);
    c->ppm += clamp(requested - c->ppm, -50 * dt, 50 * dt);
    return 1 + c->ppm * 1e-6; // Faster capture -> consume more input per output frame.
}
struct ABResampler {
    float coefficients[PHASES][TAPS], window[TAPS][2];
    uint32_t head;
    double fraction;
    bool primed, starved;
};
ABResampler *ABResamplerCreate(void) {
    ABResampler *r = calloc(1, sizeof(*r));
    if (!r) return NULL;
    // Precomputed fractional-delay, low-pass Blackman-windowed sinc bank.
    for (int phase = 0; phase < PHASES; phase++) {
        double fraction = (double)phase / PHASES, sum = 0;
        for (int j = 0; j < TAPS; j++) {
            double x = (j - 15 - fraction) * 0.95;
            double sinc = fabs(x) < 1e-12 ? 1 : sin(M_PI * x) / (M_PI * x);
            double window = 0.42 - 0.5 * cos(2 * M_PI * j / (TAPS - 1)) + 0.08 * cos(4 * M_PI * j / (TAPS - 1));
            r->coefficients[phase][j] = (float)(0.95 * sinc * window); sum += r->coefficients[phase][j];
        }
        for (int j = 0; j < TAPS; j++) r->coefficients[phase][j] /= (float)sum;
    }
    return r;
}
void ABResamplerReset(ABResampler *r) { if (r) { memset(r->window, 0, sizeof(r->window)); r->head = 0; r->fraction = 0; r->primed = false; r->starved = false; } }
void ABResamplerDestroy(ABResampler *r) { free(r); }
uint32_t ABResamplerLookahead(void) { return 17; }
bool ABResamplerStarved(const ABResampler *r) { return r && r->starved; }
uint32_t ABResamplerProcess(ABResampler *r, ABReadStereo read, void *context, float *out, uint32_t frames, double ratio) {
    if (!r || !read || !out || !isfinite(ratio) || ratio < 0.999 || ratio > 1.001) return 0;
    memset(out, 0, (size_t)frames * 2 * sizeof(float));
    r->starved = false;
    if (!r->primed) {
        for (int j = 15; j < TAPS; j++) if (read(context, r->window[j], 1) != 1) { ABResamplerReset(r); r->starved = true; return 0; }
        r->primed = true;
    }
    uint32_t made = 0;
    for (; made < frames; made++) {
        uint32_t phase = (uint32_t)(r->fraction * PHASES);
        double left = 0, right = 0;
        for (uint32_t j = 0; j < TAPS; j++) {
            uint32_t index = (r->head + j) % TAPS;
            left += r->window[index][0] * r->coefficients[phase][j];
            right += r->window[index][1] * r->coefficients[phase][j];
        }
        out[made * 2] = (float)left; out[made * 2 + 1] = (float)right;
        r->fraction += ratio;
        while (r->fraction >= 1) {
            if (read(context, r->window[r->head], 1) != 1) { ABResamplerReset(r); r->starved = true; return made + 1; }
            r->head = (r->head + 1) % TAPS; r->fraction -= 1;
        }
    }
    return made;
}
