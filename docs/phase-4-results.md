# Phase 4 — supervision and launch controls

User authorized advancing on 2026-10-12. Version 0.4.0/build 19 implements this phase's recovery/login slice; earlier audio gates and new runtime gates remain unrun. Stop for review before Phase 5.

## Implementation

- Pure RecoveryPolicy separates desired routing from observed engine state. Main-actor AppModel owns commands, monotonic retry deadlines and attempt generations; the engine retains its serial lifecycle queue. Late snapshots/completions cannot override a newer Start/Stop. Callback code has no supervisor/UI calls.
- Recoverable failures use 1, 2, 4, 8, 16, 30, 30… second backoff, reset only after 20 continuously healthy seconds. Missing endpoints wait indefinitely by selected UID, reporting both absent directions. Selected runtime ID/liveness/topology/rate/buffer changes can accelerate a pending attempt with a one-second floor. Routine unchanged catalog refreshes do not shorten backoff.
- Each attempt rebuilds through the existing fresh UID catalog and capability validation. Physical patches remain retained; no defaults or hardware rate/buffer changes. Unsupported formats/channels become action-required, not silent remapping. Routing/layout changes can recover after re-probing; invalid/nonfinite signal faults require action.
- Typed BridgeFailureKind covers recoverable, actionRequired and unsafeTeardown. Device/callback faults and helper exit/heartbeat/preparation timeout can retry. Explicit AU render/preparation errors, denied permission and configuration faults block retries. Failed callback detach retains resources and blocks all further starts until app restart.
- Manual Stop persists desiredRouting=false synchronously, cancels retries and invalidates old attempt work before completion. Stop during preparation uses the existing engine cancellation and serialized detach. Transition remains visible until stop completion. Deliberate Stop survives relaunch and overrides resume. Window closing does not stop the app-owned engine. Quit suppresses retry work and preserves saved routing intent.
- Resume at launch is a new default-off preference; both explicit opt-in and saved desired routing are required. Historical desired=true alone does not cause upgraded builds to capture automatically. Permission is checked without requesting it; first setup remains explicit. Enabling resume does not clear a manual Stop or immediately start a stopped route.
- General's login toggle uses SMAppService.mainApp. It reads actual service status, exposes approval/error states, and unregisters asynchronously when explicitly disabled. Enable requires the bundle under system/user Applications; no install or registration was performed by this implementation session. ServiceManagement is an Apple framework dependency, not a third-party package.
- Recovery/waiting uses amber menu status, action-required faults red; green still requires actual fresh callbacks/primed buffers. Diagnostics retains the last fault, bounded 50-event session history, intent/backoff/block/restart state; Copy status includes the last ten events. Full technical information remains available with the default-off debug display preference. No silence alerts or notification service added.

## Written tests — not compiled or run

RecoveryPolicyTests covers default stopped intent; launch preference/Stop precedence; indefinite capped backoff; due-time boundaries; manual Stop blocking future faults/device events; configuration/permission/unsafe blocks; explicit Start unblocking; reconnect acceleration floor; and delayed healthy reset. Existing DSP, callback and transport tests remain deferred. These pure policy sources are not evidence of app-level race, hardware or login acceptance.

## Pending acceptance and risks

- Start/Stop under AU preparation; late snapshot/completion rejection; repeated callback stalls; rapid device churn; safe memory retention on detach failure.
- Unplug/replug each endpoint and both, default-device changes, liveness/runtime ID changes, supported/unsupported format or buffer changes; confirm the same saved UIDs/physical patches are used.
- Deny/revoke/restore permission: no prompt/retry storm; explicit action resumes. Repeated invalid AU reports/configuration stay blocked. Helper crash/hang recovery may lose unsaved editor changes; only last saved state is restored.
- Manual Stop during recovery, relaunch after Stop, launch resume off/on, quit with active desired routing, and settings close with routing active.
- Install a reviewed signed bundle in a stable Applications location; enable/disable login and approval; logout/login. Ad-hoc rebuild identities can invalidate microphone grants and service registration; check the actual installed bundle. SDK compilation and Info.plist checks alone do not prove login or macOS 14 runtime compatibility.
- Existing underrun/drift/latency/CPU/soak tests remain unrun. Timers and recovery cannot guarantee continuity across sleep, host restart, plugin failure or hardware loss. No real-time scheduling/workgroup change is included. Phase 5 clean-install, CI/release and 12-hour hardening remain next-phase work.

## Actual commands

- `make doctor` passed: Xcode installed, Swift 6.4, macOS 27 SDK, arm64 host. Executable deployment target inspected as macOS 14.0; macOS 14 runtime remains unverified.
- `make build` passed; final debug compilation completed in 3.88 seconds. One intermediate compiler failure from an ambiguous string conversion was corrected before successful rebuilds.
- Release packaging and ad-hoc signing passed using `make BUILD_CONFIGURATION=release DIST_DIR=/tmp/AudioBridge-phase2 sign` (includes the app packaging target).
- Bundle verification passed with the matching release/DIST_DIR arguments: `cz.bytelab.audiobridge`, AudioBridge executable, version 0.4.0/build 19, macOS 14 minimum, LSUIElement, AudioBridge.icns, matching embedded metadata and valid helper/app signatures.
- `git diff --check` passed.
- No tests, app launch, plugin execution, login registration or hardware/audio checks were performed. `make test` and `make run` remain deferred at the user's request.
