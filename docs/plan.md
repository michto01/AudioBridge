# Implementation plan and delivery gates

## Working method

Implement in small, reviewable vertical slices. Codex must compile and run relevant tests after each slice, record commands/results, and stop to report blockers rather than papering over missing SDK or hardware. Do not generate a large untested application in one pass. Current user instruction defers automated test execution and live audio checks: tests may be written and documented, but unrun gates remain pending.

## Phase 0 — Repository and environment

Implementation status: shell and build workflow implemented; see [actual Phase 0 results](phase-0-results.md). User confirmed successful testing on 2026-10-11 and authorized Phase 1.

- Initialize Git repository, SwiftPM executable/library targets and XCTest/Swift Testing target as appropriate.
- Check `xcode-select -p`, `xcrun --find swift`, `swift --version`, `xcrun --sdk macosx --show-sdk-path`.
- Implement Makefile targets `doctor`, `build`, `test`, `app`, `run`, `sign`, `verify`, `release`, `clean`.
- Assemble valid `.app` with `Info.plist`, bundle identifier, minimum OS, microphone usage description, correct resources and optional entitlements.
- Confirm the packaged app launches with a visible menu-bar item.

**Gate:** clean `make build`, `make test`, `make app`, `make run`; inspect bundle metadata and code signature.

## Phase 1 — Device discovery and permission probe

Implementation status: device catalog, listeners, UID/channel persistence, permission UI and diagnostics export implemented. Built-in and virtual endpoints probed. See [actual Phase 1 results](phase-1-results.md). User confirmed settings persistence and granted permission, and authorized continuing. Physical reconnect and external USB validation remain deferred, not passed.

- Enumerate input/output devices with names, stable UIDs, channel counts, nominal sample rates and supported buffer sizes.
- Observe device arrival/removal; show missing device status; persist selection by UID.
- Request/check microphone permission in packaged app.
- Capture and document Core Audio characteristics across built-in, external USB, and virtual devices where available; test UID stability and unplug/replug behavior.

**Gate:** correct discovery and permission UX on the user's Mac; no silent fallback.

## Phase 2 — Minimal audio path

Implementation status: experimental manual HAL input/output path, C callback ownership, bounded stereo FIFO and Float32 layout normalization implemented. Compiled and packaged; new automated tests written but not run. Live audio checks deferred at user request. Integer PCM, multiple streams and same-device duplex routing remain prerequisites for broader compatibility. See [Phase 2 results](phase-2-results.md). Stop for review before Phase 3; the audio acceptance gate remains pending.

- Implement independent HAL capture/output, safe callback lifecycle and a preallocated FIFO.
- Support a verified internal PCM representation and explicitly convert device formats.
- Initially test stereo identity matrix and 0 dB gain; add deterministic signal tests.

**Gate:** known 1 kHz test signal on input channel 1 appears only on output L; channel 2 only on R; no undefined buffers or blocking in callbacks.

## Phase 3 — Drift, DSP and meters

User-authorized preliminary slices: local signal meters, compact FIFO buffer settings, smooth digital input trim and output gain implemented to support manual Phase 2 routing checks. See [audio settings follow-up](audio-settings-results.md) and [buffer/gain follow-up](buffer-gain-results.md). This does not complete Phase 3 or pass its audio gate; adaptive drift compensation and configurable matrix remain pending. User reported microphone routing working after refreshing permission, not a completed stereo signal or drift test.

- Add adaptive resampling and FIFO occupancy control, measured correction and under/overrun accounting.
- Add 2×2 matrix, presets, smoothed output gain, input/output peak meters and clipping indicators.
- Implement latency profiles as documented tuning parameters, not unverified absolute promises.

**Gate:** drift simulations at positive/negative ppm, matrix unit tests, 1–2 hour preliminary hardware test with stable buffer occupancy.

## Phase 4 — Supervision and UI

User-authorized AU extension: installed effect catalog, persisted ordered chain, separate editor/render helper, and trim controls above meters implemented. See [AU hosting results](au-hosting-results.md). This expands the original DSP scope but does not pass Phase 3–5 gates or establish unattended readiness.

- Build supervisor state machine with desired-vs-observed state, bounded backoff and UID-driven reconnection.
- Implement menu-bar popover, settings window, diagnostics and configuration migration.
- Implement login item via `SMAppService` as appropriate for app packaging and installation method.

**Gate:** manual Stop persists; login resumes only when enabled; reconnect never substitutes another output; UI close does not stop engine.

## Phase 5 — Hardening and distribution

- Test all device loss, sample rate, sleep/wake and permissions cases.
- Audit real-time callback allocations/locks, memory ownership, teardown races, thread sanitizer coverage where possible.
- Package ad-hoc signed ZIP, verify signature and clean-install behavior on a second Mac if available.
- Create GitHub Actions macOS CI for build/test and tagged ZIP releases (respect runner quotas).

**Gate:** 12-hour continuous run, no unhandled crashes, bounded buffer occupancy and documented recovery results. Note any remaining measurable dropouts or latency.

## Suggested release milestones

`v0.1` UI + device probe; `v0.2` stereo bridge; `v0.3` drift compensation and DSP; `v0.4` recovery/login; `v1.0` validated hardware build.

## Deliverables per phase

Source changes; passing test log; known limitations; one-paragraph risk assessment; updated docs; Git commit with scoped message. Hardware-dependent tests explicitly marked `not run` when hardware is absent.

## Codex starting task

Read README and all six docs and AGENTS.md. Implement **only Phase 0**. Do not begin HAL audio processing until the bundle and SwiftPM build pipeline are working. At the end report files changed, commands run, actual results, and decisions requiring hardware validation.
