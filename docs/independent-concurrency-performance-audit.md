# Independent concurrency and performance audit — 2026-10-13

Audited source: **0.6.4/build 37, commit `1c2acef`**. The operator requested independent subagents with fresh context. Three read-only reviewers examined callback/transport lifetime, control-plane state/IPC, and realtime/UI performance. The primary agent checked the actionable paths against source and verified hog-mode semantics against the installed Apple SDK. No source fixes, new test execution, profiler attachment, plugin instantiation, app launch or hardware operation took place during this audit.

This audit does not invalidate the operator's reported clean run. It identifies edge cases that the existing 61 passing tests do not fully cover. No confirmed mutex cycle, lost-wakeup interleaving or callback use-after-free was found in the examined code; this is not proof of absence or an unattended-readiness certification.

## Correctness findings

P2 means a scoped functional failure/race that warrants correction; P3 means lower-priority redundant work. Line references refer to the audited commit.

### P2 — Failed live-editor save wedges the AU command channel

`Sources/AudioBridgeAUWorker/Editor.swift:110–126`, `LiveHost.swift:124–157`, `Sources/AudioBridgeEngine/AUHostContext.swift:100`.

An edit command keeps the helper busy until editor completion. Invalid property-list state or the 8 MB state limit throws during save; the catch only replaces window contents with error text. It does not finish `liveCompletion`, clear helper busy or release the parent's pending edit. Edit commands deliberately have no timeout while the editor is open. Render heartbeat continues, so audio health does not reveal this control-channel wedge. Closing the window can hide the retained editor; the parent close action repeats the same failing save.

Complete the command exactly once with an error and clean up on failed close, retaining the previous saved state. Alternatively, offer a discard action that closes and replies. Test serialization/size failures, red-window close and explicit close, then assert another edit/update can execute. High confidence from source; no plugin reproduction.

### P2 — Stop can arrive after the last cancellation check but before HAL start

`Sources/AudioBridgeEngine/AUHostContext.swift:52–55`, `AudioBridgeEngine.swift:161–162`, `AudioBridgeEngine.swift:194–201`.

Preparation reads cancellation false and returns on ready. Stop then sets cancellation true and queues teardown; the existing start closure still proceeds to `ABEngineStart` because it does not check again. Its serial queue processes teardown afterward. Route generations suppress stale UI results, but not this intervening device start.

Add an attempt-specific cancellation check before starting. A check alone narrows rather than eliminates the check/start race; if immediate Stop must suppress all intervening output, use an independently clearable output-enable gate with a precisely defined start/stop linearization point. Never hold the Swift lock across HAL calls. Test a paused ready-to-start transition and Stop before releasing it. High confidence in source interleaving; physical consequence not reproduced.

### P2 — Remote service shutdown does not invalidate accepted requests

`Sources/AudioBridge/RemoteControl.swift:55`, `:63`, `:204–214`, `:263–271`.

Shutdown cancels listeners, but accepted connections are not tracked/cancelled. Acceptance/receive/dispatch paths have no service-enabled or listener-generation gate. An HTTP request accepted before shutdown can finish afterward and execute an authenticated command; accepted OSC connections or queued callbacks have the same lifecycle gap. Bearer authentication and OSC source allowlisting still apply: this is not a finding of unauthenticated access.

Track/cancel connections per service and gate acceptance and dispatch by enabled state plus generation. Test a partially received authenticated request completed after disable and an obsolete callback after restart.

### P2 — Obsolete listener callbacks can overwrite current service status

`Sources/AudioBridge/RemoteControl.swift:131–135`, `:144–153`.

An old listener's cancelled callback can enqueue a MainActor write after the replacement's ready callback, showing stopped while the replacement listens. Capture generation/listener identity and reject obsolete callbacks, including feedback status callbacks. Test generation-two ready followed by generation-one cancelled. Source-supported race, not reproduced.

### P2 — OSC integer bypass-on is decoded as floating-point bits

`Sources/AudioBridge/RemoteControl.swift:294–305`.

The shared `number()` reader always uses `Float(bitPattern:)`. OSC integer 1 therefore becomes a tiny nonzero float, failing the exact 0/1 guard; integer 0 works. Decode signed big-endian Int32 for `i` and IEEE float for `f`. Add canonical bypass 0/1/invalid-integer packets and float-gain regressions. Deterministic source defect; no live remote request issued.

## Performance opportunities

Benefits are unmeasured. Preserve callback bounds, gain ramps, drift history and safety monitoring while optimizing.

