# Product contract

Audio Bridge is a native macOS 14+ menu-bar utility for live-production audio routing in an active user session. Its aim is predictable, low-latency operation over long runs; unattended-readiness acceptance remains open.

## Invariants

| ID | Requirement |
|---|---|
| P-01 | Native SwiftUI MenuBarExtra and separate Settings; engine lifetime independent of UI |
| P-02 | Explicit input/output by Core Audio UID and physical-channel index |
| P-03 | Never substitute system defaults or alternate devices/channels |
| P-04 | Optional login launch and launch resume after explicit configuration; neither starts capture by default |
| P-05 | Manual Stop persists and overrides retries/resume |
| P-06 | Device loss/identity/topology/rate/buffer changes or confirmed callback stalls stop and require local re-arm; other recoverable failures retry with capped backoff |
| P-07 | N×2 input mix, stereo AU/drift path and L/R/explicit mono output fan-out on one output UID |
| P-08 | Smooth gain, measured stereo meters, clipping/loss diagnostics and explicit output-level control |
| P-09 | No silence notifications; clipping is a signal condition, not delivery failure |
| P-10 | Independent clocks require actual adaptive resampling; FIFO alone is insufficient |
| P-11 | Prefer 48 kHz, validate real device capabilities and apply hardware changes explicitly |
| P-12 | SwiftPM/Makefile builds and a real `.app`; no Xcode project |
| P-13 | English/Czech operator UI, with supplied device/plugin text retained |

## Scope and limits

Current IO requires distinct UIDs, matching current nominal/stream rates and validated native packed Float32 planar/interleaved stream layouts. Same-device duplex, arbitrary nominal-rate conversion and integer PCM remain future backend work. Operator-configured aggregates are best effort; no invisible aggregate is created. Device brand or transport is never a required dependency; TightAV/ATEM is only a hardware test example.

Installed stereo AU effects and optional HTTP/OSC status/control are accepted extensions. No built-in EQ/compressor, VST hosting, recording, network audio transport, cloud service, per-app system-audio capture, multichannel effect chain or independently opened multiple outputs is included.

## Operating constraints

- Running/green confirms local callback freshness and primed delivery, not upstream signal or downstream reception.
- Hardware/software faults, sleep, restart and power loss can interrupt audio. Driver and third-party plugin calls can block; no hard deadline guarantee is offered.
- External analog sensitivity and safe monitoring levels belong to the operator. Mixing/gain can clip; there is no hidden limiter or normalization.
- Ad-hoc development signing is not notarization or a stable Developer ID identity. Login registration needs a stable installation path.
- Compatibility, physical latency and reliability require tests on the stated devices/plugins. A short clean run is not a 12-hour acceptance result.

## Success criteria

Configure explicit devices and patches once; preserve them across relaunch; maintain bounded queues/drift/CPU/memory; report actionable faults; never route to an unintended output; meet the [hardware and soak gates](testing.md). Accepted choices and supersession are recorded in [ADRs](decisions/README.md).
