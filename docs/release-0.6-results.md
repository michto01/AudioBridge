# Audio reliability revision — 0.6.0 / build 33

## Scope and evidence

The operator reports periodic losses only with inserted AU effects, including hundred-frame underrun bursts, and a useful manual combination of 128 input / 32 output / 128 FIFO reserve. These are operator observations, not reproduced measurements of this revision. Audio scheduling and reliability are the release focus; [ADR-003](decisions/ADR-003-reliability-and-operator-setup.md) records the approved stop/re-arm and operator setup changes.

## Pipeline review and corrections

| Area | Source finding / invariant | Change or retained behavior |
| --- | --- | --- |
| Fault teardown | Final diagnostics queried the local C context after successful teardown freed it. | Capture exclusive ownership, AU slot timing and starvation before stop; no post-stop C context access. Preserve the final fault snapshot. |
| Callback lifetime | Clock bookkeeping preceded the callback in-flight reference. | Increment lifetime accounting first and perform clocks only inside the enabled callback. Registered IOProc destruction and bounded quiescence still gate free. |
| Stop errors | A driver Stop OSStatus was treated like unsafe callback detach even after successful IOProc destruction. | Use actual retained-context ownership to distinguish confirmed detach from unsafe retention. Only unsafe detach requires process restart. |
| AU properties | Every plugin latency was queried on the editor thread at 10 Hz while DSP ran. Property calls can contend inside third-party units. | KVO marks a C atomic dirty flag; AppKit refreshes only on change or editor close. No property getter is introduced on the render thread. Legacy units omitting notifications may show stale declared latency until editor close. Improvement is unmeasured. |
| Render blocks | Render getter was cached before resource allocation; lazy pull property was read every render. | Cache render, pull and render-context blocks after resources are allocated. Keep plugin resource allocation/retirement off HAL. |
| Scheduling | Worker is asynchronous to independently clocked HAL endpoints, with signaled readiness and Mach policy. | Add its own AudioWorkIntervalCreate workgroup, join/leave on the same thread, and start/finish a deadline interval around each block. Cached plugin render-context observers receive this workgroup. Failure is reported and falls back; no device workgroup is guessed. |
| Queue ownership | One producer/consumer per shared ring; publish indices after samples, paired arm/recheck fences, coalesced semaphore signals. | Retain these invariants. No polling sleep, spinning, blocking wait, AU calls or setup allocation in HAL callbacks. Latest starvation event is fixed atomic storage. |
| FIR / drift | Exact callback demand is batch-read once; retained history/phase survive short reads; total pending frames conserve capture minus consumption. | Retain filter, PI bounds, anti-windup, two-second occupancy filter and refill logic. No speculative retuning based only on a ppm command. A hundred-frame loss can include subsequent refill silence after a smaller initial short callback. |
| Reporting | Whole-chain timing cannot isolate individual units. | Per-plugin identity/slot wall timing, block count/max/over-budget count, and the latest short-callback queue/stage/wake snapshot. These are clues, not proof of plugin fault or CPU utilization. |
| Remote acknowledgment | Success returns nil, but optional-self coalescing converted nil success to “App model unavailable”. | Explicitly guard model ownership and preserve nil success. Start rejects a device-loss safety latch. |

Workgroup deadlines are nominal block-throughput budgets, not measured physical output deadlines. Mach setup success does not confirm that the thread remains real-time under overload. Workgroup setup and interval errors are reported. Plugin-owned auxiliary threads must cooperate with the supplied context; the host cannot make arbitrary plugin internals real-time safe.

Per-plugin timing resets when a different effect instance occupies that slot. Reordering/replacing chains can restart a slot's window; inactive historical slots are excluded from the current UI. Per-plugin rows are for the run/slot, independently of Reset counters. Wall duration includes scheduling/preemption, so it does not establish plugin compute cost alone. The starvation report is one bounded latest event; it records the initial short output callback, not each subsequent silent refill. Concurrent queue/stage observations are approximate. The previous completed block/wake may precede the event and is not automatically its cause. No audio samples, parameter state or unbounded callback log is collected.

## Device loss and operator workflow

Selected UID disappearance, changed runtime identity/topology/rate/buffer or confirmed callback stall stops the route. UID checks occur on the lifecycle queue at 0.5-second intervals; callback stall checks use the existing two-second inactivity threshold after startup grace. This is not instant unplug detection. A persisted re-arm latch suppresses reconnect/relaunch/remote Start. Bridge offers Re-arm confirmation; checks require available, explicitly selected devices and valid configuration. Unsafe detach retains memory and also latches stopped intent. Other recoverable helper faults retain capped retry policy.

General contains opt-in device-error notifications and OS authorization status. Native notification delivery still depends on macOS permission, Focus and system policy. The red in-app error does not depend on those. Raw details are available behind the device-change info button and in Diagnostics. Notification permission is not requested automatically at startup.

Simple requests one common nominal rate and hardware buffer on both explicit devices while stopped. Rates are filtered against reported capabilities; read-only drivers can retain an already matching value. Rates are applied before buffer requests, and buffers are re-read because a rate change may reset them. Driver rejection/rounding/partial changes remain visible; Simple Start requires both current values to match. Partial writes are not rolled back automatically. Switching modes itself performs no hardware write. Balanced FIFO and automatic AU blocks are used; existing configured routes remain Expert, retaining independent drafts and saved FIFO/AU preferences. Expert drafts start from current device values, with 64-frame fallback. Actual input/output driver buffers remain independent properties even in Simple.

