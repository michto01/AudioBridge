# Continuous DSP and whole-pipeline audit — 0.6.2 / build 35

## Operator evidence, not a reproduced run

The supplied 0.6.1 status uses MacBook Pro Microphone → External Headphones, 48 kHz, input 128 / output 32 / reserve 128 / AU 64, with EverClean → COMPER → SSQ. Recent delivery was healthy for 120.58 seconds: zero underruns, no late worker wakes, no over-budget blocks, workgroup join accepted and no interval failures. Whole-block last/mean/max were 0.06/0.14/0.91 ms against a 1.33 ms nominal throughput budget. This supports continuing with AU 64 for those devices/plugins; it does not prove indefinite reliability or isolate CPU consumption.

Lifetime counters still contain 1,920 rejected capture frames (40 ms of input) and 1,631 source frames discarded by recentering (33.98 ms). The snapshot contains no event timeline establishing their cause. Per-plugin timing counts differ from whole-chain counts because slot adoption resets the plugin window; do not add their means as if measured over the same window.

Clock difference 0.09 ppm and command 0.06 ppm give no evidence of a large physical clock mismatch in this run. Device-reported delay is 35.06 ms, including 29.98 ms from the microphone stream; bridge/callback allowances are 8.35 ms. The 43.42 ms known subtotal is estimated accounting, not a measured physical transit time. Changing FIFO or AU block size cannot remove device-reported microphone processing latency.

## Changes and reviewed invariants

| Pipeline area | Finding / action |
| --- | --- |
| Device selection and formats | UID/physical-channel topology remains explicit; native packed Float32 and matching nominal/stream rates are required. Unsupported layouts/rates fail without defaults. Independent device buffers remain valid. |
| Startup | Input previously started before output. A slow output startup could accumulate/drop capture before consumption. Start output first; unprimed output waits silently, then capture begins. Both start-failure paths retain safe teardown. This removes that source-level risk; it does not establish the cause of the operator's earlier drops. |
| Capture/mix/trim | Preallocated C buffers, bounded topology and 20 ms gain ramps. Nonfinite routed/trimmed samples fault; full-scale levels are separate. No HAL allocation, AU render call, UI, property query or blocking wait added. |
| SPSC transport | Capture/worker/output each own their producer or consumer index. Release/acquire publication protects samples; modulo unsigned indices support wrap. Separate capture/ready queues and in-flight work are accounted by conserved accepted capture minus consumed source, rather than adding reserve twice. Retain the paired arm/recheck fences and coalesced semaphore wake protocol. Source inspection is not a concurrency stress test. |
| AU batching | Automatic now uses half the larger device buffer, rounded down to a power of two within 16–256. Input 128 / output 32 yields AU 64. Two smaller renders can publish the first portion earlier in a capture burst. This adds per-block calls/workgroup overhead and can overload or be rejected by another plugin. Saved explicit sizes and the reserve/capacity remain unchanged. |
| Live DSP switch | Keep transport attached throughout the route. Start-off prepares an empty renderer without loading saved plugins. First enable prepares/adopts saved units while dry audio continues; successful adoption reconciles the latest request. No switch calls Stop/Start or clears queued audio. Manual Stop invalidates pending responses by generation. |
| Fade/suspension | Render-thread-owned dry/wet mix ramps for 20 ms at the configured rate. DSP-off renders only until fade-out finishes, then forwards dry blocks without invoking plugins or creating a per-block autorelease pool. Bypass keeps rendering. Reversing the toggle uses the current mix, not a new discontinuous endpoint. Renderer adoption transfers mix ownership between blocks; retirement stays on AppKit's thread. |
| FIR/drift | Exact batched source demand and retained history/phase survive short reads. PI uses conserved occupancy with anti-windup and bounded slew; delivery-pressure hold remains distinct from genuinely low capture. Keep the existing bounds/filter; the supplied near-zero measured/commanded ppm gives no reason for speculative retuning. |
| Overflow/recentering | Recentering calls source_read to discard actual audio and resets FIR history. It was wrongly exempt from warnings as bookkeeping. A positive discard delta now reports the loss; five clean seconds still clear the current warning without changing lifetime counts. Rebuffer events alone do not claim loss. |
| Lifetime and supervision | In-flight accounting precedes callback work; disabled callbacks cannot touch processing state, and destruction requires successful detach/quiescence. Final telemetry uses copied pre-teardown values. Move startup grace, callback freshness/stall thresholds and device-check cadence from wall Date to monotonic uptime. Time/date adjustments cannot distort these checks. Device loss and unsafe detach retain explicit re-arm/restart policies. |
| Reporting/localization | Engine watchdog remains 20 Hz and informational publication 5 Hz. Change Czech audio frame units to vzorky/vzorků, retaining samples-per-channel semantics; queue snapshots are stavy front. Copy Status/remote contracts stay English. Help explains the persistent transport, fade and batching trade-offs. |

