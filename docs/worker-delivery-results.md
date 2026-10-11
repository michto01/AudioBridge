# AU worker delivery follow-up — 0.3.7 / build 16

## Scope and evidence

Continuation of the Phase 3 buffer/drift repair. The user authorized continuing; no new hardware status snapshot or confirmed build-15 audio result was supplied. Tests, app launches, real plugin execution and live audio checks remain deferred. This is not Phase 4 supervision or a completed underrun acceptance gate.

## Changes

- Replace the indefinitely occupied global Dispatch worker with one named, dedicated Foundation thread at userInteractive QoS. The helper loop owns rendering through shutdown. AppKit/editor and control polling remain on the main thread. QoS is a scheduling preference, not a real-time deadline guarantee; no Mach time-constraint policy or audio workgroup membership is claimed.
- Drain an autorelease pool after each helper-loop iteration to bound temporary Objective-C objects from plugin calls. No HAL callback creates or drains a pool. Existing helper-only synchronization and renderer retirement remain between blocks.
- Count AU blocks whose measured wall duration exceeds their audio duration (block frames / sample rate). Timing includes preemption inside processing, not just plugin CPU, and excludes driver locking, autorelease-pool cleanup and polling waits. It is not physical signal delay or the current FIFO depletion deadline.
- Measure helper polling wait elapsed time; count wake lateness exceeding one block duration. Lateness is max(0, elapsed - requested), so early returns cannot wrap. Maximum lateness and total waits are separate. A delayed wake may occur without an underrun, or while waiting for input/output space; this is diagnostic evidence, not attribution to a plugin or an audible glitch.
- Expose PI command, last callback's applied correction, held-controller callbacks, unity-limited callbacks and current refill threshold in Playback's Buffer delivery diagnostics and Copy status. While refilling, applied correction is zero because output is silent; this is not evidence of zero hardware skew. Counters do not trigger health warnings independently.
- Use a minimal three-field queue snapshot in HAL drift processing and helper readiness checks, plus single atomic getters for helper stop and timeline checks, avoiding loads of UI/timing counters on those hot paths.
- Extend the shared-memory ABI to version 4; app/helper must come from the same bundle. A mismatched mapping is rejected. New shared counters are initialized and checked for lock-free access. Configure the finite positive block budget before helper readiness, retain it through live chain replacement, and reset all counters with a new routing session.

No saved UID, physical routing patch, hardware buffer value or queue reserve is changed automatically. Bypass still processes effects and selects dry output.

## Deferred test sources

`AUChainTests.testTimingAccountingWithoutSleepingOrRendering` uses synthetic durations to cover render sum/last/max, strict over-budget boundaries, early wake saturation, late-wake classification, cross-mapping visibility and unknown-budget behavior. It does not sleep, render plugins or access hardware. Source written only; neither compiled as a test target nor executed.

## Manual acceptance still required

Quit the old instance and reopen `/tmp/AudioBridge-phase2/AudioBridge.app`, confirming build 16. Keep device buffers/reserve unchanged for a useful comparison. Collect full Copy status after equal-length runs with an empty chain, active effects and whole-chain bypass. Compare underrun/rebuffer deltas, capture/processed queues, AU over-budget blocks and polling wake lateness, alongside commanded/applied correction and hold/limit counts. Check audible continuity separately. UI/editing load and normal idle runs need comparison; cumulative counts alone do not establish sustained load or causality.

A dedicated ordinary thread and smaller processing blocks cannot guarantee 32-frame operation under arbitrary system/plugin load. Any future audio-workgroup or real-time scheduling change needs actual SDK/API validation, cross-process ownership/lifetime design, bounded workload and hardware acceptance. Extended drift and unattended-operation gates remain pending.

## Actual commands

- Final `make build`: passed, debug build complete in 3.64 s. Earlier intermediate debug builds also passed (3.85 s and 2.46 s).
- Final `make BUILD_CONFIGURATION=release DIST_DIR=/tmp/AudioBridge-phase2 sign`: passed, production build complete in 11.07 s; package/plist and ad-hoc helper/app signing passed. An earlier package build also passed (14.04 s) before the final helper getters.
- `make BUILD_CONFIGURATION=release DIST_DIR=/tmp/AudioBridge-phase2 verify`: passed. Identity cz.bytelab.audiobridge; executable AudioBridge; deployment 14.0; LSUIElement true; AudioBridge.icns; version 0.3.7/build 16. Embedded executable metadata matches bundle, arm64 helper/app signatures valid.
- `git diff --check`: passed.
- No tests, app launch, plugin rendering or live audio checks executed. No measured CPU or underrun improvement claimed.

One attempted Perl text edit could not start (`Bad CPU type in executable`); the same edit was completed using apply_patch. This is a local tool limitation, not a build or runtime failure.
