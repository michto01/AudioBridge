# Audio Bridge — specification and Codex handoff

Status: **Phase 0 accepted; Phase 1 settings persistence and permission confirmed by user. Phase 3 adaptive drift and matrix implemented and compiled; automated tests and live audio acceptance deferred at user request.**

Audio Bridge is a universal macOS 14+ native SwiftUI menu-bar application that routes audio between independently selected Core Audio input and output devices. Version 1 mixes N explicitly mapped physical inputs into stereo, processes a stereo AU/drift path, and copies L/R to explicitly mapped physical outputs on one selected output device (ADR-002). No Dante, TightAV, ATEM, USB, or vendor-specific integration is required.

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

The app has a native menu-bar popover and separate settings scene. It discovers real Core Audio devices, persists explicitly selected UIDs and physical channels, observes device/property changes and provides a microphone permission button. Phase 2 adds manual Start/Stop for experimental identity routing. User-requested follow-ups add per-lane peak meters, clip indicators, compact buffer controls and smooth input trim/output gain (0 dB defaults). Phase 3 adds adaptive drift resampling, an N×2 input grid and stereo physical output fan-out. Arbitrary nominal-rate conversion, automatic recovery and login registration are not implemented. Drift and audio-quality acceptance remains pending. Closing settings does not quit the app; use Quit in the popover.

Run the current build with `make DIST_DIR=/tmp/AudioBridge-phase2 run`. Quit an older running copy first. In Settings → Audio, choose both endpoints explicitly. In Routing, press Mono → L + R or Stereo for a simple input preset, then Stereo for the first output pair, or patch physical channels directly in the grids. Mono outputs can take L or R, or an explicitly chosen L+R sum. Right-click an input cell for gain (0–2, 1 = unity), and an output row for mono sum. One side can feed multiple destinations; L/R effects and drift are processed only once. Mixing/gain changes can run live; changing device or buffer topology requires Stop.

This path requires two separate device UIDs with matching current sample rates and native packed Float32 PCM streams. Supported interleaved/planar multi-stream layouts are validated against reported IO buffers; ambiguous, disabled, integer or other unsupported layouts fail with a reason. Aggregate Devices configured by the operator are eligible but remain best effort and require hardware validation. Same-device duplex and independently opened multiple output devices are not implemented. Missing endpoints/channels are retained without fallback. Version-1 lane/matrix preferences migrate to the version-2 route with an original-payload backup. Mixing now occurs before effects, so non-linear plugins can sound different from the old post-effect matrix; review the sound after migration.

The FIFO alone does **not** compensate independently clocked devices; this build adds bounded adaptive FIR resampling. Its tuning, filtering and sustained clock behaviour remain unverified. This build is not ready for unattended streaming. Nothing captures automatically on launch. Start requests are checked against a fresh UID catalog; device loss or format changes stop this experimental path without fallback or automatic retry. Settings show human-readable device names; technical UIDs remain in Diagnostics.

For a built-in microphone-to-speakers check, choose the microphone and speakers in Audio, then press **Mono → L + R** and output **Stereo** in Routing (review the displayed physical channel indices). Keep the Mac's speaker volume low to avoid acoustic feedback. Start becomes available only after the complete route and permission are valid; a reason is shown otherwise. Meters are inactive before Start and show measured local buffer peaks afterward. See [audio settings and deferred checks](docs/audio-settings-results.md).

Bridge startup fill and interface buffers offer common frame-size dropdowns plus **Custom** text entry. Choices are filtered to the valid range; powers of two are suggestions, not a guaranteed driver capability list. **Expert** also offers FIFO presets. Interface **Apply** is available only when the driver exposes a writable HAL buffer size. Stop routing before applying; this device-wide change may affect other audio apps. The accepted value is read back and the catalog refreshed; requests can be rounded or rejected. Read-only drivers show an explanation. See [catalog/icon/buffer follow-up](docs/catalog-icon-buffer-results.md).

