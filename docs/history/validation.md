# Development and validation history

This compact record replaces detailed per-stage reports. They remain in Git before the documentation consolidation; use `git log -- docs` and `git show <commit>:docs/<old-file>.md` for exact historical commands, fixtures and snapshots. This record is evidence, not a current behavior contract. Current behavior is defined by [architecture](../architecture.md), [ADRs](../decisions/README.md) and [testing](../testing.md).

## Milestones

| Revision | Meaningful work / evidence |
|---|---|
| 0.1 shell/discovery | SwiftPM bundle/UI, probe, UID persistence and permissions; 1 then 9 tests passed. Operator accepted shell/persistence/microphone permission. Physical reconnect remained pending. |
| 0.2–0.3 | Independent HAL callbacks, Float32 queues, gains/meters, isolated AU hosting, adaptive FIR and expandable stereo routing. Many tests were authored but execution deferred at operator request; builds/signatures aren't audio acceptance. |
| 0.4 | Desired/observed recovery, persisted Stop and opt-in login/resume. Later ADR-003 superseded automatic device-loss reconnect. |
| 0.5 | Remote control, output volume/exclusive access, diagnostic reset, reduced UI work, signaled worker, Mach scheduling and safe renderer handoff. CPU point readings suggested avoidable UI work but weren't controlled benchmarks. |
| 0.6.0–0.6.3 | Pre-teardown/lifetime fixes, AU workgroups/cached blocks/latency notifications, bounded timestamp-addressed input pulls, persistent dry transport, output-before-capture startup, Simple/Expert and Czech/English/permission refinements. |
| 0.6.4 / build 37 | Searchable cached effects and deferred suite execution: 61 XCTest tests passed. Operator reported clean audio/UI and partial device-loss checks, without exact duration/build/setup; no documented 12-hour gate. |
| 0.6.5 / build 38 | Independent audit fixes, sparse routing/prepared FIR/narrow probes and complete-cycle metrics; 72 tests passed. Separate release bundle identity/signatures passed. No live new-build audio/plugin/network test performed. |
| 0.7.0–0.7.1 / builds 39–40 | Menu hierarchy/identity and visual corrections. Release package/signature checks passed with local temporary output; no new suite, rendered-UI or hardware test execution. Bash 3.2 empty-option packaging failure subsequently corrected. |

## Hardware evidence boundaries

The 2026-10-11 read-only probe found built-in/virtual/aggregate endpoints, not a verified external USB signal path. An aggregate advertised two input channels starting at physical indices 7/8: this drove explicit non-contiguous addressing rather than channel-count renumbering. Device names/advertised capabilities don't establish connected hardware or IO compatibility.

The operator's detailed 0.6.1 snapshot used MacBook Pro Microphone → External Headphones at 48 kHz, input 128 / output 32 / reserve 128 / AU 64 with EverClean → COMPER → SSQ. It showed 120.58 seconds of recent health, zero underruns/no late wakes/over-budget blocks in that snapshot, but cumulative 1,920 overruns and 1,631 recentered frames. Reported device delay was 35.06 ms and bridge/callback allowance 8.35 ms; 43.42 ms subtotal wasn't physical loopback. Later reported zero-loss operation omitted duration/build details. Neither certifies indefinite reliability or this latest revision.

## Audit and automated provenance

Independent source audit baseline: 0.6.4, commit `1c2acef`; report commit `b7f5e99`. It identified editor-save command wedging, a Stop/start transition gap, stale accepted remote commands/status, OSC integer decoding and redundant runtime/routing/FIR work. No confirmed general mutex cycle/use-after-free was established; source inspection isn't proof of absence.

Fix commits `e3ff014` and `bf74d21` corrected these and added cycle/adoption metrics. Three reviewers inspected the follow-up; a missing allocation guard and retired-attempt accumulation were caught and corrected before final tests. Final 0.6.5 suite completed **2026-10-13 09:12:17 local**, **72 XCTest tests, zero failures**, 0.534 seconds. New coverage included parser/epoch disable/restart, candidate editor state/exactly-once reply, cancellation gate ownership/start rejection, cycle/protocol accounting, topology matching, prepared FIR near-integer/short-read/reset cases and sparse 2/16/256-channel ramps/Off silence. Fan-out reference tolerance was 1e-6 for Float expression rounding.

These component checks don't execute Network.framework sockets, actual Stop/AudioDeviceStart interleavings, plugin editors or driver teardown. Queue wake tests exercise natural ordering, not all forced fence/EINTR/lifetime cases. Current [acceptance checklist](../testing.md) retains those gaps.

## Component benchmark retained from 0.6.5

`scripts/benchmark-processing.sh` compares `1c2acef` and current C components with Apple clang `-O3`, five trials. Routing: 128-frame blocks, two active patches, 1,000 iterations; FIR: 32 outputs at ratio 1.0002, 10,000 iterations. Demand/render totals and signal checks matched. It loads no devices/plugins/app.

| Component | Baseline median µs/block | Optimized median µs/block |
|---|---:|---:|
| Routing, 2 channels | 2.422 | 2.466 |
| Routing, 16 channels / 2 active | 15.996 | 2.559 |
| Routing, 256 channels / 2 active | 247.798 | 3.530 |
| FIR demand + processing | 0.817 | 0.778 |

Stereo trial ranges overlap; no stereo improvement claimed. These measurements exclude IPC/HAL/plugins/probes and uncontrolled system load; wide sparse gains don't imply mono/stereo whole-app CPU savings or deadline/audio-quality guarantees.

## Packaging evidence and unresolved storage issue

Local checks used Apple Silicon, Xcode/Swift 6.4 and macOS 27 SDK with deployment target 14.0. 0.6.5 and 0.7 release bundles verified stable `cz.bytelab.audiobridge`, embedded/bundle plist equality, icon/languages and strict ad-hoc helper/host signatures in temporary local output. No notarization, distribution signing or new-build launch was performed for those slices.

Default build/package now works without extra Swift arguments after the Bash 3.2 fix (`fceeb37`). Repository `dist/` signing can pass immediately then fail verification when File Provider reattaches FinderInfo. A targeted experiment corrected the ignore attribute from erroneous binary `01` to the tool's text `1` (hex `31`) on dist/app; FinderInfo still returned. Cloud-upload exclusion wasn't verified. No whole-project exclusion/relocation or system-cloud setting change was made. Local `/tmp` output signing/verification passed. See [build troubleshooting](../build.md#file-provider-and-signatures).

## Open release evidence

Timed 12-hour dry/full-chain soak, physical loopback/quality, representative external drivers, full loss/re-arm/sleep/login/permissions, actual remote socket shutdown, third-party editor failure paths, clean-account install, Intel/macOS 14 runtime and visual/accessibility checks remain open. GitHub CI/tag workflow was authored; local builds don't certify remote workflow execution. Historical acceptance statements must not be promoted to results for a later revision.