Expert AU blocks can be Automatic or 16/32/64/128/256/512/1024 frames, no larger than reserve. Automatic follows the larger device buffer and remains bounded at 256. The selected value sets maximumFramesToRender before allocation. Zero is invalid. Larger blocks can reduce overhead but increase batching delay; very small blocks can increase plugin/kernel overhead. No universal safe block size is claimed. The operator's 128/32/128 case can explicitly use AU 128.

General switches English/Czech; captions, numeric readouts, help, diagnostics and AU host controls use a shared localized resource target. Supplied device/plugin names, raw driver errors and vendor editor UI remain untouched. Copy Status and HTTP/OSC names/status remain English. Packaging puts resources in Contents/Resources; the CLI helper explicitly resolves the containing app's resources. No external package was added.

## Actual checks

- `make doctor`: passed. Xcode installed; Swift 6.4, arm64 host, macOS 27.0 SDK; package minimum remains macOS 14.0.
- Release `make build`: passed after fixing compiler-reported closure capture, variable shadowing, missing import and timing-array inference errors. No known compile error is deferred. Temporary SwiftPM scratch/module caches used outside File Provider storage.
- Final `make sign BUILD_CONFIGURATION=release DIST_DIR=/tmp/AudioBridge-0.6.0-final` passed on 2026-10-13: final release build 10.71 seconds, package/plist lint and ad-hoc helper/app signatures. The first signing attempt rejected an unsigned resource bundle placed in Helpers; corrected by sharing Contents/Resources with an explicit helper lookup. No active bundle was overwritten.
- `make verify DIST_DIR=/tmp/AudioBridge-0.6.0-final` passed after correcting its resource-path check for macOS bundle layout: `cz.bytelab.audiobridge`, 0.6.0/build 33, macOS 14 minimum, arm64, AudioBridge.icns, both localized tables, identical embedded/bundle plist and strict helper/app signatures. Ad-hoc identity has no TeamIdentifier/notarization.
- `git diff --check` passed. `make app` and `make build` also ran as prerequisites of `make sign`; `make test`, `make run`, release publishing and live app launch were not run.
- Tests, launching this revision, live device writes, unplug/re-arm/notification checks, plugin rendering, API/OSC runtime checks, Instruments profiling, CPU comparison, loopback latency and soak **not run**. Existing live audio was not interrupted. No new test source was added; deterministic and manual acceptance below is documented for the deferred gate.

## Deferred 0.6 acceptance

Use the same selected devices and route, input 128 / output 32 / reserve 128 / AU 128. Record build and reset measurement counters after startup; use equal windows, at least five minutes for initial comparisons. Measure main/helper CPU separately with Settings and editors both closed, then repeat with editors open.

| Comparison | Purpose |
| --- | --- |
| Stop/Start with effect processing off | Direct HAL/FIR/drift baseline, no helper or plugin load. |
| Processing enabled, empty chain | Transport/thread/workgroup overhead without plugin DSP. |
| One inserted plugin, processing off live | Loaded plugin/editor/background work without its render call. |
| Same plugin processing on | Add that plugin's DSP; inspect its identity timing and starvation evidence. |
| Same plugin with chain bypass | Rendering remains active; compare dry signal without confusing bypass with DSP-off. |
| Each plugin separately, then full chain | Isolate unit-specific versus combined chain workload. |
| AU 64/128/256 where reserve permits | Assess overhead/batching; increase reserve explicitly if needed, label the changed latency budget. |

Interpretation: high capture backlog with depleted ready audio and long render wall time suggests processing/preemption pressure; a large wake with short renders suggests worker scheduling pressure; depleted capture plus no in-flight render suggests capture/clock/queue pressure. None alone establishes causality. Compare direct/empty/loaded-off/active paths and audible output; use Audio System Trace/Time Profiler for attribution. Real loss counters remain losses even if hard to hear, and five clean seconds clear only the current display warning. A near-limit ppm command alone is not an error; timestamp clock difference and occupancy trend must also be examined.

Deterministic checks still required: queue wrap/capacity, arm/publication races in both orders, output-space wakes, interrupted waits/shutdown, exact FIR demand/short-read continuity, renderer adoption/retirement, pre-teardown fault reports, workgroup join/interval/leave pairing, plugin context replacement, latency dirty coalescing, explicit AU size/resource setup, Simple capability/readback/partial failure and persistence, and remote success/latch rejection. No tests were run for these.

Manual safety checks: unplug each endpoint while active (also while DSP off), change rate/buffer externally, stop callbacks, reconnect, relaunch with resume on, and try remote Start. Confirm stopped/latch, error detail, no substituted output, notification permission handling, and deliberate re-arm. Exercise Stop during preparation/retry/live insertion and both language modes. Check legacy AU latency changes while editor open/closed.

Final operational gate: 12-hour run at the accepted device/AU/reserve setting, bounded occupancy/CPU/memory, zero lost frames after the defined startup window, no crash or unsafe ownership event; repeat without plugins and with the deployment chain. Measure physical loopback latency separately. Hardware, sanitizer, CPU and soak gates remain pending. Stop for review; no unattended-readiness claim.
