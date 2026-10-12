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

Implementation status: experimental manual HAL input/output path, C callback ownership, bounded stereo FIFO and Float32 layout normalization implemented. Compiled and packaged; new automated tests written but not run. Live audio checks deferred at user request. Integer PCM and same-device duplex routing remain prerequisites for broader compatibility. See [Phase 2 results](phase-2-results.md). Stop for review before Phase 3; the audio acceptance gate remains pending.

- Implement independent HAL capture/output, safe callback lifecycle and a preallocated FIFO.
- Support a verified internal PCM representation and explicitly convert device formats.
- Initially test stereo identity matrix and 0 dB gain; add deterministic signal tests.

**Gate:** known 1 kHz test signal on input channel 1 appears only on output L; channel 2 only on R; no undefined buffers or blocking in callbacks.

## Phase 3 — Drift, DSP and meters

Approved extension: [ADR-002](decisions/ADR-002-stereo-mix-and-fanout.md). N×2 physical input mixing before the stereo AU/drift path, output L/R fan-out within one output device, versioned migration and routing grids are implemented in 0.3.1/build 10, with menu-bar status colours, Copy status and compact UX. Implementation evidence is in [routing extension results](stereo-routing-results.md). Mono/stereo presets remain the default workflow. Stop for review before supervisor/login work; previous and new automated/hardware gates remain pending.

User-authorized preliminary slices: local signal meters, compact FIFO buffer settings, smooth digital input trim and output gain implemented to support manual Phase 2 routing checks. See [audio settings follow-up](audio-settings-results.md) and [buffer/gain follow-up](buffer-gain-results.md). The next authorized slice implements adaptive drift resampling and a persisted live matrix; see [Phase 3 results](phase-3-results.md). Builds and bundle checks pass; automated and hardware gates remain pending under the user instruction. Stop for review before Phase 4. User reported microphone routing working after refreshing permission, not a completed stereo signal or drift test.

- Add adaptive resampling and FIFO occupancy control, measured correction and under/overrun accounting.
- Add N×2 input matrix and stereo output fan-out, mono/stereo presets, smoothed gain, stereo mix/output peak meters and clipping indicators.
- Implement latency profiles as documented tuning parameters, not unverified absolute promises.

Playback/delay follow-up: 0.3.4/build 13 separates Playback, Audio, Routing and Effects controls. Reported device/stream/safety latency, sampled queues/in-flight occupancy, FIR lookahead and declared AU latency support an estimated accounting total. AU block last/mean/max wall time supports later CPU/deadline investigation, not physical transit measurement. Interface drafts preserve current driver values with 128-frame fallback only if unknown. See [results and deferred acceptance](playback-delay-results.md). Automated tests, actual delay, CPU and UI acceptance remain pending; this does not open Phase 4.

Buffer/drift repair: 0.3.6/build 15 fixes speculative end-of-callback source reads, retains FIR history through starvation, refills callback demand plus the configured reserve, holds PI integration during processed-queue pressure and aligns small AU blocks with device buffers. See [repair results](buffer-drift-repair-results.md). Hardware improvement and test execution remain pending.

**Gate:** drift simulations at positive/negative ppm, matrix unit tests, 1–2 hour preliminary hardware test with stable buffer occupancy.

Worker-delivery follow-up: 0.3.7/build 16 uses a dedicated AU rendering thread, bounded autorelease lifetimes, minimal callback queue snapshots and separates wall-time/wake-lateness evidence from commanded/applied drift telemetry. See [results and deferred checks](worker-delivery-results.md). Real-time scheduling, measured CPU/continuity improvement and Phase 3 acceptance remain pending.

Review repair: 0.3.8/build 17 brings Settings forward, keeps drift learning active for genuinely low total backlog, derives pending source occupancy from capture/consumption counters and refreshes running AU latency outside rendering. Playback accounting uses conserved pending frames. See [changes and deferred acceptance](review-fixes-results.md). Tests and live acceptance remain unrun; Phase 4 is still gated.

