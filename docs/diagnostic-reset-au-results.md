# Diagnostic reset and AU timing investigation — 0.5.6 / build 29

Implemented on 2026-10-12.

## Reset counters

Diagnostics exposes Reset counters whenever an engine snapshot exists. It captures a UI-only baseline and timestamp; displayed callbacks, captured/rendered/lost frames, format faults, drift event counts, rebuffer/recenter counts, AU processed/timed/over-budget counts, worker wait counts and full-scale sample counts become zero relative to that baseline. Mean AU processing time uses render nanoseconds and block counts accumulated after reset. Before new blocks arrive the mean is unavailable rather than a fabricated zero duration.

Current levels, queue occupancy, reserve, measured clock difference, commanded drift, declared latency and last-block time remain live. Maximum block time, maximum wake lateness and observed queue range retain lifetime values with explicit run labels. Copy Status includes a measurement-window section with reset timestamp and interval counts; the existing sections retain lifetime totals. A new routing attempt clears the baseline.

Engine counters, plugin sample timestamps, shared-memory queue indices and fault detection are untouched. Reset does not clear an active warning or change the five-second health recovery, restart the route, flush audio or reset clock correction. It is safe to use for comparison while bridging.

## AU findings from source inspection

- AudioBridgeEngine currently creates an AUHostContext even for an empty chain. That context starts the helper and attaches shared capture/output queues. The helper still reads/writes each block when it has no effects. Removing effects therefore removes plugin render calls, not the helper path.
- Renderer processes every stage through its cached AU render block, with stereo deinterleaving/interleaving and stage-buffer validation. Its recorded wall time includes all of this work and preemption, not only time executing third-party plugin DSP.
- Whole-chain bypass retains those render calls and forwards dry capture samples afterward. It preserves live editor feedback and is not equivalent to removing effects for CPU/deadline comparison.
- The worker checks for a full captured block and enough output space. When unavailable it calls usleep for approximately a quarter-block duration, clamped to 50–1000 microseconds. That requested wait does not guarantee wakeup timing. Existing diagnostics count wake lateness exceeding one block duration.
- AU block size follows the smaller of the FIFO reserve and larger device callback size, bounded to the existing 16–256-frame sizes. At 48 kHz, 32 frames provide about 0.667 ms between blocks; 64 frames provide about 1.333 ms. Work slower than the sustained production rate cannot be fixed by a larger FIFO indefinitely, while a reserve can cover transient delays.
- Diagnostics now exposes processing budget per block and explicitly identifies the processing path. It also converts interval underrun and overrun frame sums into milliseconds, separately; these sums are not the duration of a single audible dropout.

The operator reports clean delivery with effects removed. With the same buffers and route, that narrows the suspect area to plugin render work or hosting/scheduling costs introduced by loaded units. It does not prove an individual plugin bug or a host bug. No plugin-specific fault or timing correlation was measured this turn. No worker scheduling or audio algorithm change is claimed as a repair.

## Manual comparison

Keep devices, interface buffers and FIFO reserve unchanged. For each case, reset diagnostic counters, run for the same period (for example 30–60 seconds), and copy status: empty chain, one effect at a time, then the full chain. Removing effects is the meaningful dry comparison; bypass still renders them. Compare interval underrun/overrun counts, timed/over-budget blocks, interval mean processing time and late worker wakeups. Lifetime maxima remain explicitly labeled and should not be mistaken for interval maxima.

Rising over-budget counts suggest render/host work or preemption consumes the block allowance. Rising late-wakeup counts suggest worker scheduling delays. Either can be absorbed temporarily by reserve, and neither alone proves actual lost audio; delivery-loss counters remain the warning signal. Per-plugin timing and event-driven worker wakeup are possible subsequent improvements after this comparison identifies the dominant failure mode.

## Checks

- Release compilation passed using `make build BUILD_CONFIGURATION=release SWIFT_BUILD_OPTIONS='--disable-sandbox --scratch-path /tmp/audiobridge-build'` and `SWIFTPM_MODULECACHE_OVERRIDE=/tmp/audiobridge-swift-module-cache`.
- Final release packaging and ad-hoc signing passed: `make sign BUILD_CONFIGURATION=release DIST_DIR=/tmp/AudioBridge-release` with the same options.
- Bundle verification passed: `make verify DIST_DIR=/tmp/AudioBridge-release`. Version 0.5.6/build 29, bundle ID `cz.bytelab.audiobridge`, minimum macOS 14.0; embedded metadata matched and app/helper signatures verified.
- `git diff --check` passed.
- Automated tests, new-app launch, counter-reset UI acceptance, real audio/plugin comparisons and network checks were not run, following deferred manual acceptance. Phase 5 operational acceptance remains pending.
