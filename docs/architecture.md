# Architecture

Current continuous-switch amendment: app routes retain the AU helper transport with DSP off, but a dry start loads no plugins. First enable prepares/adopts the saved chain while dry blocks continue. A 20 ms dry/wet ramp precedes DSP suspension. Output starts before capture; callback supervision uses monotonic time. See [ADR-003](decisions/ADR-003-reliability-and-operator-setup.md) and [pipeline audit](continuous-dsp-pipeline-results.md).

Current 0.6 amendment: [ADR-003](decisions/ADR-003-reliability-and-operator-setup.md) supersedes automatic re-arming after device loss/identity/format/buffer changes or confirmed callback stalls. Simple/Expert setup and English/Czech UI are described there. Operational acceptance remains pending.


## User-authorized Audio Unit extension

Installed AU effects are hosted by a separate SwiftPM helper, connected to HAL capture/output through preallocated shared-memory queues. N×2 physical input mixing and input trim precede the chain; stereo adaptive drift processing and output gain follow it, then physical output fan-out (ADR-002). The UI persists exact AU component identities and state, with explicit bypass only. Plugin setup/editing stays outside HAL callbacks. Failed/stalled helpers detach the engine; typed recoverable failures retry with bounded backoff while explicit render/configuration failures require action. Hardware acceptance remains pending. See [Phase 4 evidence](phase-4-results.md).

## Logical components

```
SwiftUI MenuBarExtra / Settings Window
                │ snapshots + commands (main actor)
                ▼
AppCoordinator ─ SettingsStore ─ LoginItemManager
                │
                ▼
BridgeSupervisor (serialized state machine)
                │                 └─ DiagnosticsService / OSLog
                ▼
CoreAudioDeviceManager (UID discovery, property listeners, format probe)
                │
                ▼
AudioBridgeEngine
  Input HAL → Float32 addressing → N×2 input mix → input trim
                                                   ↓
                              bounded stereo capture queue → stereo AU helper
                                                   ↓
                              bounded stereo output queue → adaptive drift FIR
                                                   ↓
                              output gain → physical L/R fan-out → Output HAL
                                                   ↓
                              one explicitly selected output UID
```

The diagram is conceptual: precise order of format conversion, resampling and matrix depends on supported stream formats. Do not copy/allocate/lock in real-time callbacks; preallocate conversion buffers and initialize converters outside the callback.

## Interfaces and responsibilities

- `AudioDeviceCatalog`: enumerate input/output devices, UIDs, names, channel capabilities, sample rates, buffer ranges, liveness, and property changes. Treat runtime `AudioDeviceID` as ephemeral.
- `BridgeConfiguration`: versioned, codable settings: selected UIDs, versioned physical input/output patches, gain, latency profile, desired routing, login option and diagnostics options. Validate before committing.
- `BridgeSupervisor`: serialized commands `start`, `stop`, `reconfigure`, `deviceChanged`, `engineFault`, `retry`; publishes immutable `BridgeSnapshot` for UI.
- `AudioBridgeEngine`: `prepare(config, devices)`, `start`, `stop`, `teardown`, diagnostics snapshots. No SwiftUI references.
- `AudioProcessor`: pure testable matrix/gain DSP, resampler and ring-buffer primitives.
- `DiagnosticsService`: structured events, rate-limited error reporting, cumulative glitch counters, optional diagnostic export.

## State machine

Current implementation uses pure `RecoveryPolicy` for desired state, blocked state and monotonic retry deadlines. AppModel serializes orchestration on the main actor, with attempt generations rejecting late completion/snapshot work. AudioBridgeEngine retains its independent serial lifecycle queue. Main-actor retry tasks never enter HAL callbacks. ServiceManagement registration happens only after explicit interaction with General's login toggle.

