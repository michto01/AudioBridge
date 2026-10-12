# Settings visual correction — 0.5.3 / build 26

Implemented on 2026-10-12 in response to operator feedback.

## Changes

- `DeviceIcon` accepts an explicit size. Bridge headers request 42 points; picker icons retain the font-size default. Resizable device images and SF Symbols fit and clip inside that requested square.
- A shared SwiftUI Layout measures both endpoint cards at equal widths, then places both at the larger measured height with matching top/bottom edges. Header names occupy the same two-line area, keeping icon, channel metadata, meters and trim rows aligned. Output-device volume contributes to the measured height; there is no fixed 285-point height or invisible filler.
- Shared group styling uses 16-point bold headings, compact content spacing, native control backgrounds and rounded borders. Per-group `(i)` popovers contain explanations and detailed status. Popovers allow copying text and scroll within a bounded height.
- Audio, Bridge, Routing, Effects, General, Remote and the menu popover no longer repeat inline explanatory paragraphs. Bridge retains one visible routing badge; Remote retains one listener state per group. Fault details and reasons are available from the associated info button, while Diagnostics directly exposes the current delivery-warning reason and recovery progress.
- Diagnostics has sections for application state, delivery, queues/clocks, AU timing, signal levels and recovery. Values occupy labeled rows. Device catalog, stream properties and session history are expandable. Copy Status has distinct sections and one field per line where practical. Tiny physical-output peaks display as whole dB in Diagnostics instead of rounding linear amplitude to zero.
- The main delay value uses a large number and a separate label. Accounting details are behind its info button or shown as rows when interface debug is enabled. Five-second averaging only collects live primed snapshots.
- Bundle metadata and verification expectations advance to 0.5.3/build 26.

## Checks actually run

- `make build` passed using `SWIFT_BUILD_OPTIONS="--disable-sandbox --scratch-path /tmp/audiobridge-build"` and `SWIFTPM_MODULECACHE_OVERRIDE=/tmp/audiobridge-swift-module-cache`. The first compilation found an ambiguous `greatestFiniteMagnitude` reference in popover sizing; explicitly naming `CGFloat` resolved it.
- `make sign DIST_DIR=/tmp/AudioBridge-refine` with the same build options passed, including compilation, app packaging and helper/app ad-hoc signing. The existing ICNS fallback handled this host's `iconutil` rejection.
- `make verify DIST_DIR=/tmp/AudioBridge-refine` passed. The app is version 0.5.3/build 26, bundle ID `cz.bytelab.audiobridge`, minimum macOS 14.0. Embedded and bundle metadata match, and both signatures verify.
- `git diff --check` passed.
- Automated tests, app launch, visual inspection and live audio/network checks were not run, following the operator's deferred manual acceptance workflow.

## Manual acceptance

Manual review should cover narrow and wide settings windows, long device names, built-in and driver-provided icons, output volume available/unavailable, light/dark appearance, info popover scrolling, warning reasons and copying the reorganized status report. Swift compilation and signature verification alone do not establish visual acceptance.