## Phase 4 — Supervision and UI

Current implementation: user authorized advancing on 2026-10-12 despite deferred earlier acceptance checks. Version 0.4.0/build 19 implements desired/observed separation, capped recovery, explicit launch resume, persisted Stop, recovery diagnostics and SMAppService login controls. See [Phase 4 results](phase-4-results.md). Compilation and bundle checks are recorded there; reconnect, login, race and hardware gates remain **not run**. Stop for review before Phase 5 hardening/distribution.

User-authorized AU extension: installed effect catalog, persisted ordered chain, separate editor/render helper, and trim controls above meters implemented. See [AU hosting results](au-hosting-results.md). This expands the original DSP scope but does not pass Phase 3–5 gates or establish unattended readiness.

Follow-up: live chain insertion/removal, same-instance parameter editing, automatic editor sizing and whole-chain bypass implemented; see [live AU results](live-au-results.md). Runtime acceptance, transition behavior and the reported allocation failure remain unverified.

Bypass now selects dry output while keeping effects editable and processing; editor indication added. The fixed 256-frame floor is removed in favor of device-constrained startup fill (minimum 16) and 16–256 AU blocks. See [bypass and small-buffer results](bypass-small-buffer-results.md); low-buffer hardware acceptance remains deferred.

Catalog discovery now has a persistent metadata cache, isolated first-run/manual background scans with progress, and common/custom buffer choices. Icon metadata is embedded and verified in the executable as well as the bundle. See [catalog/icon/buffer results](catalog-icon-buffer-results.md); visual microphone-list confirmation remains pending.

- Build supervisor state machine with desired-vs-observed state, bounded backoff and UID-driven reconnection.
- Implement menu-bar popover, settings window, diagnostics and configuration migration.
- Implement login item via `SMAppService` as appropriate for app packaging and installation method.

**Gate:** manual Stop persists; login resumes only when enabled; reconnect never substitutes another output; UI close does not stop engine.

## Phase 5 — Hardening and distribution

Current implementation: local Phase 5 tooling begins with macOS 14 CI (`make doctor/build/test`), tag-validated ZIP publishing and the existing signed ZIP/checksum release flow. See [Phase 5 implementation and pending acceptance](phase-5-results.md). CI and release workflows have been authored but not run remotely; tests and live audio remain deferred per user instruction. Do not mark the phase gate complete until hardware, lifecycle, clean-install and soak evidence is recorded.

- Test all device loss, sample rate, sleep/wake and permissions cases.
- Audit real-time callback allocations/locks, memory ownership, teardown races, thread sanitizer coverage where possible.
- Package ad-hoc signed ZIP, verify signature and clean-install behavior on a second Mac if available.
- Create GitHub Actions macOS CI for build/test and tagged ZIP releases (respect runner quotas).

**Gate:** 12-hour continuous run, no unhandled crashes, bounded buffer occupancy and documented recovery results. Note any remaining measurable dropouts or latency.

User-authorized operator-interface follow-up: 0.5.0/build 21 refreshes the Bridge dashboard, smooths visible meter motion, uses one two-state Start/Stop button, and adds opt-in OSC/HTTP status and control for Bitfocus Companion. See [UI/remote control results](ui-remote-control-results.md) and [protocol contract](remote-control.md). Build and signed bundle checks pass; network/Companion/UI visual acceptance and Phase 5 operational gates remain pending.

## Suggested release milestones

`v0.1` UI + device probe; `v0.2` stereo bridge; `v0.3` drift compensation and DSP; `v0.4` recovery/login; `v1.0` validated hardware build.

## Deliverables per phase

Source changes; passing test log; known limitations; one-paragraph risk assessment; updated docs; Git commit with scoped message. Hardware-dependent tests explicitly marked `not run` when hardware is absent.

## Codex starting task

Read README and all six docs and AGENTS.md. Implement **only Phase 0**. Do not begin HAL audio processing until the bundle and SwiftPM build pipeline are working. At the end report files changed, commands run, actual results, and decisions requiring hardware validation.
