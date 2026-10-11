# Audio settings follow-up — 2026-10-11

User requested buffer settings and visible signals before manually checking microphone-to-MacBook-speaker routing, then reported disabled Start/Stop and a missing app icon in microphone privacy settings. This authorizes a narrow meters/buffer slice from Phase 3; the broader Phase 3 work remains pending. Automated tests and live HAL checks remain deferred at the user's request.

## Changes

- Measured per-lane input/output peak bars, numeric dBFS, and full-scale indicators in Settings and the menu popover. Latest completed callback-buffer peaks are polled at 20 Hz; short peaks between polls may not appear on bars. Full-scale sample counts accumulate for the entire run, so CLIP stays visible until Stop/Start. Silence is −∞ dBFS; stopped, unprimed output or no fresh callback shows Inactive. No silence alerts.
- Input measurement occurs before FIFO insertion. Output measurement occurs after FIFO consumption and explicit duplicate-output summation, before HAL delivery; it does not include system speaker volume or prove audible output. Underrun zeros are measured as zeros. Nonfinite input/summed output is replaced with zero and flagged as a format fault, stopping at the next lifecycle check.
- Callback metering is bounded C work with preallocated samples and integer lock-free atomics. No callback allocation, logging, Swift, UI, blocking or HAL property queries were introduced. Snapshots are approximate and fields can span adjacent callbacks. Lifecycle checks run every 500 ms, independently of 50 ms meter polling; callback-stall timeout remains based on elapsed time.
- Low/Balanced/Robust profiles persist under `AudioBridge.bufferProfile`. For largest current device callback buffer B, initial fill targets are max(256, 2B), max(1024, 4B), max(4096, 8B). With B=512 these are 1024, 2048 and 4096 frames. FIFO capacity is a power of two, at least 16384 and at least twice the target, up to 65536 for supported devices. Changes require Stop and take effect on next Start. Balanced is default.
- Actual device buffer sizes/ranges remain read-only. Profile sizes are provisional safety margins, not measured latency or drift correction. Startup target duration is target frames / actual sample rate. FIFO occupancy, fill state and underrun/overrun frames are visible in Audio settings.
- Start now reports the first blocking reason, including missing channel selections, permission and unsupported format/rate. A mono input button explicitly maps its sole physical channel to both logical lanes without selecting devices automatically. Stop clears displayed levels and acknowledges only after serial HAL cleanup. Start/Stop are near the top of Audio settings.
- Version 0.2.1, build 2 identifies this update. Diagnostics shows running bundle path/build. Bundle icon remains the user-supplied full `.icns` family. `make run` refreshes this bundle's Launch Services registration before opening it; it does not reset TCC grants.

## Diagnosis and actual checks

The user clarified Start was greyed out before any press, so the engine had not been invoked. Read-only saved preference inspection confirmed built-in microphone channels 1/1 and built-in speaker channels 1/2 were already configured correctly. Missing lanes therefore do not explain this user's reported block. The exact remaining gate (current discovery/liveness, permission or configuration state) has not been observed in the running UI. Start readiness feedback exposes it without bypassing safety validation; live Start/Stop remains unverified. A mono convenience button supports other incomplete first-time configurations.

Read-only process inspection showed the Phase 2 bundle running at `/private/tmp/AudioBridge-phase2/AudioBridge.app`. Launch Services inspection found Phase 0, Phase 1 and checkout bundles without icon metadata alongside Phase 2 with `CFBundleIconFile=AudioBridge.icns`. That is evidence of competing registrations, not proof of which bundle System Settings used. Version increment and refreshing the current registration address stale identity/icon resolution. Visual privacy-list confirmation remains pending; no system-wide cache or authorization reset is performed.

- `make build`: passed (`Build complete! (2,87 sec)`).
- `make DIST_DIR=/tmp/AudioBridge-phase2 sign`: passed after final UI changes (`Build complete! (2,83 sec)`), plist lint and strict ad-hoc signature valid.
- `make DIST_DIR=/tmp/AudioBridge-phase2 verify`: passed; version 0.2.1/build 2, `cz.bytelab.audiobridge`, macOS 14 minimum, `CFBundleIconFile=AudioBridge.icns`, arm64, strict ad-hoc signature valid.
- Refresh current app's Launch Services registration with `lsregister -f /tmp/AudioBridge-phase2/AudioBridge.app`: passed (exit 0). Visual privacy-list confirmation pending.
- Final rebuild after callback-freshness adjustment passed (`Build complete! (2,67 sec)`); packaging/signing/verification repeated successfully. Input/output activity is tracked independently so asynchronous slow callbacks do not produce a false stall; meter freshness allows at least 250 ms (or three configured callback periods).
- Final UI packaging rebuild passed (`Build complete! (2,09 sec)`), followed by successful strict verification and registration refresh. Start's reason appears directly beside its controls.
- New `AudioIndicatorTests` cover silence/unity/half-amplitude dBFS, lane-specific peaks/full-scale counts and provisional buffer targets. These and existing tests were **not run or compiled**.
- App relaunch, actual Start/Stop, microphone capture, audible routing, feedback behavior and UI appearance: **not verified by automation**.

## Deferred manual check

1. Quit the older Audio Bridge process through its menu. Run `make DIST_DIR=/tmp/AudioBridge-phase2 run`; confirm About says 0.2.1 and Diagnostics build 2. Close/reopen System Settings if reviewing its cached icon.
2. Select MacBook microphone and press Use mono input in both lanes (both physical channel 1). Select MacBook speakers with output channels 1 and 2. Grant permission if required; otherwise inspect the displayed Start unavailable reason. No default device substitution or global rate change occurs.
3. Keep system speaker volume low, choose Balanced and press Start. Speak briefly: input and output meters should show local signal, callbacks/frames progress, and FIFO should fill. Stop immediately if acoustic feedback occurs. Repeat Stop/Start and Low/Robust only when ready; record any fault text and glitch counts.
4. Stop must cease routing and show Inactive meters. Closing settings must not stop a running route. Full drift/soak and hardware compatibility gates remain pending.
