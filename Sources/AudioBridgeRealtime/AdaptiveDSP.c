#include "AdaptiveDSP.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
#define TAPS 32
#define PHASES 256
#define SOURCE_FRAMES 65664
static double clamp(double x, double lo, double hi) { return fmin(hi, fmax(lo, x)); }
bool ABDriftShouldHold(double pending, double target, uint32_t processed, uint32_t needed, uint32_t reserve) {
    return processed < (uint64_t)needed + reserve / 2 && pending > target;
}
double ABDriftStep(ABDriftController *c, double occupancy, double target, double rate, uint32_t frames) {
    if (!c || !isfinite(occupancy) || !isfinite(target) || !isfinite(rate) || rate <= 0 || target <= 0 || !frames) return 1;
    double dt = frames / rate;
    if (!c->initialized) { c->filtered = target; c->initialized = true; }
    c->filtered += dt / (2.0 + dt) * (occupancy - c->filtered);
    double error = (c->filtered - target) / rate; // seconds of excess queued audio
    double proposedIntegral = clamp(c->integral + error * dt * 10000.0, -800, 800);
    double proposed = proposedIntegral + error * 200000.0;
    // Anti-windup: do not integrate farther into a saturated correction.
    if ((proposed > 1000 && error > 0) || (proposed < -1000 && error < 0)) {
        proposedIntegral = c->integral;
        proposed = proposedIntegral + error * 200000.0;
    }
    c->integral = proposedIntegral;
    c->saturated = proposed > 1000 || proposed < -1000;
    double requested = clamp(proposed, -1000, 1000);
    c->ppm += clamp(requested - c->ppm, -50 * dt, 50 * dt);
    return 1 + c->ppm * 1e-6; // Faster capture -> consume more input per output frame.
}
void ABDriftReanchor(ABDriftController *c, double target) {
    if (!c || !isfinite(target) || target <= 0) return;
    c->filtered = target; c->initialized = true;
    c->saturated = false;
    // Preserve the bounded running correction, remove a stale occupancy error.
    c->integral = clamp(c->ppm, -800, 800);
}
struct ABResampler {
    float coefficients[PHASES][TAPS], window[TAPS * 2][2];
    float source[SOURCE_FRAMES][2];
    uint32_t head, primeCount;
    double fraction;
    bool primed, starved;
    uint64_t generation;
};
ABResampler *ABResamplerCreate(void) {
    ABResampler *r = calloc(1, sizeof(*r));
    if (!r) return NULL;
    r->primeCount = 15;
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
void ABResamplerReset(ABResampler *r) { if (r) { r->generation++; memset(r->window, 0, sizeof(r->window)); r->head = 0; r->primeCount = 15; r->fraction = 0; r->primed = false; r->starved = false; } }
void ABResamplerDestroy(ABResampler *r) { free(r); }
uint32_t ABResamplerLookahead(void) { return 17; }
bool ABResamplerStarved(const ABResampler *r) { return r && r->starved; }
uint32_t ABResamplerInputNeeded(const ABResampler *r, uint32_t frames, double ratio) {
    if (!r || frames > 65536 || !isfinite(ratio) || ratio < 0.999 || ratio > 1.001) return UINT32_MAX;
    if (!frames) return 0;
    uint32_t count = r->primed ? 0 : TAPS - r->primeCount;
    double fraction = r->fraction;
    for (uint32_t i = 0; i < frames; i++) {
        while (fraction >= 1) { count++; fraction -= 1; }
        fraction += ratio;
    }
    return count;
}
uint32_t ABResamplerProcess(ABResampler *r, ABReadStereo read, void *context, float *out, uint32_t frames, double ratio) {
    ABResamplerPlan plan = ABResamplerPrepare(r, frames, ratio);
    return ABResamplerProcessPrepared(r, read, context, out, &plan);
}
ABResamplerPlan ABResamplerPrepare(const ABResampler *r, uint32_t frames, double ratio) {
    return (ABResamplerPlan){ .owner = r, .generation = r ? r->generation : 0,
        .frames = frames, .ratio = ratio, .needed = ABResamplerInputNeeded(r, frames, ratio) };
}
bool ABResamplerPlanValid(const ABResampler *r, const ABResamplerPlan *plan) {
    return r && plan && plan->owner == r && plan->generation == r->generation
        && plan->frames && plan->frames <= 65536 && plan->needed <= SOURCE_FRAMES
        && isfinite(plan->ratio) && plan->ratio >= 0.999 && plan->ratio <= 1.001;
}
uint32_t ABResamplerProcessPrepared(ABResampler *r, ABReadStereo read, void *context, float *out, const ABResamplerPlan *plan) {
    // Only callback-owned plans prepared by this API may be passed here.
    // A reset or even a short/empty process invalidates all previous plans.
    if (!read || !out || !ABResamplerPlanValid(r, plan)) return 0;
    uint32_t frames = plan->frames, needed = plan->needed;
    double ratio = plan->ratio;
    r->generation++;
    memset(out, 0, (size_t)frames * 2 * sizeof(float));
    r->starved = false;
    // Fetch exactly this callback's source demand once. No per-sample IPC
    // atomics/wakes; short reads retain the same FIR history and phase.
    if (needed > SOURCE_FRAMES) return 0;
    uint32_t available = needed ? read(context, &r->source[0][0], needed) : 0;
    if (available > needed) available = needed;
    uint32_t consumed = 0;
    if (!r->primed) {
        while (r->primeCount < TAPS) {
            if (consumed == available) { r->starved = true; return 0; }
            memcpy(r->window[r->primeCount], r->source[consumed++], sizeof(float) * 2);
            memcpy(r->window[r->primeCount + TAPS], r->window[r->primeCount], sizeof(float) * 2);
            r->primeCount++;
        }
        r->primed = true;
    }
    uint32_t made = 0;
    for (; made < frames; made++) {
        // Advance only when another output sample needs it. A full final
        // callback must not starve just because the *next* sample is absent.
        while (r->fraction >= 1) {
            if (consumed == available) { r->starved = true; return made; }
            memcpy(r->window[r->head], r->source[consumed++], sizeof(float) * 2);
            memcpy(r->window[r->head + TAPS], r->window[r->head], sizeof(float) * 2);
            r->head = (r->head + 1) % TAPS; r->fraction -= 1;
        }
        uint32_t phase = (uint32_t)(r->fraction * PHASES);
        double left = 0, right = 0;
        for (uint32_t j = 0; j < TAPS; j++) {
            uint32_t index = r->head + j;
            left += r->window[index][0] * r->coefficients[phase][j];
            right += r->window[index][1] * r->coefficients[phase][j];
        }
        out[made * 2] = (float)left; out[made * 2 + 1] = (float)right;
        r->fraction += ratio;
    }
    return made;
}