Input trim and output gain can change live, apply to both lanes, and persist; their −60 to +12 dB controls ramp over 20 ms. Input meters show samples after trim, while a separate warning tracks raw capture reaching full scale. Digital attenuation cannot repair capture clipping. See [buffer and gain follow-up](docs/buffer-gain-results.md).

Full-scale audio is a signal-level indication, not a routing glitch. Meter **CLIP** holds briefly; cumulative counts remain in Diagnostics. Delivery faults (underrun, overrun, invalid format/nonfinite data) affect routing status independently. For CPU comparisons use an optimized bundle: `make BUILD_CONFIGURATION=release DIST_DIR=/tmp/AudioBridge-phase2 sign`, then `make DIST_DIR=/tmp/AudioBridge-phase2 verify`. Quit the old process before opening the new bundle. Build 12 uses this release configuration; no measured CPU improvement or COMPER needle repair is claimed. See [clipping, AU UI and CPU follow-up](docs/clip-au-cpu-results.md).

Development builds are ad-hoc signed. This build's designated requirement is its code hash, which changes on rebuild; this may invalidate an earlier microphone grant. The user reported routing working after toggling AudioBridge's microphone permission. If a rebuilt app's grant appears stale, quit the app, toggle its entry in System Settings and reopen the same bundle. No permission reset or weaker signing requirement is applied automatically.

Settings → Diagnostics shows actual stream formats and property errors and exports a JSON report including permission context. `make probe` runs the same read-only catalog as a CLI. CLI microphone authorization is **not evidence of packaged-app authorization**; request/check permission in Settings → Audio. Raw local diagnostic snapshots under `.diagnostics/` are ignored by Git and contain no audio samples.

Artifacts normally go to `dist/AudioBridge.app`. `make run` packages and ad-hoc signs, refreshes that bundle's Launch Services registration (including its icon), then opens it. Quit an older running copy first: opening another build does not replace the running process. If System Settings has cached an old icon, close and reopen it after launching the current bundle. `make release` builds the release configuration, signs, verifies and creates a ZIP with a SHA-256 checksum. Ad-hoc signing does not provide Developer ID trust or notarization. `make clean` clears SwiftPM build products and retains distribution artifacts for review.

File Provider storage on the development machine attaches Finder metadata that can invalidate bundle signing. Use local output storage for reliable packaging, for example `make DIST_DIR=/tmp/AudioBridge-phase2 run` and `make DIST_DIR=/tmp/AudioBridge-phase2 release`. Temporary artifacts are disposable, not a stable deployment path. Tests automatically use isolated temporary build storage and remove it afterward. Packaging refuses to replace a bundle with another identifier or a symlink. There are no third-party dependencies or extra entitlements. Packaging converts `Resources/AudioBridge.png` into a complete `AudioBridge.icns` family using Apple's `sips` and `iconutil` and includes it in the app bundle.

See [Phase 0 results](docs/phase-0-results.md), [Phase 1 results](docs/phase-1-results.md) and [Phase 2 results and deferred checks](docs/phase-2-results.md) for actual checks and remaining acceptance steps.

## Installed Audio Unit effects

Settings → Playback contains Start/Stop, input trim/output gain above their meters, and a delay/processing breakdown. The menu popover retains quick controls. Settings → Audio configures devices, current driver buffer values, bridge fill and permission. Settings → Effects lists installed AU effects. Add, reorder, enable or remove up to eight slots while routing; the helper prepares a replacement chain alongside the current one and switches between processing blocks. Close an editor before changing the chain. Preparation failures stop routing, preserving explicit device selection. Switching resets plugin histories/tails and is not guaranteed click-free or latency-matched.

