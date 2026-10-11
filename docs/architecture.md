# Architecture

## User-authorized Audio Unit extension

Installed AU effects are hosted by a separate SwiftPM helper, connected to HAL capture/output through preallocated shared-memory queues. Input trim precedes the chain; output gain follows it. The UI persists exact AU component identities and state, with explicit bypass only. Plugin setup/editing stays outside HAL callbacks. Failed or stalled helpers stop routing; automatic recovery and drift compensation are still pending. See [implementation evidence and limits](au-hosting-results.md).

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
  Input HAL callback → PCM normalization → bounded SPSC FIFO
                                      ↓
                  adaptive resampler / drift control
                                      ↓
                 2×2 matrix → smoothed gain → output HAL callback
                │
                ▼
        independently selected output device
```

The diagram is conceptual: precise order of format conversion, resampling and matrix depends on supported stream formats. Do not copy/allocate/lock in real-time callbacks; preallocate conversion buffers and initialize converters outside the callback.

## Interfaces and responsibilities

- `AudioDeviceCatalog`: enumerate input/output devices, UIDs, names, channel capabilities, sample rates, buffer ranges, liveness, and property changes. Treat runtime `AudioDeviceID` as ephemeral.
- `BridgeConfiguration`: versioned, codable settings: selected UIDs, 2×2 matrix, gain, latency profile, desired routing, login option and diagnostics options. Validate before committing.
- `BridgeSupervisor`: serialized commands `start`, `stop`, `reconfigure`, `deviceChanged`, `engineFault`, `retry`; publishes immutable `BridgeSnapshot` for UI.
- `AudioBridgeEngine`: `prepare(config, devices)`, `start`, `stop`, `teardown`, diagnostics snapshots. No SwiftUI references.
- `AudioProcessor`: pure testable matrix/gain DSP, resampler and ring-buffer primitives.
- `DiagnosticsService`: structured events, rate-limited error reporting, cumulative glitch counters, optional diagnostic export.

## State machine

`stopped` (manual), `waitingForInput`, `waitingForOutput`, `preparing`, `running`, `degraded`, `recovering`, `faulted` (unrecoverable configuration or permission). Model desired state separately from observed state. Both devices absent must be represented unambiguously in a diagnostic reason.

- Start requested: resolve both UIDs; missing device → wait; permission denied → actionable fault; devices present → prepare/start.
- Device disappears or invalidates stream: detach safely; silence output if possible; transition to recovery; re-resolve by UID.
- Reappearance: re-query capabilities and rebuild from scratch if necessary.
- Recoverable error: retry 1, 2, 4, 8, 16, 30, 30… seconds (with notification-driven immediate recheck); never busy-loop.
- Manual Stop: clear desired routing, cancel scheduled retries and prevent reconnection-triggered restart. Persist preference before acknowledging Stop.
- Reconfiguration: serialize transitions; avoid competing device callbacks and configuration changes; validate and apply atomically or restore last valid settings.
- Distinguish fatal configuration/permission errors (require operator action) from recoverable hardware failures (retry indefinitely). Do not endlessly retry permission prompts.

## Real-time design

Two independent clock domains require an elastic buffer and resampling or equivalent drift correction. A simple FIFO alone is insufficient for indefinite operation. Use preallocated single-producer/single-consumer ring storage, clear memory ordering, explicit underrun/overrun behavior and no hidden allocations in callbacks. Prefer C/C++ or carefully audited Swift for callback-critical structures if ARC/Swift exclusivity/runtime behavior complicates hard real-time guarantees; keep app orchestration in Swift.

- Input callback: copy/convert frames into FIFO; update lock-free counters; never block on output.
- Output callback: consume/resample to requested output frame count; process matrix/gain; output silence on starvation; no UI calls.
- Drift controller: track smoothed FIFO occupancy vs target, bound resampling correction (ppm limit to be tuned), detect outliers and perform controlled re-centering when necessary.
- Channel layout: explicit 2-channel input and output contract. Handle other device channel counts only through validated selection/mapping or reject clearly.
- Formats: support common Core Audio float/int PCM and planar/interleaved layouts through a tested conversion layer; do not assume `Float32` non-interleaved on every device.
- Metering: peak or peak+RMS accumulated in callback-safe structures, polled by UI at a modest rate (e.g. 10–20 Hz); report dBFS and clipping counts. Meters reflect local samples, not reception at downstream hardware.
- Gain/matrix updates: smooth ramps at audio rate to avoid clicks; define coefficient range and clipping policy.
- Avoid creating an aggregate device as an invisible dependency; if an aggregate-device approach is considered, benchmark it and document persistence and drift-compensation implications.

## Latency

Report measured or estimated components separately: input device, input buffer, FIFO target, resampler, output buffer and output device. Profiles adjust safety margin rather than promising fixed end-to-end milliseconds. Default Balanced; measured round-trip/one-way signal latency requires physical loopback measurement.

## Concurrency

Supervisor and configuration changes execute on a single serialized actor/queue; Core Audio property listeners enqueue events only. Audio callbacks never await actors, acquire locks, access settings storage, log synchronously, allocate or trigger SwiftUI updates. Teardown must guarantee callback lifetime safety before freeing buffers; test stop/restart races under sanitizers where feasible.

## Device permissions and app lifecycle

Include `NSMicrophoneUsageDescription` for capture, test TCC authorization with the packaged bundle, and ensure `LSUIElement`/menu-bar behavior is correct. `SMAppService` login-item registration must be verified from a real signed app at a stable installation path. Do not assume direct `swift run` reproduces app-bundle behavior.

## Hardware probe before implementation lock

Create a small CLI tool or diagnostics screen that lists UIDs, transport types, stream/channel formats, nominal rates, supported buffers and permission status for all eligible Core Audio devices. Validate using at least built-in and independent external or virtual endpoints. Use findings to select exact HAL API surface. Do not claim a specific callback or AudioConverter configuration is supported without validating against the macOS SDK and hardware.

## Universal device contract (normative)

- The product is a **Core Audio PCM device bridge**, not a Dante or USB adapter utility. No device brand, model, transport, or downstream mixer is a required dependency.
- Enumerate all available input-capable and output-capable Core Audio endpoints. Persist each selected endpoint by stable device UID; never bind to transient `AudioDeviceID` or display name.
- At runtime probe stream availability, channel count, channel layout, sample rate, sample representation, buffer size and liveness. Reject unsupported or non-PCM formats with an actionable reason; never silently choose a different endpoint.
- V1 has **two logical input lanes and two logical output lanes**, each mapped to a user-selected physical channel index of its respective device. A device may expose more than two physical channels. If fewer than two channels are exposed, allow explicitly configured duplication/mono routing where technically valid; do not fabricate channels implicitly.
- Keep physical channel selection distinct from the logical 2×2 mixing matrix. The DSP and configuration schema should admit future N×M generalization without promising it in V1.
- Input and output may be independently clocked, even at the same nominal sample rate. Use bounded buffering and adaptive conversion; do not assume a shared USB clock.
- Built-in, USB, Thunderbolt and virtual devices are first-class discovery targets. Bluetooth, AirPlay, aggregate and unusual virtual devices are best-effort until validated for latency, liveness and format behavior.
- The initial hardware validation example is a class-compliant TightAV Dante USB 2×2 feeding a Mac 3.5 mm output and ATEM Mini. This is **non-normative**; no vendor-specific branches are permitted for that example.

See `device-compatibility.md` and `decisions/ADR-001-universal-core-audio.md`.
