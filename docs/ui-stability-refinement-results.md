# UI and stability refinement — 0.5.1 / build 24

Implemented on 2026-10-12. Automated tests, app launch and live audio/network acceptance were not run; the user previously deferred staged tests and hardware checks.

## Changes

- Bridge keeps the digital input-trim and output-gain sliders beside the meters. The menu popover has no digital trim sliders or Copy Status; output-device volume remains there for exclusive-access use. Bridge endpoint cards have equal fixed height and larger device icons; clicking a device header selects Audio settings.
- Gain sliders are continuous; visible gain and meter values use whole dB labels. Device sample rates use compact kHz labels. Bridge runtime updates once per second. Dynamic bridge/callback delay is averaged from once-per-second snapshots over a rolling five-second window; detailed component snapshots remain available with debug information.
- Microphone permission controls moved to General. Settings restores to the front after returning from a permission prompt/System Settings only when a permission action requested restoration. Remote and Diagnostics tab visibility can be changed in General. Copy Status remains in Diagnostics only. About includes a setup and settings guide.
- HTTP and OSC expose separate listener status and Start/Stop actions. Starting/stopping either one does not stop the other; applying shared endpoint/security edits restarts enabled services. The Remote tab documents paths, request shape, meter units, bearer token and OSC source allowlist.
- Device buffer editors draft 64 frames when within the driver's reported range and never change hardware until one explicit Apply action. Readback is reported. The balanced software FIFO target is `max(64, 2 × larger current interface buffer)` and is explicitly separate; it takes effect on the next Start. The `.low` and `.robust` expert presets remain available.
- Recent-delivery warning changes now use underrun, overrun and format-fault deltas, not recenter counts or rebuffer bookkeeping alone. Short temporary refill periods no longer make the health tracker report a fault by themselves; callback gaps still do. Cumulative counters remain intact.
- Drift reporting now distinguishes a timestamp-derived input/output clock-rate difference from the FIFO occupancy controller's commanded/applied correction. Callback timestamp deltas use shared HAL host time over intervals of at least half a nominal second. PI integration has anti-windup at its existing ±1000 ppm command bounds, and diagnostics count saturated correction callbacks.
- The Xcode 27 `iconutil` on this host rejected both the generated iconset and an iconset exported by itself. The package script now falls back to writing the standard ICNS PNG chunks with Python 3's standard library. The resulting bundle icon reports ICNS format and 1024×1024 dimensions.

## Checks actually run

- `make doctor`: passed; Xcode selected, Swift 6.4, macOS 27 SDK, arm64 host.
- `make build` with `SWIFT_BUILD_OPTIONS="--disable-sandbox --scratch-path /tmp/audiobridge-build"`: passed. `SWIFTPM_MODULECACHE_OVERRIDE=/tmp/audiobridge-swift-module-cache` was needed because the managed shell cannot write SwiftPM's user module cache. SwiftPM also warned it could not update its user manifest cache.
- `make app`, `make sign`, `make verify` with `DIST_DIR=/tmp/AudioBridge-refine` and the same build options: passed. Bundle identity is `cz.bytelab.audiobridge`, version 0.5.1/build 24, minimum macOS 14.0, arm64, AudioBridge.icns present, and both app/helper ad-hoc signatures verify.
- `file` and `sips` identify packaged `AudioBridge.icns` as an ICNS image with 1024×1024 representation.
- `git diff --check`: passed after implementation.
- `make test` was intentionally not run. `make run` was not run to avoid replacing an app instance or starting audio without the user's interaction.

## Manual acceptance still required

- Confirm the Bridge layout, equal card sizing, meter/gain alignment, menu popover native appearance, Settings front restoration, and tab visibility on the user's macOS version.
- Confirm selected devices accept/reject 64-frame drafts as expected, verify the driver readback, and compare 64→128 / 32→64 / 16→64 FIFO targets with real routes. Interface values are not guaranteed discrete by the reported min/max range; drivers may reject them.
- Compare audible delivery with an empty AU chain and active effects. Confirm warning behavior after real frame loss, during queue recentering and callback gaps; cumulative counters should remain available.
- Observe timestamp-derived clock difference, commanded/applied correction and saturation counters on the actual devices. Host timestamps can be invalid or unavailable; no measured value is shown until both clock domains yield valid timestamp intervals. Neither this estimate nor controller telemetry alone proves physical clock accuracy or stable unattended operation.
- Exercise HTTP and OSC separately from Companion, including endpoint reachability, token, allowlist, macOS Local Network privacy and stopping one service while the other remains active.

Separate device buffers and sample rates remain separate properties. Independently opened devices need separate callback buffers. Nominal input/output sample rates must still match because cross-rate conversion is not implemented; independently clocked devices at the same nominal rate are handled by adaptive resampling. The native MenuBarExtra controls its own anchoring, material and corner treatment; the app does not override that system window chrome.
