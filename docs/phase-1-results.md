# Phase 1 — discovery and permission probe

Date: 2026-10-11. Phase 0 UI was accepted by user testing before this work.

Follow-up: user confirmed that selections survive relaunch and microphone permission is granted. These packaged-app checks are user verified. Physical external-device unplug/replug remains pending.

Device selectors now query the SDK's `kAudioDevicePropertyIcon` (caller-owned CFURL to an image file) and display that image when available and readable. Local file URLs only; unavailable icons use native SF Symbols by transport/direction. Icons are cached by URL and selected by UID; they do not affect routing identity. Device icon property changes are observed. Build, bundle assembly, ad-hoc signing and strict verification passed for this follow-up; UI icon rendering still needs visual review.

## Implemented slice

Shared read-only Core Audio catalog and `AudioBridgeProbe` CLI; input/output UID pickers; explicit one-based physical channel selection for two logical lanes; versioned selection persistence; missing endpoint/channel state; Core Audio property listeners; microphone authorization status and one explicit request button; permission recovery guidance; device diagnostics and timestamped JSON export. The app owns the catalog independently of settings/popover lifetime. No vendor branches, dependencies, device/default/rate mutations or audio IO were added. Routing, meters, login and DSP remain unimplemented.

Settings persist UID/channel mappings under `AudioBridge.routeSelection` in app UserDefaults. Runtime device IDs and names are never saved as routing identity. Unknown schemas and corrupt payloads are retained and editing is disabled instead of silently resetting them. Catalog disappearance/layout changes retain the selected UID and mapping. Reappearance resolves that same UID. Mono duplication requires choosing the same channel for both lanes explicitly.

## Actual checks

Environment: Apple Silicon, macOS 27.0 (26A428), Swift 6.4, macOS 27 SDK, deployment target macOS 14. SDK headers were inspected for property scopes/types, CFString ownership, property listener dispatch/removal and AVAudioApplication availability.

- `make build`: passed (`Build complete!`).
- `make test`: passed, **9 XCTest tests, 0 failures**. Covers first-launch absence of defaults, UID resolution despite runtime ID changes, missing UID despite identical names, changed channels, explicit mono selection, unknown liveness/PCM, persistence, future/corrupt schemas and non-contiguous physical indices.
- `make DIST_DIR=/tmp/AudioBridge-phase1 sign`: passed packaging, ad-hoc signing and strict verification.
- `make DIST_DIR=/tmp/AudioBridge-phase1 run`: launch attempted before the server interruption; its final command output was lost. Resumed verification observed the process at `/private/tmp/AudioBridge-phase1/AudioBridge.app/Contents/MacOS/AudioBridge`, confirming the packaged build launched.
- `make DIST_DIR=/tmp/AudioBridge-phase1 verify`: passed; identifier `cz.bytelab.audiobridge`, minimum macOS `14.0`, `LSUIElement=true`, microphone description present, `Signature=adhoc`.
- `swift run AudioBridgeProbe`: passed; 12 devices, no catalog/property issues in the captured snapshot. Final capture time `2026-10-11T15:03:00Z`.

Raw snapshots are retained locally in `.diagnostics/device-probe-2026-10-11.json` and `.diagnostics/device-probe-2026-10-11-final.json` (ignored by Git). The final report says CLI authorization `not requested`, explicitly scoped to the CLI process; it does not prove the app's TCC state. No microphone request was triggered by automation.

## Observed device facts

These are advertised properties at probe time, not capture/output compatibility tests or latency measurements. All nonempty current virtual streams reported 32-bit float, little-endian, interleaved `lpcm`. The Continuity microphone physical format reported non-interleaved while its virtual IO format was interleaved.

