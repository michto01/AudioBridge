# Audio Bridge — specification and Codex handoff

Status: **Phase 0 accepted; Phase 1 settings persistence and permission confirmed by user. Phase 2 experimental audio path implemented and compiled; automated tests and live audio acceptance deferred at user request.**

Audio Bridge is a universal macOS 14+ native SwiftUI menu-bar application that routes audio between independently selected Core Audio input and output devices. Version 1 processes two selected input channels into two selected output channels using a configurable 2×2 matrix. No Dante, TightAV, ATEM, USB, or vendor-specific integration is required.

Read documents in this order:

1. [Overview](docs/overview.md) — purpose, decisions, scope and constraints.
2. [Architecture](docs/architecture.md) — processing, clocks, concurrency and failure modes.
3. [Design](docs/design.md) — UX, settings and state semantics.
4. [Plan](docs/plan.md) — staged execution, acceptance gates and deliverables.
5. [Testing](docs/testing.md) — deterministic and hardware validation.
6. [Compliance](docs/compliance.md) — Apple permissions, signing, distribution, licences and operational safeguards.
7. [AGENTS.md](AGENTS.md) — standing implementation instructions for Codex.

## Build strategy

Swift Package Manager (`Package.swift`) is the canonical build definition. A thin `Makefile` invokes `swift build`, `swift test`, and shell scripts for assembling, signing and launching a genuine `.app` bundle. No `.xcodeproj` is required. Xcode/Apple SDK tooling must be installed on the target Mac (Swift 5.9+ and a macOS 14+ SDK).

```sh
make doctor
make build
make test
make app
make sign
make verify
make run
make release
make clean
```

The app has a native menu-bar popover and separate settings scene. It discovers real Core Audio devices, persists explicitly selected UIDs and physical channels, observes device/property changes and provides a microphone permission button. Phase 2 adds manual Start/Stop for experimental identity routing. User-requested follow-ups add per-lane peak meters, clip indicators, compact buffer controls and smooth input trim/output gain (0 dB defaults). Drift correction, rate conversion, automatic recovery and login registration are not implemented. Closing settings does not quit the app; use Quit in the popover.

Run the current build with `make DIST_DIR=/tmp/AudioBridge-phase2 run`. Quit an older running copy first. In Settings → Audio, choose both endpoints and both physical lanes explicitly, then press Start when ready for an attended check. This initial path requires two separate devices, matching current sample rates and one packed native-endian Float32 PCM stream per selected direction. Planar and interleaved layouts are normalized to internal stereo Float32; unsupported formats are rejected with a reason. These temporary restrictions are not the universal v1 compatibility contract. Duplicate input channels copy into both lanes; duplicate output channels sum both lanes and can clip. Device selection never changes macOS default devices or sample rates. A missing endpoint or invalidated channel selection stays saved and is shown as unavailable.

The FIFO does **not** compensate independently clocked devices: even at equal nominal rates, buffers may eventually overrun or underrun. This build is not ready for unattended streaming. Nothing captures automatically on launch. Start requests are checked against a fresh UID catalog; device loss or format changes stop this experimental path without fallback or automatic retry. Settings show human-readable device names; technical UIDs remain in Diagnostics.

For a built-in microphone-to-speakers check, choose the microphone, press **Use mono input in both lanes**, then choose the speakers and physical output channels 1 and 2. Keep the Mac's speaker volume low to avoid acoustic feedback. Start becomes available only after the complete route and permission are valid; a reason is shown otherwise. Meters are inactive before Start and show measured local buffer peaks afterward. See [audio settings and deferred checks](docs/audio-settings-results.md).

The compact bridge-buffer slider shows its valid range; **Expert** allows exact startup-fill frame values and presets. This controls the bridge FIFO. Each endpoint also shows a separate **Interface buffer** slider/exact frame field and **Apply** when the driver exposes a writable HAL buffer size. Stop routing before applying; this device-wide change may affect other audio apps. The accepted value is read back and the catalog refreshed; requests can be rounded or rejected by the driver. Read-only drivers show an explanation. See [interface buffer/editor follow-up](docs/interface-buffer-editor-results.md).

Input trim and output gain can change live, apply to both lanes, and persist; their −60 to +12 dB controls ramp over 20 ms. Input meters show samples after trim, while a separate warning tracks raw capture reaching full scale. Digital attenuation cannot repair capture clipping. See [buffer and gain follow-up](docs/buffer-gain-results.md).

