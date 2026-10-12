#include "AudioBridgeRealtime.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <math.h>

ABLevels ABMeasureStereo(const float *stereo, uint32_t frames) {
    ABLevels levels = {0};
    for (uint32_t i = 0; i < frames; ++i) {
        float a = fabsf(stereo[i * 2]), b = fabsf(stereo[i * 2 + 1]);
        if (a > levels.peak1) levels.peak1 = a;
        if (b > levels.peak2) levels.peak2 = b;
        if (a >= 1) ++levels.clips1;
        if (b >= 1) ++levels.clips2;
    }
    return levels;
}

void ABGainRetarget(ABGainRamp *ramp, float target, uint32_t frames) {
    if (!isfinite(target) || target < 0 || target > 4) return;
    ramp->target = target;
    ramp->remaining = frames;
    ramp->step = frames ? (target - ramp->current) / frames : 0;
    if (!frames) ramp->current = target;
}
float ABGainNext(ABGainRamp *ramp) {
    if (ramp->remaining) {
        ramp->current += ramp->step;
        if (--ramp->remaining == 0) ramp->current = ramp->target;
    }
    return ramp->current;
}

struct ABRing {
    float *samples;
    uint32_t capacity;
    _Atomic uint32_t write;
    _Atomic uint32_t read;
};
ABRing *ABRingCreate(uint32_t capacity) {
    if (capacity < 2 || capacity > 65536 || (capacity & (capacity - 1))) return NULL;
    ABRing *ring = calloc(1, sizeof(*ring));
    if (!ring) return NULL;
    ring->samples = calloc((size_t)capacity * 2, sizeof(float));
    if (!ring->samples) { free(ring); return NULL; }
    ring->capacity = capacity;
    atomic_init(&ring->write, 0); atomic_init(&ring->read, 0);
    if (!atomic_is_lock_free(&ring->write) || !atomic_is_lock_free(&ring->read)) {
        ABRingDestroy(ring); return NULL;
    }
    return ring;
}
void ABRingDestroy(ABRing *ring) {
    if (ring) { free(ring->samples); free(ring); }
}
uint32_t ABRingAvailable(const ABRing *ring) {
    // UI snapshots are approximate. Clamp a mixed-generation read/write pair.
    uint32_t read = atomic_load_explicit(&ring->read, memory_order_acquire);
    uint32_t write = atomic_load_explicit(&ring->write, memory_order_acquire);
    uint32_t available = write - read;
    return available > ring->capacity ? ring->capacity : available;
}
uint32_t ABRingWrite(ABRing *ring, const float *stereo, uint32_t frames) {
    uint32_t write = atomic_load_explicit(&ring->write, memory_order_relaxed);
    uint32_t read = atomic_load_explicit(&ring->read, memory_order_acquire);
    uint32_t space = ring->capacity - (write - read);
    uint32_t count = frames < space ? frames : space;
    for (uint32_t i = 0; i < count; ++i) {
        uint32_t slot = ((write + i) & (ring->capacity - 1)) * 2;
        ring->samples[slot] = stereo[i * 2];
        ring->samples[slot + 1] = stereo[i * 2 + 1];
    }
    atomic_store_explicit(&ring->write, write + count, memory_order_release);
    return count;
}
uint32_t ABRingRead(ABRing *ring, float *stereo, uint32_t frames) {
    uint32_t read = atomic_load_explicit(&ring->read, memory_order_relaxed);
    uint32_t write = atomic_load_explicit(&ring->write, memory_order_acquire);
    uint32_t available = write - read;
    uint32_t count = frames < available ? frames : available;
    for (uint32_t i = 0; i < count; ++i) {
        uint32_t slot = ((read + i) & (ring->capacity - 1)) * 2;
        stereo[i * 2] = ring->samples[slot]; stereo[i * 2 + 1] = ring->samples[slot + 1];
    }
    // Starvation never exposes old samples from the caller scratch buffer.
    if (count < frames) memset(stereo + count * 2, 0, (size_t)(frames - count) * 2 * sizeof(float));
    atomic_store_explicit(&ring->read, read + count, memory_order_release);
    return count;
}