| Endpoint | Transport | Input / output channels | Nominal rate | Current buffer |
|---|---|---|---|---|
| MacBook Pro Microphone | Built-in | 1 / 0 | 48 kHz | 512 frames |
| MacBook Pro Speakers | Built-in | 0 / 2 | 48 kHz | 512 frames |
| BlackHole 2ch | Virtual | 2 / 2 | 48 kHz | 512 frames |
| Microsoft Teams Audio | Virtual | 1 / 1 | 48 kHz | 512 frames |
| NDI Audio input | Virtual, distinct UID | 2 / 0 | 44.1 kHz | 512 frames |
| NDI Audio output | Virtual, distinct UID | 0 / 6 | 48 kHz | 512 frames |
| Continuity iPhone microphone | Wired Continuity | 1 / 0 | 48 kHz | 512 frames |
| MacBook I/O | Aggregate | 1 / 2 | 48 kHz | 512 frames |
| BlackHole + System | Aggregate | 2 / 4 | 48 kHz | 512 frames |
| Wing + Local | Aggregate | 1 / 0 | 48 kHz | 512 frames |
| Ableton Live - Lexicon | Aggregate | 0 / 0 | Reported 0 Hz | 512 frames |
| Dante + Local | Aggregate | 0 / 0 | Reported 0 Hz | 512 frames |

Built-in endpoints advertise 44.1, 48, 88.2 and 96 kHz; BlackHole advertises additional rates. Nonempty devices advertised buffer ranges 15–4096 frames except the NDI input (14–4096). Empty aggregates reported 14–4096. Advertised ranges do not establish that every value can be configured successfully.

No dedicated USB audio interface or headphone endpoint was visible. Aggregate names are not evidence that their named hardware is connected. Zero-channel endpoints appear in diagnostics and are not offered as usable input/output choices.

### Channel numbering correction from hardware evidence

BlackHole + System reported two input channels in stream configuration, but its input stream starting channel was **7**. Channel count therefore cannot safely be treated as the largest physical index. The picker uses reported stream starting indices and format channel counts, preserving channels **7 and 8** instead of silently renumbering them 1 and 2. Added a deterministic regression test. This is read-only probe evidence; aggregate IO remains best effort and requires separate validation before a backend treats the route as supported. Corrupt/extreme formats with over 4096 channels per stream are not exposed by the picker.

Clock-domain 0 was reported by virtual and Continuity endpoints; the SDK defines 0 as unspecified, including between two devices reporting 0. Built-in endpoints reported the same nonzero domain in this snapshot. The bridge still must support independent clocks and actual drift compensation; discovery alone does not establish a shared-clock IO design.

## Phase gate still requiring review

1. Quit any older Audio Bridge build, run `make DIST_DIR=/tmp/AudioBridge-phase1 run`, and open Settings → Audio.
2. Choose devices and both physical lanes. Quit/relaunch and confirm selections are preserved. With the built-in mono microphone, explicitly choose physical channel 1 twice if that is the intended route.
3. Press Request microphone permission, respond to macOS, and confirm status. Check denied/re-enabled behavior in System Settings where appropriate. No capture occurs.
4. With an external interface connected, verify UID/channel discovery, unplug/replug while settings is closed, missing status and restoration of the same UID without substitution. Export device facts before/after.
5. Review Diagnostics, including distinct UIDs for same-name devices and stream formats.

Packaged permission interaction, UI selection/relaunch, hardware arrival/removal, UID stability across physical reconnect, dedicated USB endpoints, headphone detection, Intel/macOS 14 runtime and audio IO are **not verified by this run**. Automated tests simulate selection/reconnection semantics; they are not physical reconnect evidence.

Risk assessment: current property reads do not open audio or change hardware. Changing catalogs can invalidate a property mid-read; such failures are surfaced and refresh can retry, while selection remains intact. Listener ownership retains exact block/address/queue registrations; property events only enqueue refresh. Backend callback lifetime, format conversion, independent clock handling and drift behavior remain undecided until Phase 1 acceptance and suitable hardware facts. Stop before Phase 2.

Permission API reference: [Apple AVAudioApplication requestRecordPermission](https://developer.apple.com/documentation/avfaudio/avaudioapplication/requestrecordpermission(completionhandler:)). Runtime availability was checked in the installed SDK: macOS 14.0+.