No additional package, recording, vendor-specific behavior or hardware write was introduced. The generic microphone-permission indicator icon remains deferred.

## Remaining practical limits

- Persistent transport means DSP-off still uses its helper thread/IPC queues; it is no longer a no-helper CPU baseline. Loaded plugins may continue their own editor/background activity even with render calls suspended. A helper failure remains a route fault.
- A sample ramp reduces abrupt switching but does not latency-align dry and wet paths or clear stored plugin tails. Effect-dependent combing/transients on switching are possible. Live chain replacement also does not crossfade the old and new plugin engines.
- Successful Mach/workgroup setup and short reported block times do not guarantee future deadlines. Third-party render/context/setup calls and auxiliary threads remain outside host control. Plugin setup may compete for CPU even though it does not stop HAL.
- Recenter recovery still discards source to bound queue growth; now its loss is visible. An initial short callback can be followed by refill silence, so underrun bursts include both. Storage capacity 1024 is not a 1024-frame latency target.
- Legacy units missing latency KVO can leave declared delay stale until editor close. Physical loopback latency, per-process CPU and worst-case delivery still require measurement.

## Actual build checks — 2026-10-13

- `make doctor` passed: Xcode, Swift 6.4, arm64 macOS 27.0 SDK; deployment minimum remains macOS 14.
- `make sign BUILD_CONFIGURATION=release DIST_DIR=/tmp/AudioBridge-0.6.2-final` passed, including release build, app packaging/plist lint and strict ad-hoc helper/app signing. Final incremental build was 3.53 seconds after the earlier 17.36/12.55/13.90-second successful iterations.
- `make verify DIST_DIR=/tmp/AudioBridge-0.6.2-final` passed: `cz.bytelab.audiobridge`, 0.6.2/build 35, macOS 14 minimum, AudioBridge.icns, English/Czech tables, identical embedded/bundle metadata and helper/app signatures. Bundle is `/tmp/AudioBridge-0.6.2-final/AudioBridge.app`; no running bundle was replaced.
- `git diff --check` passed. Build and app ran as signing prerequisites. `make test`, `make run`, live audio, plugin execution, CPU profiling and soak were not run.

## Deferred acceptance

No live audio, automated tests, app launch, plugin execution or soak were run for this revision. An existing RecentGlitches test's name/expectation was updated for actual recenter discards; no new test was added or executed.

Required checks:

1. Keep the operator's 128/32/128/AU64 settings. Compare empty chain, loaded DSP-off, each plugin, full chain and bypass using equal windows. Reset counters after startup, but retain a separate startup status to locate any initial loss. Measure main/helper CPU separately.
2. DSP-off start → enable saved chain → disable → enable, with rapid reversals, bypass on/off, editor open/closed and nonzero-latency effects. Confirm no HAL Stop/Start recovery events or runtime reset, no lost frames and acceptable audible transition. Rendering should cease after fade-out, while bypass rendering continues.
3. Toggle during startup, recovery, chain preparation/adoption and manual Stop. Last request must win; Stop/device-loss latch must prevent late responses from enabling or restarting the bridge. Failed requested chain preparation remains explicit.
4. Simulate slow output startup and second-device Start failure. Check silent priming, no capture-before-output backlog, complete detach and correct ownership. Adjust wall time in an isolated test to check monotonic freshness/grace/cadence.
5. Run deterministic SPSC wrap/wake races, source conservation, exact FIR demand/short reads, ramp endpoint/reversal, adoption lifetime and recent-loss clearing checks before the gate. Smaller-block acceptance must include plugins with internal FFT/buffering, not just one favorable chain.
6. Complete the 12-hour bounded occupancy/CPU/memory, zero-loss post-startup gate from [0.6 results](release-0.6-results.md), with physical loopback latency recorded separately. The supplied two-minute healthy interval does not pass that gate.