Development builds are ad-hoc signed. This build's designated requirement is its code hash, which changes on rebuild; this may invalidate an earlier microphone grant. The user reported routing working after toggling AudioBridge's microphone permission. If a rebuilt app's grant appears stale, quit the app, toggle its entry in System Settings and reopen the same bundle. No permission reset or weaker signing requirement is applied automatically.

Settings → Diagnostics shows actual stream formats and property errors and exports a JSON report including permission context. `make probe` runs the same read-only catalog as a CLI. CLI microphone authorization is **not evidence of packaged-app authorization**; request/check permission in Settings → Audio. Raw local diagnostic snapshots under `.diagnostics/` are ignored by Git and contain no audio samples.

Artifacts normally go to `dist/AudioBridge.app`. `make run` packages and ad-hoc signs, refreshes that bundle's Launch Services registration (including its icon), then opens it. Quit an older running copy first: opening another build does not replace the running process. If System Settings has cached an old icon, close and reopen it after launching the current bundle. `make release` builds the release configuration, signs, verifies and creates a ZIP with a SHA-256 checksum. Ad-hoc signing does not provide Developer ID trust or notarization. `make clean` clears SwiftPM build products and retains distribution artifacts for review.

File Provider storage on the development machine attaches Finder metadata that can invalidate bundle signing. Use local output storage for reliable packaging, for example `make DIST_DIR=/tmp/AudioBridge-phase2 run` and `make DIST_DIR=/tmp/AudioBridge-phase2 release`. Temporary artifacts are disposable, not a stable deployment path. Tests automatically use isolated temporary build storage and remove it afterward. Packaging refuses to replace a bundle with another identifier or a symlink. There are no third-party dependencies or extra entitlements. Packaging converts `Resources/AudioBridge.png` into a complete `AudioBridge.icns` family using Apple's `sips` and `iconutil` and includes it in the app bundle.

See [Phase 0 results](docs/phase-0-results.md), [Phase 1 results](docs/phase-1-results.md) and [Phase 2 results and deferred checks](docs/phase-2-results.md) for actual checks and remaining acceptance steps.

## Installed Audio Unit effects

Input trim and output gain sit above their meters in Settings → Audio and the menu popover. Settings → Audio → Audio Unit effects lists installed AU effects. Stop routing to add, reorder, bypass or remove up to eight slots. Adding an effect opens its editor; **Edit** reopens it. A separate helper window hosts AUv2 Cocoa editors or AUv3 view controllers where supplied, otherwise generic parameters and factory presets. **Save settings** stores plugin state; the next Start loads it. Close editor cancels without changing saved state.

The chain order is input trim → enabled AU effects → output gain. Effects must accept stereo planar Float32 at the route's sample rate; optional additional buses are disabled, with no sidechain or MIDI routing. Active effects require at least 256 startup frames. Missing plugins, preparation timeout, helper exit, render error or stalled helper stop routing without silently substituting or bypassing an effect. Plugin latency is reported separately, not claimed as measured end-to-end latency. VST hosting is not included.

Plugins run in a separate signed helper using shared-memory audio queues, outside HAL callbacks. This isolates process crashes, not security privileges: third-party code retains the user's access and may have its own licensing or network behavior. Compatibility and performance remain untested. Drift compensation, automatic recovery, login startup and long-duration validation are still required for unattended operation. See [AU hosting results and deferred checks](docs/au-hosting-results.md).

## Decisions already locked

- Launch at login; automatically route when configured devices are present.
- Bind input and output by stable Core Audio device UID; **never silently fall back** to another device.
- 2×2 configurable amplitude mixing matrix; stereo identity preset by default.
- Silence is metered but **never generates silence notifications**.
- Menu-bar popover for monitoring; separate settings window.
- Retry recoverable failures indefinitely with capped backoff; deliberate Stop always wins.
- Preferred processing rate 48 kHz; negotiate actual hardware formats safely.
- Initial release is a login-session app, not a system daemon.

## Important unknowns to validate on hardware

- Actual Core Audio capabilities, channel layouts, supported formats, and UID behavior across representative devices and reconnects.
- Whether the built-in headphone output exposes expected stereo format and volume control.
- Whether HAL device I/O APIs chosen support the required independent device configuration on macOS 14+.
- Actual latency, drift, glitches, and sample-rate behavior across representative independent devices; analog destination calibration belongs to the deployment scenario.

See [Plan](docs/plan.md) for the mandatory device-probe milestone before finalizing the backend.

## Device independence

See [`docs/device-compatibility.md`](docs/device-compatibility.md) and [`docs/decisions/ADR-001-universal-core-audio.md`](docs/decisions/ADR-001-universal-core-audio.md). TightAV/ATEM is an example deployment only.