Playback delay adds reported input/output device and routed-stream latency, safety offsets, callback buffer allowances, observed capture/processed queues and in-flight AU block, FIR lookahead and declared AU signal latency. Missing values remain Unknown; startup fill and processing wall time are not added twice. The displayed chain allowance is an **estimate**, not measured physical end-to-end latency. AU last/mean/max block wall time is separate performance telemetry, including scheduling/preemption; queue min/max is sampled while primed. Copy status includes the components. Interface controls read the device's existing value; when it is unavailable the draft fallback is 128 frames within the reported range, with no automatic hardware write. See [Playback/delay results](docs/playback-delay-results.md).

The effect catalog is cached locally. First launch without a valid cache scans metadata in a separate background helper, showing a spinner and found count; device discovery uses its own queue. Later launches use the saved list immediately. **Rescan** refreshes it manually after installing/removing plugins and keeps existing results usable meanwhile. A stale cache cannot guarantee plugin availability; loading the actual unit still validates it.

Adding an effect opens its editor; **Edit** reopens it. Editor windows fit the plugin's advertised size, clamped to the display, with scrolling for oversized legacy views. During routing the editor controls the **same plugin instance that renders audio**, so parameter changes apply immediately without app/HAL restart. **Close and save** persists its state; the live editor has no Cancel rollback. Close it before Stop if the latest settings must be saved. When stopped, editing uses a separate instance with Save/Cancel for the next Start. **Bypass chain** outputs dry audio while keeping effects processing and editable. Plugin windows display **Chain bypassed**; trim/gain stay active. Enable chain restores processed output. This explicit bypass is saved separately from individual slot enable flags and retains plugin CPU cost.

The chain order is physical input matrix → input trim → enabled AU effects → adaptive drift resampler → output gain → physical output fan-out. Effects must accept stereo planar Float32 at the route's sample rate; optional additional buses are disabled, with no sidechain or MIDI routing. Startup fill can be as small as 16/32 frames when both current device buffers permit it. AU processing uses 16–256 frame blocks selected from the startup target. Zero is unsupported. Smaller values are experimental and can underrun; presets remain conservative. Change interface buffers first, then bridge fill while stopped. Missing plugins, preparation timeout, helper exit, render error or stalled helper stop routing without silently substituting or bypassing an effect. Plugin latency is reported separately, not claimed as measured end-to-end latency. VST hosting is not included.

Plugins run in a separate signed helper using shared-memory audio queues, outside HAL callbacks. The helper remains present even for an empty chain to allow live insertion. This isolates process crashes, not security privileges: third-party code retains the user's access and may have its own licensing or network behavior. Compatibility and performance remain untested. Drift validation, automatic recovery, login startup and long-duration validation are still required for unattended operation. See [AU hosting results](docs/au-hosting-results.md), [live editor follow-up](docs/live-au-results.md) and [editable bypass/small buffers](docs/bypass-small-buffer-results.md).

## Decisions already locked

- Launch at login; automatically route when configured devices are present.
- Bind input and output by stable Core Audio device UID; **never silently fall back** to another device.
- N×2 input mix with mono/stereo presets, stereo AU/drift path and output fan-out within one selected output device; see [ADR-002](docs/decisions/ADR-002-stereo-mix-and-fanout.md).
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

## Adaptive drift and routing

Phase 3 implements a preallocated fractional FIR resampler with bounded occupancy control for small clock differences at equal nominal sample rates. Routing has physical input rows × Mix L/R columns, plus physical output rows × Mix L/R columns (after processing). Input meters show the trimmed stereo mix, not each raw physical channel. Commanded correction, rebuffer events, discarded frames and physical output full-scale counts appear in Diagnostics. **Copy status** in the popover/Diagnostics copies build, route, permission, effects and engine counters as plain text without audio/plugin state.

The menu waveform is grey when idle, green only for confirmed fresh local callbacks and buffers, amber while starting/rebuffering or after glitches, and red for action-required faults. Text and accessibility labels accompany colour. Green does not verify upstream audio or downstream reception. Visual colour acceptance, filter quality, clock simulations and sustained hardware operation remain unverified. See [routing extension results](docs/stereo-routing-results.md) and [earlier Phase 3 results](docs/phase-3-results.md).