`stopped` (manual), `waitingForInput`, `waitingForOutput`, `preparing`, `running`, `degraded`, `recovering`, `faulted` (unrecoverable configuration or permission). Model desired state separately from observed state. Both devices absent must be represented unambiguously in a diagnostic reason.

- Start requested: resolve both UIDs; missing device → wait; permission denied → actionable fault; devices present → prepare/start.
- Device disappears, changes identity/format/buffer or stops callbacks: detach safely, latch stopped intent and require explicit local re-arming (ADR-003); never substitute another UID.
- Reappearance: re-query capabilities and rebuild from scratch if necessary.
- Recoverable error: retry 1, 2, 4, 8, 16, 30, 30… seconds (with notification-driven immediate recheck); never busy-loop.
- Manual Stop: clear desired routing, cancel scheduled retries and prevent reconnection-triggered restart. Persist preference before acknowledging Stop.
- Reconfiguration: serialize transitions; avoid competing device callbacks and configuration changes; validate and apply atomically or restore last valid settings.
- Distinguish fatal configuration/permission errors (require operator action) from recoverable hardware failures (retry indefinitely). Do not endlessly retry permission prompts.

## Real-time design

Two independent clock domains require an elastic buffer and resampling or equivalent drift correction. A simple FIFO alone is insufficient for indefinite operation. Use preallocated single-producer/single-consumer ring storage, clear memory ordering, explicit underrun/overrun behavior and no hidden allocations in callbacks. Prefer C/C++ or carefully audited Swift for callback-critical structures if ARC/Swift exclusivity/runtime behavior complicates hard real-time guarantees; keep app orchestration in Swift.

- Input callback: address validated physical streams, mix N inputs into stereo and apply trim before FIFO; update lock-free counters; never block on output.
- Output callback: consume/resample to requested output frame count; apply output gain and physical stereo fan-out; output silence on starvation; no UI calls.
- Drift controller: track smoothed FIFO occupancy vs target, bound resampling correction (ppm limit to be tuned), detect outliers and perform controlled re-centering when necessary.
- Channel layout: N×2 input mix, stereo processing and output fan-out per ADR-002; validate actual stream order/buffers and preserve physical indices. Integer PCM and same-device duplex remain pending.
- Formats: support common Core Audio float/int PCM and planar/interleaved layouts through a tested conversion layer; do not assume `Float32` non-interleaved on every device.
- Metering: peak or peak+RMS accumulated in callback-safe structures, polled by UI at a modest rate (e.g. 10–20 Hz); report dBFS and clipping counts. Meters reflect local samples, not reception at downstream hardware.
- Gain/matrix updates: smooth ramps at audio rate to avoid clicks; define coefficient range and clipping policy.
- Avoid creating an aggregate device as an invisible dependency; if an aggregate-device approach is considered, benchmark it and document persistence and drift-compensation implications.

## Latency

Build 32's helper sleeps on a precreated named semaphore until a full capture
block and output space are available, with arm/recheck fences and a coalesced
publication signal. Capture/output callbacks only issue a non-waiting `sem_post`
when an armed worker can proceed; semaphore creation, waiting and destruction
are outside callbacks. A kernel notification has overhead; this is not a claim
that arbitrary system calls are cost-free or bounded by an audio deadline.
Shutdown wakes an armed helper. Wake telemetry measures signal-to-resume delay,
excluding normal time waiting for capture/space. The shared protocol is version
6; app and helper must come from the same bundle.

The dedicated helper render thread requests `THREAD_TIME_CONSTRAINT_POLICY`
using its block duration as period/constraint and half that duration as nominal
computation. Diagnostics reports the setup Mach result; failed requests retain
QoS scheduling. This is a soft scheduling request, not continuous policy
verification, audio workgroup membership or a deadline guarantee. Readiness is
published by the render thread after policy setup, before parent HAL startup.

