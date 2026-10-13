# 0.7 menu popover — build 39

## 0.7.1 / build 40 corrections

Operator feedback identified double outer corners, clipped Czech volume text, persistent info-button focus decoration, small device names and blank space beside the meter values. The correction removes the extra painted outer material/border and uses MenuBarExtra's native surface/corners. Endpoint card styling is retained. Device names use 15-point semibold type with a matching two-line height on both cards. The menu volume label is shortened to **Volume / Hlasitost**, sized to its intrinsic width; Settings retains the full device-volume label with intrinsic sizing as well.

Info buttons suppress the SwiftUI focus effect while remaining buttons with keyboard/accessibility activation. Menu meters omit the reserved trailing CLIP column; a real CLIP indication overlays the meter only while active, leaving dB at the right edge. Settings meters retain their separate CLIP column. Meter sampling, animation and audio processing are unchanged.

Release `make sign` (including build/app packaging) and `make verify DIST_DIR=/tmp/AudioBridge-0.7.1-final` passed. Bundle: `/tmp/AudioBridge-0.7.1-final/AudioBridge.app`, version 0.7.1/build 40, stable `cz.bytelab.audiobridge` identity and macOS 14.0 minimum. Host/helper signatures, embedded plist and both localization files verify. No tests were added or run; rendered UI and keyboard/accessibility behavior still require operator review. The running app was not replaced or launched.

The operator supplied a visual reference on 2026-10-13 and requested its hierarchy/identity, while retaining existing meters and leaving source selection in Settings.

## Implemented

- A 440-point popover with the bundled app icon, prominent title/subtitle, colored status, status explanation behind `(i)` and elapsed runtime.
- Matching rounded input/output cards with 30-point device icons inside 50-point icon tiles. Long names reserve the same two-line area; names are read-only. Missing/unconfigured devices remain explicit.
- A downward flow indicator between the cards, colored by the existing real routing activity.
- A distinct output-device volume row and footer with the shared Start/Stop/re-arm action, one Settings action and labeled Quit. Settings retains its existing focus/front behavior. No digital trim or device picker is added to the menu.
- System materials and semantic surfaces rather than forced dark colors. Existing native-layer meters, live data, clipping/inactive indications and update cadence remain intact.
- English/Czech strings for the subtitle and compact startup/action-required status. Full status reasons remain available from the header info button.

Source changes are isolated to `MenuPopoverView.swift`, menu wiring/settings-focus visibility in `AudioBridgeApp.swift`, an optional width parameter on the shared routing button, localization and 0.7.0/build 39 metadata. No audio-engine, AU transport or remote changes.

## Validation and review

Release build, app packaging and ad-hoc signing succeeded using the existing Makefile workflow with isolated Swift scratch/cache storage. `make verify DIST_DIR=/tmp/AudioBridge-0.7.0-final` checks host/helper signatures, localizations and embedded bundle identity. Bundle: `/tmp/AudioBridge-0.7.0-final/AudioBridge.app`, `cz.bytelab.audiobridge`, minimum macOS 14.0, version 0.7.0/build 39. This is an arm64 development bundle, not notarized distribution.

No tests were added or run for this presentation-only slice. The preceding 0.6.5 run passed 72 tests; that is historical evidence, not a new test execution. No app launch, screenshot capture, live device operation or permission changes were performed; the existing running app was left untouched.

Operator review remains needed for light/dark and English/Czech layouts, very long device names, missing devices, volume capability/loading/error states, stopped/startup/warning/re-arm states and keyboard/VoiceOver interaction. The new runtime timer is confined to its header subview. No claims of reduced CPU or completed audio/12-hour acceptance are made.
