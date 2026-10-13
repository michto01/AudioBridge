# Architecture

## Processing path

```text
Selected input UID / physical channels
  → HAL capture → N×2 mix → input trim
  → bounded stereo capture queue
  → dedicated AU helper (effects or dry forwarding)
  → bounded stereo ready queue
  → adaptive drift FIR → output gain
  → physical L/R/explicit L+R fan-out → HAL output
Selected output UID
```

One selected device per direction, one stereo effects/drift path. Current formats/rates and stream/buffer topology are validated before registration. Unsupported or ambiguous layouts fail explicitly. See [endpoint contract](device-compatibility.md) and [ADR-002](decisions/ADR-002-stereo-mix-and-fanout.md).

## Modules

| Target | Responsibility |
|---|---|
| AudioBridge | SwiftUI, AppModel orchestration, settings/login/permissions and remote listeners |
| AudioBridgeCore | Device/route models, persistence/migration, readiness/recovery policy, diagnostics and remote parsing |
| AudioBridgeDiscovery | Core Audio catalogs, UID resolution and property operations |
| AudioBridgeRealtime | Preallocated C callbacks, routing/gain/FIR/drift, queues, cancellation gates and AU transport |
| AudioBridgeEngine | Serial lifecycle, supervision, helper hosting and immutable telemetry |
| AudioBridgeAU | AU identities, chains, state serialization and helper protocol models |
| AudioBridgeAUWorker / AUViews | Plugin preparation, rendering, editor UI and legacy Cocoa integration in the helper |
| AudioBridgeStrings | English/Czech resources |
| AudioBridgeProbe | Read-only device/permission-context CLI |

No external Swift package dependency. SwiftPM is canonical; host/helper executables and resources ship together.

## Ownership and lifecycle

AppModel orchestrates on MainActor with generations rejecting stale route updates. RecoveryPolicy separates desired routing from observed delivery and uses monotonic retry deadlines. AudioBridgeEngine owns a serial lifecycle queue independent of UI windows. Property listeners enqueue events; they never rebuild resources inside HAL callbacks.

Each start publishes an irreversible atomic C cancellation gate before preparation. Stop cancels published attempts synchronously without holding a Swift lock across HAL calls. Preparation and HAL start check the gate; callbacks check it before processing. An already executing callback can finish. The C engine retains the gate until confirmed destroy, including retained memory after uncertain detach. Lifecycle teardown retires Swift attempts, preventing retry-history accumulation.

Stop disables delivery, stops/detaches IOProcs and checks in-flight quiescence before freeing buffers. Unsafe detach retains context/mapping and requires process restart. A driver Stop error after confirmed detach is reported separately. Driver Stop/destroy calls themselves can block; a callback drain timeout does not bound them. Device loss/change/stall persists the local re-arm latch ([ADR-003](decisions/ADR-003-reliability-and-operator-setup.md)).

## Callback invariants

- C callbacks use preallocated storage, lock-free atomics and bounded processing. No ARC/SwiftUI, allocation, logging, actor waits, property queries, plugin calls or blocking waits.
- Input addresses validated physical streams, sums the stereo mix, applies smooth trim, publishes samples then queue indices and updates counters.
- Output consumes/resamples exact source demand, applies output gain/fan-out and clears unpatched output buffers. Starvation produces counted zero-fill, never fabricated audio.
- Sparse routes retain active/ramping channel indices through fade-out. Coherent 64-bit publication versions skip unchanged targets; exhaustion is rejected before publication. Control updates have one writer.
- FIR plans reuse original demand arithmetic, validated by owner/state generation; reset/process invalidates plans and ratio/recenter changes rebuild them. History survives short reads; filtering remains active at unity.

## Queues, clocks and rendering

Each shared queue has one producer/consumer. Release/acquire index publication follows sample writes; paired sequentially consistent arm/recheck fences prevent missed worker wakes. A precreated named semaphore coalesces readiness signals. HAL callbacks only signal an armed worker when it can proceed; waiting/resource creation happen outside callbacks. Shutdown wakes an armed worker.

The helper render thread requests Mach time-constraint scheduling and owns an asynchronous AudioWorkInterval workgroup; it does not join either independently clocked device's parallel workgroup. Setup/interval errors are reported with fallback. Accepted setup is not a sustained scheduling or deadline guarantee. Cached render-context observers receive the helper context on the render thread.

AU render/pull blocks are cached after resource allocation. A borrowed-pointer mailbox adopts prepared replacements between blocks. Helper main retains old/new owners until acknowledgment, then retires the old chain off the render thread. Per-block autorelease pools bound temporary legacy-plugin objects. Plugin properties/setup/editor work stay off HAL; third-party locks/auxiliary threads remain outside host control. See [ADR-004](decisions/ADR-004-audio-unit-hosting.md).

All app routes retain the helper transport, including DSP off. A dry start loads no saved effects; enabling prepares/adopts them while forwarding dry audio. Dry/wet changes use a 20 ms ramp. DSP off suspends render calls after fade-out; bypass keeps rendering. No queue flush or HAL restart is used for the switch. Dry/wet latency is not aligned and transitions are not guaranteed inaudible.

Equal nominal rates can still have clock skew. Bounded adaptive FIR consumption follows filtered occupancy with anti-windup/refill handling; measured timestamp clock difference, commanded correction and applied correction are distinct. Pending source uses accepted capture minus consumed/discarded frames, avoiding in-flight double counting. Reserve is occupied-audio target; allocated capacity is headroom, not extra delay. See [ADR-005](decisions/ADR-005-realtime-health-and-observability.md).

## Discovery and telemetry

Full catalogs serve setup. The 0.5-second watchdog checks selected UID uniqueness/liveness, runtime identity, current rate/buffer, stream order/layout/current formats and latency without static capability lists, names or icons. Volume operations resolve the selected UID afresh and query necessary properties only.

Health/command supervision runs at 20 Hz; normal informational snapshots publish at 5 Hz, with fault/state/command transitions immediate. Native Core Animation meters quantize targets to whole dB without SwiftUI redraws at display refresh rate. Dynamic delay is averaged over five seconds; detailed snapshots remain available.

Protocol **8** validates app/helper shared-memory compatibility. DSP block timing, wake delay, per-plugin timing and complete worker-cycle/adoption timing are separate. Complete cycles include adoption/context hooks and pool drain, exclude idle waiting, and are run totals unaffected by Reset counters. None is added as signal latency. Per-plugin totals reset with slot-instance adoption; their means cannot simply be summed across differing windows.

## Remote and permissions

Independent HTTP/OSC generations invalidate before listener/accepted-connection cancellation. Acceptance, dispatch, status and feedback ticks reject stale generations; dispatch is serialized on MainActor. Shared parsers enforce bounded HTTP frames and exact OSC tags/count/length with distinct Int32/Float decoding. [ADR-006](decisions/ADR-006-remote-control.md) and the [wire reference](remote-control.md) define access limits.

Microphone capture uses packaged-app TCC identity; CLI authorization is not app authorization. Notifications and Local Network access are separate. SMAppService login registration is opt-in at a stable app path. UI closure does not own or stop the engine. [ADR-007](decisions/ADR-007-build-and-distribution.md) records packaging/identity choices.