struct ABEngine {
    AudioDeviceID inputDevice, outputDevice;
    AudioDeviceIOProcID inputProc, outputProc;
    ABRouting *routing;
    ABRing *ring;
    float *inputScratch, *outputScratch;
    uint32_t scratchFrames, prefill;
    bool inputStarted, outputStarted;
    bool exclusiveRequested, inputHogHeld, outputHogHeld;
    uint32_t exclusiveFailureDevice;
    _Atomic bool enabled, primed;
    _Atomic uint32_t inFlight;
    _Atomic uint64_t inputCallbacks, outputCallbacks, inputFrames, outputFrames;
    _Atomic uint64_t underrunFrames, overrunFrames, formatFaults;
    _Atomic uint64_t layoutFaults;
    // Float bits use lock-free integer atomics; single writer per direction.
    _Atomic uint32_t inputPeak1, inputPeak2, outputPeak1, outputPeak2;
    _Atomic uint64_t inputClips1, inputClips2, outputClips1, outputClips2;
    _Atomic uint32_t inputGainTarget, outputGainTarget;
    _Atomic uint64_t rawInputClips1, rawInputClips2;
    ABGainRamp inputGain, outputGain;
    uint32_t rampFrames;
    ABAUTransport *au;
    ABResampler *resampler;
    ABDriftController drift;
    double sampleRate, driftTarget;
    uint32_t inputBuffer;
    _Atomic uint32_t driftPPMBits, physicalOutputPeak;
    _Atomic uint32_t appliedDriftPPMBits, refillThresholdFrames;
    _Atomic uint64_t inputClockAnchorSample, inputClockAnchorHost, outputClockAnchorSample, outputClockAnchorHost;
    _Atomic uint64_t inputClockRateBits, outputClockRateBits;
    _Atomic bool inputClockAnchorValid, outputClockAnchorValid, inputClockRateValid, outputClockRateValid;
    _Atomic uint32_t measuredClockDifferenceBits;
    _Atomic bool measuredClockDifferenceValid;
    _Atomic uint64_t driftHeldCallbacks, driftLimitedCallbacks;
    _Atomic uint64_t driftSaturatedCallbacks;
    _Atomic uint64_t recenterFrames, rebufferEvents, physicalOutputClips;

};

bool ABEngineAttachAU(ABEngine *engine, ABAUTransport *transport) {
    if (!engine || engine->inputProc || engine->outputProc) return false;
    engine->au = transport; return true;
}

