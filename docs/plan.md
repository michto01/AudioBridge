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

User-authorized device-access follow-up: 0.5.0/build 22 adds an opt-in request for Core Audio hog mode on both selected endpoints. The C engine acquires before IOProc registration, rolls back partial ownership, confirms device ownership and releases after safe callback teardown. Unsupported or busy devices block Start with an actionable device-specific reason; shared access remains selectable. See [exclusive access results](exclusive-access-results.md). Build and bundle checks are recorded there; testing with competing apps and multiple device drivers remains pending.

User-authorized output-volume follow-up: 0.5.0/build 23 adds a distinct selected-device master-volume slider beside software output gain in the Bridge output card. It reads and writes the explicit output UID through the Core Audio volume scalar property on a utility queue, verifies readback and indicates absent/read-only controls. Device volume/physical output checks remain pending. See [device volume results](device-volume-results.md).

User-authorized UI/stability refinement: 0.5.1/build 24 keeps trim sliders in the main Bridge window only; drafts 64-frame interface buffers with explicit combined Apply; uses a separate 64-frame-minimum, twice-device-buffer FIFO default; moves permission controls to General; adds tab visibility and service-specific remote status/control; averages dynamic delay over five seconds; and distinguishes timestamp-measured clock difference from correction commands. Recent-delivery warning ignores queue recenter bookkeeping while preserving real underrun/overrun/format counts. See [UI/stability refinement results](ui-stability-refinement-results.md). Build, app packaging, ad-hoc signing and verification pass. Tests and visual, network, audio, clock and unattended acceptance remain unrun.

User-authorized usability follow-up: 0.5.2/build 25 replaces duplicated Remote enable/start/stop/apply actions with one independent switch per HTTP and OSC service, adds an explicit delivery-warning reason to Diagnostics, shortens warning recovery to five healthy seconds, and removes fixed empty space from the Bridge endpoint cards. Queue occupancy passing two buffer lengths is not used as proof of recovery; actual callback health and frame-loss counters remain the signals. See [remote/warning/card follow-up](remote-warning-ui-results.md). Automated tests and live network/audio/UI acceptance remain unrun.

User-authorized visual correction: 0.5.3/build 26 gives Bridge icons an explicit 42-point size, measures equal endpoint heights from the larger card, introduces bold group headings and per-group info popovers, and structures diagnostics and Copy Status into labeled sections. See [visual correction results](ui-visual-correction-results.md). This is an operator-interface follow-up; Phase 5 operational acceptance remains pending.

User-authorized CPU/card follow-up: 0.5.4/build 27 places channel/rate metadata beneath each device name, separates 20 Hz engine telemetry from configuration observation, and avoids no-op recovery publications. Read-only profiling of build 26 found high main-app CPU and substantial SwiftUI layout activity. An optimized release bundle is provided for comparison. See [CPU and device-card follow-up](cpu-device-card-results.md). CPU improvement and Phase 5 operational acceptance remain unverified.

User-authorized output-level simplification: 0.5.5/build 28 retains input trim, uses writable device volume as the primary output control, and holds digital output gain at unity in that mode. Devices without writable volume expose the saved digital gain as a fallback. See [output-level fallback results](output-level-fallback-results.md). Phase 5 operational acceptance remains pending.

User-authorized diagnostic follow-up: 0.5.6/build 29 adds Reset counters as a safe observation baseline, retains engine lifetime totals and health checks, and exposes AU block processing budget and aggregated lost-frame duration. Empty chains still use the helper; removing plugins narrows the failure to plugin render work or associated hosting/scheduling overhead. See [diagnostic reset and AU investigation](diagnostic-reset-au-results.md). Phase 5 operational acceptance remains pending.

User-authorized effect suspension: 0.5.7/build 30 adds a saved Enable effect processing switch. Off forwards dry stereo without invoking AU render calls; loaded units and settings remain available, while plugin meters/DSP state pause. Bypass remains a separate dry-output mode with plugin rendering. See [effect-processing switch results](effect-processing-switch-results.md). Worker scheduling refinement and Phase 5 operational acceptance remain pending.

User-authorized startup/rendering repair: 0.5.8/build 31 guards running-bundle replacement, identifies incompatible helper startup as action-required, exposes effect controls during recovery, supports direct routing when starting with effects off, and publishes UI telemetry at 5 Hz while retaining the 20 Hz watchdog. Meter animation draws inside fixed bounds. See [helper startup and UI load results](helper-startup-ui-load-results.md). Effect-mode route restarts respect manual Stop. Worker scheduling refinement and Phase 5 operational acceptance remain pending.

User-authorized real-time performance follow-up: 0.5.9/build 32 adds signaled
AU work readiness, a reported Mach real-time scheduling request, lock-free
block-boundary renderer adoption with main-thread retirement, batched source
reads and mirrored FIR history. Meter animation moves to native layers; FIFO
capacity/reserve and startup filling are explicit. See [real-time scheduling
results](realtime-scheduling-results.md). Audio workgroups, runtime scheduling,
CPU comparisons and Phase 5 operational acceptance remain pending.

## 0.6 — Audio reliability revision (current review gate)

Continuous DSP/startup follow-up: 0.6.2/build 35 keeps transport active for DSP switching, lazily prepares saved effects after a dry start, applies a 20 ms dry/wet fade, tries half-device AU blocks in Automatic, starts output before capture, uses monotonic callback supervision and reports actual recenter discards as recent loss. Czech buffer units now use vzorky. See [whole-pipeline audit and deferred acceptance](continuous-dsp-pipeline-results.md). Live switching, CPU and long-run acceptance remain pending.

Audio-first follow-up: 0.6.1/build 34 corrects the full-block-only AU input pull callback to support timestamp-addressed portions of a prepared block with bounded validation. See [source finding and deferred acceptance](au-input-pull-results.md). This is not a confirmed fix for the operator's periodic underruns; current runtime diagnostics and the 0.6 operational gate remain pending. The microphone-permission icon is deferred.

User authorized this slice on 2026-10-12. [ADR-003](decisions/ADR-003-reliability-and-operator-setup.md) records device-loss stop/re-arm semantics and operator setup. Version 0.6.0/build 33 implements lifetime/reporting repairs, asynchronous AU workgroup/context integration, notification-driven latency refresh, plugin/stall telemetry, explicit AU blocks, shared Simple configuration, retained Expert controls and English/Czech localization. See [implementation, commands and pending acceptance](release-0.6-results.md).

Gate: deterministic queue/wake/ownership checks, device drop/re-arm checks, plugin isolation comparisons at 128 input / 32 output / 128 reserve, physical loopback latency and a 12-hour run with bounded queues and no lost frames. All runtime/test gates remain pending. Build/signature checks do not complete the gate. Stop for review; no distribution or unattended readiness claim.

## Suggested release milestones

`v0.1` UI + device probe; `v0.2` stereo bridge; `v0.3` drift compensation and DSP; `v0.4` recovery/login; `v1.0` validated hardware build.

## Deliverables per phase

Source changes; passing test log; known limitations; one-paragraph risk assessment; updated docs; Git commit with scoped message. Hardware-dependent tests explicitly marked `not run` when hardware is absent.

## Codex starting task

Read README and all six docs and AGENTS.md. Implement **only Phase 0**. Do not begin HAL audio processing until the bundle and SwiftPM build pipeline are working. At the end report files changed, commands run, actual results, and decisions requiring hardware validation.