1. **P2 — Broad capability probes on the lifecycle queue twice per second.** `AudioBridgeEngine.swift:299–302`, `Sources/AudioBridgeDiscovery/CoreAudioCatalog.swift:94–197`. Selected endpoints still fetch static name/icon/ranges/layouts and available formats. Introduce a narrow runtime routing probe for identity, liveness, current rates/buffers/topology and necessary latency facts. Keep full scans for setup and preserve duplicate-UID handling. This also reduces potential driver-query delays to Stop/supervision. Output-volume reads/writes currently use unfiltered full catalog snapshots (`CoreAudioCatalog.swift:16`, `:37`); narrow these while retaining fresh UID validation.
2. **P2 — Sparse routing still traverses all physical channels per frame.** `Sources/AudioBridgeRealtime/StereoRouting.c:90–123`. Use preallocated callback-owned active-or-ramping indices; retain channels through fade-out and explicitly zero unpatched output lanes. The benefit is mainly for wide devices, not established for the operator's mono/stereo hardware.
3. **P2 — AU timing excludes parts of render-thread delivery work.** `Sources/AudioBridgeAUWorker/Worker.swift:201`, `LiveHost.swift:37–55`. Existing block timing ends before the surrounding autorelease pool drains; adoption and foreign render-context observer calls precede it. Add separately labeled complete worker-cycle/adoption timings rather than pretending DSP timing includes these. Preserve pools for legacy plugin temporary lifetime. Slow drains/hooks are hypotheses, not observed bottlenecks.
4. **P3 — Repeated FIR demand simulation.** `AudioBridgeRealtime.c:280`, `:313–319`, `AdaptiveDSP.c:66–83`. Demand walks output frames ordinarily twice and potentially four times per callback. Reuse final demand when ratio/state are unchanged; recenter/reset and controller updates must invalidate reuse. A closed-form calculation needs reference tests at floating-point integer boundaries and after short reads, rather than a blind replacement.
5. **P3 — Unchanged route targets are reread each callback.** `StereoRouting.c:79–85`. Cache the last successfully applied publication version and skip target-copy work when unchanged; ramps still advance. Preserve coherent version validation and address theoretical version wrap.
6. **P3 — Repeated transport metric snapshots per lifecycle poll.** `AudioBridgeRealtime.c:534`, `AUHostContext.swift:104`, `AudioBridgeEngine.swift:325–328`. Use queue-only access where sufficient and one shared transport metrics snapshot per poll; retain safety/response cadence.

Further profiling candidates: cache-line separation of shared indices/telemetry, SIMD FIR accumulation preserving numerical quality, identical-pointer memmove skips, and small-block semaphore/stage-timing overhead. Do not weaken arm/recheck fences, bypass FIR at unity, remove autorelease pools or eliminate the persistent dry-path helper as an unmeasured shortcut.

## Protections that appear sound

- HAL callbacks use preallocated C storage, atomics and bounded routines, with no Swift UI, callback-side waits or AU render invocation.
- Stop disables delivery, detaches registrations and checks in-flight callbacks before free; uncertain detach deliberately retains context/mapping.
- Renderer exchange uses release/acquire handoff and main-thread ownership until acknowledgement; no premature retirement was demonstrated.
- Worker wait uses paired sequentially consistent arm/recheck fences and consumes a claimed signal before rearming; no lost wake was demonstrated.
- AppModel uses routing generations and command UUIDs to reject stale updates. Manual Stop persists stopped intent.
- Active latency refresh does not expose a demonstrated `latencySeconds` race: render does not read it in block processing, and adoption reads before acknowledgement while main skips pending replacement refresh.
- Meter/UI telemetry is already separated from configuration, normally publishes at 5 Hz and uses Core Animation. No evidence justified a broad SwiftUI rewrite.
- Hog-mode release is valid: installed `AudioHardware.h:938–944` documents ignored setter input and toggle ownership semantics.

## Remaining limits and priority

Driver calls themselves can hang on the lifecycle queue; the later callback-drain timeout does not bound `AudioDeviceStop` or `AudioDeviceDestroyIOProcID`. Plugin property/teardown calls can block the helper main thread while render heartbeat continues. Source review cannot prove third-party lock behavior or scheduling reliability.

Recommended next slice: editor-command completion, Stop transition guard/gate and remote generation/connection lifecycle, with parser and failure-path tests. Then narrow discovery and improve complete-cycle timing before performance comparisons. FIR/SIMD and sparse-route changes should follow targeted benchmarks. This report introduces no audio or UI behavior changes.