static uint32_t float_bits(float value) { uint32_t bits; memcpy(&bits, &value, sizeof(bits)); return bits; }
static float bits_float(uint32_t bits) { float value; memcpy(&value, &bits, sizeof(value)); return value; }
static uint64_t double_bits(double value) { uint64_t bits; memcpy(&bits, &value, sizeof(bits)); return bits; }
static double bits_double(uint64_t bits) { double value; memcpy(&value, &bits, sizeof(value)); return value; }
static void record_clock_rate(ABEngine *engine, const AudioTimeStamp *timestamp, bool input) {
    if (!timestamp || (timestamp->mFlags & (kAudioTimeStampSampleTimeValid | kAudioTimeStampHostTimeValid))
        != (kAudioTimeStampSampleTimeValid | kAudioTimeStampHostTimeValid)
        || !isfinite(timestamp->mSampleTime)) return;
    _Atomic uint64_t *sampleAnchor = input ? &engine->inputClockAnchorSample : &engine->outputClockAnchorSample;
    _Atomic uint64_t *hostAnchor = input ? &engine->inputClockAnchorHost : &engine->outputClockAnchorHost;
    _Atomic bool *anchorValid = input ? &engine->inputClockAnchorValid : &engine->outputClockAnchorValid;
    _Atomic uint64_t *rateBits = input ? &engine->inputClockRateBits : &engine->outputClockRateBits;
    _Atomic bool *rateValid = input ? &engine->inputClockRateValid : &engine->outputClockRateValid;
    uint64_t sampleNow = double_bits(timestamp->mSampleTime), hostNow = timestamp->mHostTime;
    if (!atomic_load_explicit(anchorValid, memory_order_relaxed)) {
        atomic_store_explicit(sampleAnchor, sampleNow, memory_order_relaxed);
        atomic_store_explicit(hostAnchor, hostNow, memory_order_relaxed);
        atomic_store_explicit(anchorValid, true, memory_order_release);
        return;
    }
    double sampleThen = bits_double(atomic_load_explicit(sampleAnchor, memory_order_relaxed));
    uint64_t hostThen = atomic_load_explicit(hostAnchor, memory_order_relaxed);
    double sampleDelta = timestamp->mSampleTime - sampleThen;
    if (sampleDelta < engine->sampleRate * 0.5 || hostNow <= hostThen) return;
    double ratePerHostTick = sampleDelta / (double)(hostNow - hostThen);
    if (isfinite(ratePerHostTick) && ratePerHostTick > 0) {
        atomic_store_explicit(rateBits, double_bits(ratePerHostTick), memory_order_relaxed);
        atomic_store_explicit(rateValid, true, memory_order_release);
        double inRate = bits_double(atomic_load_explicit(&engine->inputClockRateBits, memory_order_relaxed));
        double outRate = bits_double(atomic_load_explicit(&engine->outputClockRateBits, memory_order_relaxed));
        if (atomic_load_explicit(&engine->inputClockRateValid, memory_order_acquire)
            && atomic_load_explicit(&engine->outputClockRateValid, memory_order_acquire)
            && isfinite(inRate) && isfinite(outRate) && outRate > 0) {
            double ppm = (inRate / outRate - 1.0) * 1000000.0;
            if (isfinite(ppm) && fabs(ppm) <= 100000.0) {
                atomic_store_explicit(&engine->measuredClockDifferenceBits, float_bits((float)ppm), memory_order_relaxed);
                atomic_store_explicit(&engine->measuredClockDifferenceValid, true, memory_order_release);
            }
        }
    }
    atomic_store_explicit(sampleAnchor, sampleNow, memory_order_relaxed);
    atomic_store_explicit(hostAnchor, hostNow, memory_order_relaxed);
}
bool ABEngineConfigureDrift(ABEngine *engine, double rate, uint32_t inputBuffer) {
    if (!engine || engine->inputProc || engine->outputProc || !isfinite(rate) || rate <= 0 || !inputBuffer) return false;
    engine->sampleRate = rate; engine->inputBuffer = inputBuffer;
    engine->driftTarget = engine->prefill + ABResamplerLookahead() + inputBuffer * 0.5;
    return true;
}
bool ABEngineAttachRouting(ABEngine *engine, ABRouting *routing) {
    if (!engine || !routing || engine->routing || engine->inputProc || engine->outputProc) return false;
    engine->routing = routing; return true; // Ownership transfers; freed after callbacks detach.
}
bool ABEngineSetRouting(ABEngine *engine, const float *input, uint32_t ni, const float *output, uint32_t no) {
    if (!engine || !engine->routing) return false;
    bool initial = !engine->inputProc && !engine->outputProc;
    return ABRoutingSetBoth(engine->routing, input, ni, output, no, initial);
}
static uint32_t source_read(void *context, float *samples, uint32_t frames) {
    ABEngine *engine = context;
    return engine->au ? ABAUOutputRead(engine->au, samples, frames) : ABRingRead(engine->ring, samples, frames);
}
void ABEngineSetGains(ABEngine *engine, float input, float output) {
    if (!engine || !isfinite(input) || !isfinite(output) || input < 0 || input > 4 || output < 0 || output > 4) return;
    atomic_store_explicit(&engine->inputGainTarget, float_bits(input), memory_order_relaxed);
    atomic_store_explicit(&engine->outputGainTarget, float_bits(output), memory_order_relaxed);
}
void ABEngineInitialGains(ABEngine *engine, float input, float output, uint32_t rampFrames) {
    if (!engine || engine->inputProc || engine->outputProc) return;
    ABEngineSetGains(engine, input, output);
    engine->inputGain = (ABGainRamp){ .current = bits_float(atomic_load(&engine->inputGainTarget)), .target = bits_float(atomic_load(&engine->inputGainTarget)) };
    engine->outputGain = (ABGainRamp){ .current = bits_float(atomic_load(&engine->outputGainTarget)), .target = bits_float(atomic_load(&engine->outputGainTarget)) };
    engine->rampFrames = rampFrames;
}
static void apply_gain(float *samples, uint32_t frames, ABGainRamp *ramp, float target, uint32_t rampFrames, ABEngine *engine) {
    if (target != ramp->target) ABGainRetarget(ramp, target, rampFrames);
    for (uint32_t i = 0; i < frames; ++i) {
        float gain = ABGainNext(ramp);
        for (uint32_t lane = 0; lane < 2; ++lane) {
            float sample = samples[i * 2 + lane] * gain;
            if (!isfinite(sample)) { sample = 0; atomic_fetch_add_explicit(&engine->formatFaults, 1, memory_order_relaxed); }
            samples[i * 2 + lane] = sample;
        }
    }
}
static void publish_levels(ABEngine *engine, ABLevels levels, bool input) {
    atomic_store_explicit(input ? &engine->inputPeak1 : &engine->outputPeak1, float_bits(levels.peak1), memory_order_relaxed);
    atomic_store_explicit(input ? &engine->inputPeak2 : &engine->outputPeak2, float_bits(levels.peak2), memory_order_relaxed);
    atomic_fetch_add_explicit(input ? &engine->inputClips1 : &engine->outputClips1, levels.clips1, memory_order_relaxed);
    atomic_fetch_add_explicit(input ? &engine->inputClips2 : &engine->outputClips2, levels.clips2, memory_order_relaxed);
}