Renderer swaps use a lock-free borrowed-pointer mailbox. The helper main thread
retains both old and prepared replacement owners until adoption is acknowledged
between completed render blocks. It then releases the retired chain on the main
thread, keeping AU render-resource teardown off the render thread. One live
command remains outstanding until adoption; no unbounded retired-chain list.

The resampler fetches its exact callback demand into preallocated scratch once,
instead of reading/publishing the source queue for each sample. Mirrored FIR
history removes circular indexing from the inner convolution loop. Filter,
phase/demand calculation, short-read history and drift tuning are preserved;
numerical, wrap, starvation and lifecycle acceptance remain pending.

Report measured or estimated components separately: input device, input buffer, FIFO target, resampler, output buffer and output device. Profiles adjust safety margin rather than promising fixed end-to-end milliseconds. Default Balanced; measured round-trip/one-way signal latency requires physical loopback measurement.

## Concurrency

Supervisor and configuration changes execute on a single serialized actor/queue; Core Audio property listeners enqueue events only. Audio callbacks never await actors, acquire locks, access settings storage, log synchronously, allocate or trigger SwiftUI updates. Teardown must guarantee callback lifetime safety before freeing buffers; test stop/restart races under sanitizers where feasible.

## Device permissions and app lifecycle

Include `NSMicrophoneUsageDescription` for capture, test TCC authorization with the packaged bundle, and ensure `LSUIElement`/menu-bar behavior is correct. `SMAppService` login-item registration must be verified from a real signed app at a stable installation path. Do not assume direct `swift run` reproduces app-bundle behavior.

## Remote control and reporting

Opt-in HTTP/OSC listeners use Apple's Network framework; no third-party package is needed. HTTP exposes a JSON status snapshot and a small command set (Start, Stop, input/output gain, chain bypass) behind a random Keychain bearer token. OSC uses standard UDP messages, accepts commands only from explicitly allowlisted source IPs, and reports status/meters to a configured Companion host/port once per second. Listeners default off. HTTP is plain-text and intended only for a trusted local production network; bearer tokens are not protected from network sniffing. UDP OSC has no protocol authentication. No audio samples or plugin state are sent. See `docs/remote-control.md`.

## Hardware probe before implementation lock

Create a small CLI tool or diagnostics screen that lists UIDs, transport types, stream/channel formats, nominal rates, supported buffers and permission status for all eligible Core Audio devices. Validate using at least built-in and independent external or virtual endpoints. Use findings to select exact HAL API surface. Do not claim a specific callback or AudioConverter configuration is supported without validating against the macOS SDK and hardware.

## Universal device contract (normative)

- The product is a **Core Audio PCM device bridge**, not a Dante or USB adapter utility. No device brand, model, transport, or downstream mixer is a required dependency.
- Enumerate all available input-capable and output-capable Core Audio endpoints. Persist each selected endpoint by stable device UID; never bind to transient `AudioDeviceID` or display name.
- At runtime probe stream availability, channel count, channel layout, sample rate, sample representation, buffer size and liveness. Reject unsupported or non-PCM formats with an actionable reason; never silently choose a different endpoint.
- V1 uses N×2 physical input mixing, stereo AU/drift processing and L/R fan-out within one selected output device. ADR-002 supersedes the old 2×2 lane restriction. Explicit patches and actual stream/buffer topology are validated; unsupported layouts are rejected without defaults.
- Input and output may be independently clocked, even at the same nominal sample rate. Use bounded buffering and adaptive conversion; do not assume a shared USB clock.
- Built-in, USB, Thunderbolt and virtual devices are first-class discovery targets. Bluetooth, AirPlay, aggregate and unusual virtual devices are best-effort until validated for latency, liveness and format behavior.
- The initial hardware validation example is a class-compliant TightAV Dante USB 2×2 feeding a Mac 3.5 mm output and ATEM Mini. This is **non-normative**; no vendor-specific branches are permitted for that example.

See `device-compatibility.md` and `decisions/ADR-001-universal-core-audio.md`.
