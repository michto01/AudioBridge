# Roadmap and acceptance gates

Implementation and acceptance are separate. The current **0.7.2/build 41** slice fixes CI concurrency compatibility following the menu presentation work; audio reliability/hardware acceptance remains open. No phase advancement implies completed earlier hardware gates.

## Milestones

| Phase | Implemented scope | Acceptance still relevant |
|---|---|---|
| 0 — App/package | SwiftPM executables, MenuBarExtra/Settings, icon/plist, Makefile, ad-hoc signing | Clean-install, macOS 14/Intel runtime and accessibility |
| 1 — Discovery | Core Audio catalog/probe, UID/physical channels, listeners, persistence and permissions | Representative driver capabilities, reconnect/UID and packaged permission cases |
| 2 — Audio path | Independent HAL callbacks, bounded queues and native Float32 layouts | Physical isolated-channel signal and callback lifetime stress |
| 3 — Drift/routing | Adaptive FIR, N×2 mix, stereo fan-out, smooth gains/meters | Full clock/quality/physical loopback and long-run routing validation |
| 4 — Supervision | Desired/observed state, persisted Stop, capped recovery, opt-in login/resume | Device-loss local latch, permission/configuration faults, sleep/wake and login |
| 5 — Hardening | CI and tag ZIP/checksum workflow, diagnostics and isolation | Documented 12-hour run, clean-account install and broader driver/plugin coverage |

The initial 2×2 scope is superseded by ADR-002; automatic device reconnect by ADR-003. Installed AU effects and remote control are accepted extensions, not new unapproved backend scope. See [ADRs](decisions/README.md).

## Current review priorities

1. **Audio lifecycle:** Stop during preparation/HAL start/live adoption/retry, callback detach, helper failures and bounded memory. Real driver/plugin interleavings remain separate from component tests.
2. **Device safety:** loss/format/rate/buffer/stall cases, notifications, reconnect/relaunch/remote rejection and explicit local re-arm. Never substitute an output.
3. **Plugin isolation:** equal windows with loaded DSP off, empty chain, individual effects, full chain and rendering bypass; record lost frames, queue bounds, complete-cycle/DSP/wake timing and main/helper CPU separately.
4. **Latency/soak:** physical loopback and documented 12-hour nominal run with bounded queues/CPU/memory and no unaccounted frame loss; repeat dry and with deployment effects.
5. **0.7 UI:** light/dark, English/Czech, long/missing device names, volume unavailable/loading, startup/warning/latch states, focus and keyboard/VoiceOver.
6. **Distribution:** verify clean-account extraction/launch, stable-path login, permissions after rebuild and tag CI. Ad-hoc artifacts remain prerelease development builds.

Current backend gaps: integer PCM, independent nominal-rate conversion, same-device duplex and independently opened multiple output devices. These need separate decisions and tests; no automatic expansion is implied.

## Evidence and execution protocol

The last recorded automated run passed 72 tests on 0.6.5. Menu revisions passed release package/signature checks in local output storage; those checks are not visual or hardware acceptance. Operator reports of clean audio lack a timed 12-hour record. Details are compacted in [validation history](history/validation.md).

For each working slice: identify the gate, choose the smallest concrete change, document invariants/risks, implement focused regressions, report commands actually run, update current docs/ADRs and commit a scoped change. Mark deferred hardware/plugin checks explicitly. Stop for review before extending scope; do not claim unattended readiness from build checks.