// C-only callbacks: no ARC, Swift exclusivity, allocation, locking, UI, logging or HAL property reads.
static OSStatus input_callback(AudioObjectID device, const AudioTimeStamp *now,
    const AudioBufferList *input, const AudioTimeStamp *inputTime,
    AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    (void)device; (void)now; (void)output; (void)outputTime;
    ABEngine *engine = context;
    atomic_fetch_add_explicit(&engine->inFlight, 1, memory_order_acquire);
    if (atomic_load_explicit(&engine->enabled, memory_order_acquire)) {
        uint32_t frames;
        record_clock_rate(engine, inputTime, true);
        atomic_fetch_add_explicit(&engine->inputCallbacks, 1, memory_order_relaxed);
        if (ABRoutingFrames(engine->routing, input, true, &frames) && frames <= engine->scratchFrames) {
            uint64_t faults = 0, rawL = 0, rawR = 0;
            ABRoutingMix(engine->routing, input, engine->inputScratch, frames, engine->rampFrames, &faults, &rawL, &rawR);
            atomic_fetch_add_explicit(&engine->formatFaults, faults, memory_order_relaxed);
            atomic_fetch_add_explicit(&engine->rawInputClips1, rawL, memory_order_relaxed);
            atomic_fetch_add_explicit(&engine->rawInputClips2, rawR, memory_order_relaxed);
            apply_gain(engine->inputScratch, frames, &engine->inputGain,
                bits_float(atomic_load_explicit(&engine->inputGainTarget, memory_order_relaxed)), engine->rampFrames, engine);
            publish_levels(engine, ABMeasureStereo(engine->inputScratch, frames), true);
            uint32_t written = engine->au ? ABAUCaptureWrite(engine->au, engine->inputScratch, frames)
                : ABRingWrite(engine->ring, engine->inputScratch, frames);
            atomic_fetch_add_explicit(&engine->inputFrames, written, memory_order_relaxed);
            atomic_fetch_add_explicit(&engine->overrunFrames, frames - written, memory_order_relaxed);
        } else {
            atomic_fetch_add_explicit(&engine->formatFaults, 1, memory_order_relaxed);
            atomic_fetch_add_explicit(&engine->layoutFaults, 1, memory_order_relaxed);
        }
    }
    atomic_fetch_sub_explicit(&engine->inFlight, 1, memory_order_release);
    return noErr;
}
static OSStatus output_callback(AudioObjectID device, const AudioTimeStamp *now,
    const AudioBufferList *input, const AudioTimeStamp *inputTime,
    AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    (void)device; (void)now; (void)input; (void)inputTime;
    ABEngine *engine = context;
    atomic_fetch_add_explicit(&engine->inFlight, 1, memory_order_acquire);
    // HAL supplies zeroed output buffers (AudioHardware.h). Unselected lanes remain untouched.
    if (atomic_load_explicit(&engine->enabled, memory_order_acquire)) {
        record_clock_rate(engine, outputTime, false);
        atomic_fetch_add_explicit(&engine->outputCallbacks, 1, memory_order_relaxed);
        uint32_t frames;
        if (ABRoutingFrames(engine->routing, output, false, &frames) && frames <= engine->scratchFrames) {
            ABLevels levels = {0};
            ABAUQueueMetrics queued = engine->au ? ABAUTransportQueues(engine->au)
                : (ABAUQueueMetrics){ .outputFrames = ABRingAvailable(engine->ring) };
            if (!engine->au) queued.pendingFrames = queued.outputFrames;
            // Reserve is left AFTER rendering a callback; FIR demand includes retained history.
            engine->driftTarget = engine->prefill + frames + engine->inputBuffer * 0.5;
            double ratio = 1 + engine->drift.ppm * 0.000001;
            uint32_t needed = ABResamplerInputNeeded(engine->resampler, frames, ratio);
            atomic_store_explicit(&engine->refillThresholdFrames, engine->prefill + needed, memory_order_relaxed);
            atomic_store_explicit(&engine->appliedDriftPPMBits, 0, memory_order_relaxed);
            if (!atomic_load_explicit(&engine->primed, memory_order_relaxed)
                && queued.outputFrames >= engine->prefill + needed) {
                ABDriftReanchor(&engine->drift, engine->driftTarget);
                atomic_store_explicit(&engine->primed, true, memory_order_release);
            }
            if (atomic_load_explicit(&engine->primed, memory_order_relaxed)) {
                // Hold only for poor processed delivery with excess conserved backlog.
                // A genuinely low total must still learn slower consumption.
                bool held = ABDriftShouldHold(queued.pendingFrames, engine->driftTarget, queued.outputFrames, needed, engine->prefill);
                if (!held) {
                    ratio = ABDriftStep(&engine->drift,
                        queued.pendingFrames,
                        engine->driftTarget, engine->sampleRate, frames);
                    if (engine->drift.saturated) atomic_fetch_add_explicit(&engine->driftSaturatedCallbacks, 1, memory_order_relaxed);
                } else atomic_fetch_add_explicit(&engine->driftHeldCallbacks, 1, memory_order_relaxed);
                atomic_store_explicit(&engine->driftPPMBits, float_bits((float)engine->drift.ppm), memory_order_relaxed);
                if (queued.outputFrames > engine->scratchFrames * 9 / 10) {
                    uint32_t keep = engine->prefill + frames + ABResamplerLookahead();
                    if (queued.outputFrames > keep) {
                        uint32_t discard = queued.outputFrames - keep;
                        if (discard > engine->scratchFrames) discard = engine->scratchFrames;
                        uint32_t removed = source_read(engine, engine->outputScratch, discard);
                        queued.outputFrames -= removed;
                        atomic_fetch_add_explicit(&engine->recenterFrames, removed, memory_order_relaxed);
                        ABResamplerReset(engine->resampler);
                        ABDriftReanchor(&engine->drift, engine->driftTarget);
                    }
                }
                // A positive correction can need one extra source frame. Prefer a complete
                // unity callback to avoidable starvation; retain the bounded PI command.
                if (ratio > 1 && ABResamplerInputNeeded(engine->resampler, frames, ratio) > queued.outputFrames
                    && ABResamplerInputNeeded(engine->resampler, frames, 1) <= queued.outputFrames) {
                    ratio = 1;
                    atomic_fetch_add_explicit(&engine->driftLimitedCallbacks, 1, memory_order_relaxed);
                }
                atomic_store_explicit(&engine->appliedDriftPPMBits, float_bits((float)((ratio - 1) * 1e6)), memory_order_relaxed);
                uint32_t read = ABResamplerProcess(engine->resampler, source_read, engine, engine->outputScratch, frames, ratio);
                apply_gain(engine->outputScratch, frames, &engine->outputGain,
                    bits_float(atomic_load_explicit(&engine->outputGainTarget, memory_order_relaxed)), engine->rampFrames, engine);
                uint64_t faults = 0, clips = 0; float peak = 0;
                ABRoutingFanout(engine->routing, engine->outputScratch, output, frames, engine->rampFrames, &faults, &peak, &clips);
                atomic_fetch_add_explicit(&engine->formatFaults, faults, memory_order_relaxed);
                atomic_store_explicit(&engine->physicalOutputPeak, float_bits(peak), memory_order_relaxed);
                atomic_fetch_add_explicit(&engine->physicalOutputClips, clips, memory_order_relaxed);
                levels = ABMeasureStereo(engine->outputScratch, frames);
                atomic_fetch_add_explicit(&engine->outputFrames, read, memory_order_relaxed);
                atomic_fetch_add_explicit(&engine->underrunFrames, frames - read, memory_order_relaxed);
                if (engine->au && read < frames) ABAUTransportRecordStarvation(engine->au, frames - read);
                if (read < frames || ABResamplerStarved(engine->resampler)) {
                    atomic_store_explicit(&engine->primed, false, memory_order_release);
                    atomic_fetch_add_explicit(&engine->rebufferEvents, 1, memory_order_relaxed);
                    ABDriftReanchor(&engine->drift, engine->driftTarget);
                }
            } else if (atomic_load_explicit(&engine->rebufferEvents, memory_order_relaxed) > 0) {
                atomic_fetch_add_explicit(&engine->underrunFrames, frames, memory_order_relaxed);
            }
            publish_levels(engine, levels, false);
        } else {
            atomic_fetch_add_explicit(&engine->formatFaults, 1, memory_order_relaxed);
            atomic_fetch_add_explicit(&engine->layoutFaults, 1, memory_order_relaxed);
        }
    }
    atomic_fetch_sub_explicit(&engine->inFlight, 1, memory_order_release);
    return noErr;
}
ABEngine *ABEngineCreate(AudioDeviceID input, AudioDeviceID output, uint32_t capacity, uint32_t prefill) {
    if (!input || !output || input == output
        || prefill == 0 || prefill >= capacity) return NULL;
    ABEngine *engine = calloc(1, sizeof(*engine));
    if (!engine) return NULL;
    engine->ring = ABRingCreate(capacity);
    engine->resampler = ABResamplerCreate();
    engine->inputScratch = calloc((size_t)capacity * 2, sizeof(float));
    engine->outputScratch = calloc((size_t)capacity * 2, sizeof(float));
    engine->scratchFrames = capacity; engine->prefill = prefill;
    engine->inputDevice = input; engine->outputDevice = output;
    atomic_init(&engine->enabled, false); atomic_init(&engine->primed, false);
    atomic_init(&engine->inFlight, 0);
    atomic_init(&engine->inputCallbacks, 0); atomic_init(&engine->outputCallbacks, 0);
    atomic_init(&engine->inputFrames, 0); atomic_init(&engine->outputFrames, 0);
    atomic_init(&engine->underrunFrames, 0); atomic_init(&engine->overrunFrames, 0); atomic_init(&engine->formatFaults, 0);
    atomic_init(&engine->layoutFaults, 0);
    atomic_init(&engine->inputPeak1, 0); atomic_init(&engine->inputPeak2, 0);
    atomic_init(&engine->outputPeak1, 0); atomic_init(&engine->outputPeak2, 0);
    atomic_init(&engine->inputClips1, 0); atomic_init(&engine->inputClips2, 0);
    atomic_init(&engine->outputClips1, 0); atomic_init(&engine->outputClips2, 0);
    atomic_init(&engine->inputGainTarget, float_bits(1)); atomic_init(&engine->outputGainTarget, float_bits(1));
    atomic_init(&engine->rawInputClips1, 0); atomic_init(&engine->rawInputClips2, 0);
    engine->inputGain = (ABGainRamp){ .current = 1, .target = 1 };
    engine->outputGain = (ABGainRamp){ .current = 1, .target = 1 };
    engine->rampFrames = 960;
    engine->sampleRate = 48000; engine->inputBuffer = 512; engine->driftTarget = prefill + 17 + 256;
    atomic_init(&engine->driftPPMBits, 0); atomic_init(&engine->physicalOutputPeak, 0);
    atomic_init(&engine->inputClockAnchorSample, 0); atomic_init(&engine->inputClockAnchorHost, 0);
    atomic_init(&engine->outputClockAnchorSample, 0); atomic_init(&engine->outputClockAnchorHost, 0);
    atomic_init(&engine->inputClockRateBits, 0); atomic_init(&engine->outputClockRateBits, 0);
    atomic_init(&engine->inputClockAnchorValid, false); atomic_init(&engine->outputClockAnchorValid, false);
    atomic_init(&engine->inputClockRateValid, false); atomic_init(&engine->outputClockRateValid, false);
    atomic_init(&engine->measuredClockDifferenceBits, 0); atomic_init(&engine->measuredClockDifferenceValid, false);
    atomic_init(&engine->appliedDriftPPMBits, 0); atomic_init(&engine->refillThresholdFrames, 0);
    atomic_init(&engine->driftHeldCallbacks, 0); atomic_init(&engine->driftLimitedCallbacks, 0);
    atomic_init(&engine->driftSaturatedCallbacks, 0);
    atomic_init(&engine->physicalOutputClips, 0); atomic_init(&engine->recenterFrames, 0); atomic_init(&engine->rebufferEvents, 0);
    if (!engine->ring || !engine->resampler || !engine->inputScratch || !engine->outputScratch
        || !atomic_is_lock_free(&engine->enabled) || !atomic_is_lock_free(&engine->primed)
        || !atomic_is_lock_free(&engine->inFlight) || !atomic_is_lock_free(&engine->inputCallbacks)
        || !atomic_is_lock_free(&engine->inputPeak1) || !atomic_is_lock_free(&engine->inputClips1)
        || !atomic_is_lock_free(&engine->appliedDriftPPMBits) || !atomic_is_lock_free(&engine->refillThresholdFrames)
        || !atomic_is_lock_free(&engine->driftHeldCallbacks) || !atomic_is_lock_free(&engine->driftLimitedCallbacks)
        || !atomic_is_lock_free(&engine->layoutFaults)
        || !atomic_is_lock_free(&engine->inputClockAnchorSample)
        || !atomic_is_lock_free(&engine->measuredClockDifferenceBits)
        || !atomic_is_lock_free(&engine->inputClockAnchorValid)
        || !atomic_is_lock_free(&engine->driftSaturatedCallbacks)) {
        ABEngineDestroy(engine); return NULL;
    }
    return engine;
}
OSStatus ABEngineStart(ABEngine *engine) {
    if (!engine || !engine->routing || engine->inputProc || engine->outputProc) return kAudioHardwareIllegalOperationError;
    OSStatus status = noErr;
    engine->exclusiveFailureDevice = 0;
    if (engine->exclusiveRequested) {
        AudioObjectPropertyAddress address = { kAudioDevicePropertyHogMode, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        AudioDeviceID devices[] = { engine->inputDevice, engine->outputDevice };
        bool *held[] = { &engine->inputHogHeld, &engine->outputHogHeld };
        for (uint32_t i = 0; i < 2; ++i) {
            pid_t owner = -1; UInt32 size = sizeof(owner);
            if (!AudioObjectHasProperty(devices[i], &address)
                || AudioObjectGetPropertyData(devices[i], &address, 0, NULL, &size, &owner) != noErr) {
                status = kAudioHardwareUnsupportedOperationError; engine->exclusiveFailureDevice = i + 1; break;
            }
            if (owner == getpid()) { *held[i] = true; continue; }
            if (owner != -1) { status = kAudioHardwareIllegalOperationError; engine->exclusiveFailureDevice = i + 1; break; }
            Boolean settable = false;
            if (AudioObjectIsPropertySettable(devices[i], &address, &settable) != noErr || !settable) {
                status = kAudioHardwareUnsupportedOperationError; engine->exclusiveFailureDevice = i + 1; break;
            }
            // Hog mode is a toggle; read back the owner instead of assuming success.
            status = AudioObjectSetPropertyData(devices[i], &address, 0, NULL, sizeof(owner), &owner);
            if (status == noErr) { size = sizeof(owner); status = AudioObjectGetPropertyData(devices[i], &address, 0, NULL, &size, &owner); }
            if (status != noErr || owner != getpid()) {
                if (status == noErr) status = kAudioHardwareIllegalOperationError;
                engine->exclusiveFailureDevice = i + 1; break;
            }
            *held[i] = true;
        }
        if (status != noErr) {
            for (int i = 1; i >= 0; --i) {
                if (!*held[i]) continue;
                pid_t owner = -1; UInt32 size = sizeof(owner);
                if (AudioObjectGetPropertyData(devices[i], &address, 0, NULL, &size, &owner) != noErr || owner != getpid()) {
                    *held[i] = false;
                    continue;
                }
                if (AudioObjectSetPropertyData(devices[i], &address, 0, NULL, sizeof(owner), &owner) == noErr) {
                    size = sizeof(owner);
                    if (AudioObjectGetPropertyData(devices[i], &address, 0, NULL, &size, &owner) == noErr && owner != getpid())
                        *held[i] = false;
                }
            }
            return status;
        }
    }
    status = AudioDeviceCreateIOProcID(engine->inputDevice, input_callback, engine, &engine->inputProc);
    if (status != noErr) return status;
    status = AudioDeviceCreateIOProcID(engine->outputDevice, output_callback, engine, &engine->outputProc);
    if (status != noErr) return status;
    atomic_store_explicit(&engine->enabled, true, memory_order_release);
    // Output can wait silently for priming. Starting capture first lets a
    // slow output-device startup fill/overflow queues before any consumption.
    status = AudioDeviceStart(engine->outputDevice, engine->outputProc);
    if (status != noErr) { atomic_store_explicit(&engine->enabled, false, memory_order_release); return status; }
    engine->outputStarted = true;
    status = AudioDeviceStart(engine->inputDevice, engine->inputProc);
    if (status != noErr) { atomic_store_explicit(&engine->enabled, false, memory_order_release); return status; }
    engine->inputStarted = true;
    return noErr;
}
void ABEngineSetExclusiveAccessRequested(ABEngine *engine, bool requested) {
    if (engine && !engine->inputProc && !engine->outputProc) engine->exclusiveRequested = requested;
}
uint32_t ABEngineExclusiveAccessMask(const ABEngine *engine) {
    if (!engine) return 0;
    return (engine->inputHogHeld ? 1u : 0u) | (engine->outputHogHeld ? 2u : 0u);
}
uint32_t ABEngineExclusiveFailureDevice(const ABEngine *engine) {
    return engine ? engine->exclusiveFailureDevice : 0;
}
OSStatus ABEngineStop(ABEngine *engine) {
    if (!engine) return noErr;
    atomic_store_explicit(&engine->enabled, false, memory_order_release);
    OSStatus first = noErr;
    AudioDeviceIOProcID *procs[] = { &engine->outputProc, &engine->inputProc };
    AudioDeviceID devices[] = { engine->outputDevice, engine->inputDevice };
    bool *started[] = { &engine->outputStarted, &engine->inputStarted };
    for (int i = 0; i < 2; ++i) {
        if (!*procs[i]) continue;
        if (*started[i]) {
            OSStatus status = AudioDeviceStop(devices[i], *procs[i]);
            if (status != noErr && first == noErr) first = status;
            if (status == noErr) *started[i] = false;
        }
        OSStatus status = AudioDeviceDestroyIOProcID(devices[i], *procs[i]);
        if (status == noErr) { *procs[i] = NULL; *started[i] = false; }
        else if (first == noErr) first = status;
    }
    // Wait only on the lifecycle queue, after detaching registrations. Never wait in a callback.
    if (!engine->inputProc && !engine->outputProc) {
        for (int i = 0; i < 1000 && atomic_load_explicit(&engine->inFlight, memory_order_acquire); ++i) usleep(1000);
        if (atomic_load_explicit(&engine->inFlight, memory_order_acquire) && first == noErr)
            first = kAudioHardwareUnspecifiedError;
        if (!atomic_load_explicit(&engine->inFlight, memory_order_acquire)) {
            AudioObjectPropertyAddress address = { kAudioDevicePropertyHogMode, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
            AudioDeviceID devices[] = { engine->inputDevice, engine->outputDevice };
            bool *held[] = { &engine->inputHogHeld, &engine->outputHogHeld };
            for (int i = 1; i >= 0; --i) {
                if (!*held[i]) continue;
                pid_t owner = -1; UInt32 size = sizeof(owner);
                OSStatus status = AudioObjectGetPropertyData(devices[i], &address, 0, NULL, &size, &owner);
                if (status == noErr && owner == getpid()) {
                    status = AudioObjectSetPropertyData(devices[i], &address, 0, NULL, sizeof(owner), &owner);
                    if (status == noErr) {
                        size = sizeof(owner);
                        status = AudioObjectGetPropertyData(devices[i], &address, 0, NULL, &size, &owner);
                        if (status == noErr && owner == getpid()) status = kAudioHardwareIllegalOperationError;
                    }
                }
                if (status == noErr) *held[i] = false;
                else if (first == noErr) first = status;
            }
        }
    }
    return first;
}
bool ABEngineDestroy(ABEngine *engine) {
    if (!engine) return true;
    (void)ABEngineStop(engine);
    if (engine->inputProc || engine->outputProc || engine->inputHogHeld || engine->outputHogHeld
        || atomic_load_explicit(&engine->inFlight, memory_order_acquire))
        return false; // Keep callbacks context alive on failed unregister/teardown.
    ABRingDestroy(engine->ring); ABResamplerDestroy(engine->resampler); ABRoutingDestroy(engine->routing); free(engine->inputScratch); free(engine->outputScratch); free(engine);
    return true;
}
ABMetrics ABEngineMetrics(const ABEngine *engine) {
    ABMetrics result = {0};
    if (!engine) return result;
#define AB_LOAD(field) result.field = atomic_load_explicit(&engine->field, memory_order_relaxed)
    AB_LOAD(inputCallbacks); AB_LOAD(outputCallbacks); AB_LOAD(inputFrames); AB_LOAD(outputFrames);
    AB_LOAD(underrunFrames); AB_LOAD(overrunFrames); AB_LOAD(formatFaults); AB_LOAD(layoutFaults); AB_LOAD(primed);
#undef AB_LOAD
    result.bufferedFrames = engine->au ? ABAUTransportSnapshot(engine->au).outputFrames : ABRingAvailable(engine->ring);
    result.inputLevels.peak1 = bits_float(atomic_load_explicit(&engine->inputPeak1, memory_order_relaxed));
    result.inputLevels.peak2 = bits_float(atomic_load_explicit(&engine->inputPeak2, memory_order_relaxed));
    result.outputLevels.peak1 = bits_float(atomic_load_explicit(&engine->outputPeak1, memory_order_relaxed));
    result.outputLevels.peak2 = bits_float(atomic_load_explicit(&engine->outputPeak2, memory_order_relaxed));
    result.inputLevels.clips1 = atomic_load_explicit(&engine->inputClips1, memory_order_relaxed);
    result.inputLevels.clips2 = atomic_load_explicit(&engine->inputClips2, memory_order_relaxed);
    result.outputLevels.clips1 = atomic_load_explicit(&engine->outputClips1, memory_order_relaxed);
    result.outputLevels.clips2 = atomic_load_explicit(&engine->outputClips2, memory_order_relaxed);
    result.rawInputClips1 = atomic_load_explicit(&engine->rawInputClips1, memory_order_relaxed);
    result.rawInputClips2 = atomic_load_explicit(&engine->rawInputClips2, memory_order_relaxed);
    result.driftPPM = bits_float(atomic_load_explicit(&engine->driftPPMBits, memory_order_relaxed));
    result.measuredClockDifferencePPM = bits_float(atomic_load_explicit(&engine->measuredClockDifferenceBits, memory_order_relaxed));
    result.clockEstimateValid = atomic_load_explicit(&engine->measuredClockDifferenceValid, memory_order_acquire);
    result.appliedDriftPPM = bits_float(atomic_load_explicit(&engine->appliedDriftPPMBits, memory_order_relaxed));
    result.refillThresholdFrames = atomic_load_explicit(&engine->refillThresholdFrames, memory_order_relaxed);
    result.driftHeldCallbacks = atomic_load_explicit(&engine->driftHeldCallbacks, memory_order_relaxed);
    result.driftLimitedCallbacks = atomic_load_explicit(&engine->driftLimitedCallbacks, memory_order_relaxed);
    result.driftSaturatedCallbacks = atomic_load_explicit(&engine->driftSaturatedCallbacks, memory_order_relaxed);
    result.recenterFrames = atomic_load_explicit(&engine->recenterFrames, memory_order_relaxed);
    result.rebufferEvents = atomic_load_explicit(&engine->rebufferEvents, memory_order_relaxed);
    result.physicalOutputPeak = bits_float(atomic_load_explicit(&engine->physicalOutputPeak, memory_order_relaxed));
    result.physicalOutputClips = atomic_load_explicit(&engine->physicalOutputClips, memory_order_relaxed);
    return result;
}
