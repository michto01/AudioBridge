#include "StereoRouting.h"
#include "AudioBridgeRealtime.h"
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    ABChannelAddress *addresses;
    uint32_t *buffers, count, bufferCount;
    _Atomic uint32_t *targets, version;
    float *snapshot;
    ABGainRamp *ramps;
} Direction;
struct ABRouting { Direction input, output; };
static uint32_t bits(float f) { uint32_t v; memcpy(&v, &f, sizeof v); return v; }
static float value(uint32_t v) { float f; memcpy(&f, &v, sizeof f); return f; }
static void dispose(Direction *d) { free(d->addresses); free(d->buffers); free(d->targets); free(d->snapshot); free(d->ramps); }
static bool prepare(Direction *d, const ABChannelAddress *a, uint32_t n, const uint32_t *b, uint32_t nb) {
    if (!a || !b || !n || n > 4096 || !nb || nb > 4096) return false;
    for (uint32_t i = 0; i < nb; i++) if (!b[i] || b[i] > 4096) return false;
    for (uint32_t i = 0; i < n; i++) {
        if (a[i].buffer >= nb || a[i].stride != b[a[i].buffer] || a[i].offset >= a[i].stride) return false;
        for (uint32_t j = 0; j < i; j++) if (a[i].buffer == a[j].buffer && a[i].offset == a[j].offset) return false;
    }
    d->count = n; d->bufferCount = nb;
    d->addresses = malloc(n * sizeof(*a)); d->buffers = malloc(nb * sizeof(*b));
    d->targets = calloc(n * 2, sizeof(*d->targets));
    d->snapshot = calloc(n * 2, sizeof(float)); d->ramps = calloc(n * 2, sizeof(ABGainRamp));
    if (!d->addresses || !d->buffers || !d->targets || !d->snapshot || !d->ramps) return false;
    memcpy(d->addresses, a, n * sizeof(*a)); memcpy(d->buffers, b, nb * sizeof(*b));
    atomic_init(&d->version, 0);
    for (uint32_t i = 0; i < n * 2; i++) atomic_init(&d->targets[i], 0);
    return atomic_is_lock_free(&d->version) && atomic_is_lock_free(&d->targets[0]);
}
static bool valid_gains(const Direction *d, const float *g, uint32_t n) {
    if (!g || n != d->count) return false;
    for (uint32_t i = 0; i < n * 2; i++) if (!isfinite(g[i]) || g[i] < 0 || g[i] > 2) return false;
    return true;
}
static bool update(Direction *d, const float *g, uint32_t n, bool initial) {
    if (!valid_gains(d, g, n)) return false;
    atomic_fetch_add_explicit(&d->version, 1, memory_order_seq_cst);
    for (uint32_t i = 0; i < n * 2; i++) atomic_store_explicit(&d->targets[i], bits(g[i]), memory_order_seq_cst);
    atomic_fetch_add_explicit(&d->version, 1, memory_order_seq_cst);
    if (initial) for (uint32_t i = 0; i < n * 2; i++) d->ramps[i] = (ABGainRamp){ .current = g[i], .target = g[i] };
    return true;
}
ABRouting *ABRoutingCreate(const ABChannelAddress *i, uint32_t ni, const uint32_t *ib, uint32_t nib, const float *ig,
    const ABChannelAddress *o, uint32_t no, const uint32_t *ob, uint32_t nob, const float *og) {
    ABRouting *r = calloc(1, sizeof *r);
    if (!r) return NULL;
    if (!prepare(&r->input, i, ni, ib, nib) || !prepare(&r->output, o, no, ob, nob)
        || !update(&r->input, ig, ni, true) || !update(&r->output, og, no, true)) { ABRoutingDestroy(r); return NULL; }
    return r;
}
void ABRoutingDestroy(ABRouting *r) { if (r) { dispose(&r->input); dispose(&r->output); free(r); } }
bool ABRoutingSetInput(ABRouting *r, const float *g, uint32_t n, bool initial) { return r && update(&r->input, g, n, initial); }
bool ABRoutingSetOutput(ABRouting *r, const float *g, uint32_t n, bool initial) { return r && update(&r->output, g, n, initial); }
bool ABRoutingSetBoth(ABRouting *r, const float *input, uint32_t ni, const float *output, uint32_t no, bool initial) {
    if (!r || !valid_gains(&r->input, input, ni) || !valid_gains(&r->output, output, no)) return false;
    return update(&r->input, input, ni, initial) && update(&r->output, output, no, initial);
}
bool ABRoutingFrames(const ABRouting *r, const AudioBufferList *abl, bool input, uint32_t *frames) {
    if (!r || !abl || !frames) return false;
    const Direction *d = input ? &r->input : &r->output;
    if (abl->mNumberBuffers != d->bufferCount) return false;
    uint32_t count = 0;
    for (uint32_t b = 0; b < d->bufferCount; b++) {
        const AudioBuffer *buffer = &abl->mBuffers[b];
        uint32_t bytes = d->buffers[b] * sizeof(float);
        if (!buffer->mData || buffer->mNumberChannels != d->buffers[b] || buffer->mDataByteSize % bytes) return false;
        uint32_t n = buffer->mDataByteSize / bytes;
        if (b && n != count) return false;
        count = n;
    }
    *frames = count; return count > 0;
}
static void snapshot(Direction *d, uint32_t ramp) {
    uint32_t version = atomic_load_explicit(&d->version, memory_order_seq_cst);
    if (version & 1) return;
    for (uint32_t i = 0; i < d->count * 2; i++) d->snapshot[i] = value(atomic_load_explicit(&d->targets[i], memory_order_seq_cst));
    if (version != atomic_load_explicit(&d->version, memory_order_seq_cst)) return;
    for (uint32_t i = 0; i < d->count * 2; i++) if (d->snapshot[i] != d->ramps[i].target) ABGainRetarget(&d->ramps[i], d->snapshot[i], ramp);
}
void ABRoutingMix(ABRouting *r, const AudioBufferList *abl, float *out, uint32_t frames, uint32_t ramp,
                 uint64_t *faults, uint64_t *rawL, uint64_t *rawR) {
    Direction *d = &r->input; snapshot(d, ramp);
    memset(out, 0, (size_t)frames * 2 * sizeof(float));
    for (uint32_t f = 0; f < frames; f++) {
        double left = 0, right = 0;
        for (uint32_t c = 0; c < d->count; c++) {
            float l = ABGainNext(&d->ramps[c * 2]), rr = ABGainNext(&d->ramps[c * 2 + 1]);
            if (l == 0 && rr == 0) continue;
            ABChannelAddress a = d->addresses[c]; float sample;
            memcpy(&sample, (char *)abl->mBuffers[a.buffer].mData + ((size_t)f * a.stride + a.offset) * sizeof(float), sizeof sample);
            if (!isfinite(sample)) { sample = 0; (*faults)++; }
            if (fabsf(sample) >= 1) { if (l > 0) (*rawL)++; if (rr > 0) (*rawR)++; }
            left += sample * (double)l; right += sample * (double)rr;
        }
        out[f * 2] = (float)left; out[f * 2 + 1] = (float)right;
    }
}
void ABRoutingFanout(ABRouting *r, const float *in, AudioBufferList *abl, uint32_t frames, uint32_t ramp,
                    uint64_t *faults, float *peak, uint64_t *clips) {
    Direction *d = &r->output; snapshot(d, ramp);
    for (uint32_t f = 0; f < frames; f++) for (uint32_t c = 0; c < d->count; c++) {
        float l = ABGainNext(&d->ramps[c * 2]), rr = ABGainNext(&d->ramps[c * 2 + 1]);
        float sample = l * in[f * 2] + rr * in[f * 2 + 1];
        if (!isfinite(sample)) { sample = 0; (*faults)++; }
        *peak = fmaxf(*peak, fabsf(sample)); if (fabsf(sample) >= 1) (*clips)++;
        ABChannelAddress a = d->addresses[c];
        memcpy((char *)abl->mBuffers[a.buffer].mData + ((size_t)f * a.stride + a.offset) * sizeof(float), &sample, sizeof sample);
    }
}
