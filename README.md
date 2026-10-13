# Audio Bridge — specification and Codex handoff

Status: **0.7.0/build 39 refreshes the menu popover with a prominent app header, matched input/output cards, signal-flow link and a single Settings action. Device selection stays in Settings; current meters and audio behavior are preserved. See [menu redesign](docs/menu-0.7-results.md). The preceding 0.6.5 audio audit fixes passed 72 tests; the timed 12-hour and broader hardware gates remain open.**

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

The app has a native menu-bar popover and separate settings scene. It discovers real Core Audio devices, persists explicitly selected UIDs and physical channels, observes device/property changes and provides a microphone permission button. Phase 2 adds manual Start/Stop for experimental routing; Phase 3 adds adaptive drift resampling, an N×2 input grid, smooth trim/gain, meters and stereo physical output fan-out. Phase 4 adds bounded recovery and explicit launch/login controls. Arbitrary nominal-rate conversion remains unimplemented. Drift, recovery and audio-quality acceptance remain pending. Closing settings does not quit the app; use Quit in the popover.

Run the current build with `make DIST_DIR=/tmp/AudioBridge-phase2 run`. Quit an older running copy first. In Settings → Audio, choose both endpoints explicitly. In Routing, press Mono → L + R or Stereo for a simple input preset, then Stereo for the first output pair, or patch physical channels directly in the grids. Mono outputs can take L or R, or an explicitly chosen L+R sum. Right-click an input cell for gain (0–2, 1 = unity), and an output row for mono sum. One side can feed multiple destinations; L/R effects and drift are processed only once. Mixing/gain changes can run live; changing device or buffer topology requires Stop.

This path requires two separate device UIDs with matching current sample rates and native packed Float32 PCM streams. Supported interleaved/planar multi-stream layouts are validated against reported IO buffers; ambiguous, disabled, integer or other unsupported layouts fail with a reason. Aggregate Devices configured by the operator are eligible but remain best effort and require hardware validation. Same-device duplex and independently opened multiple output devices are not implemented. Missing endpoints/channels are retained without fallback. Version-1 lane/matrix preferences migrate to the version-2 route with an original-payload backup. Mixing now occurs before effects, so non-linear plugins can sound different from the old post-effect matrix; review the sound after migration.

The FIFO alone does **not** compensate independently clocked devices; this build adds bounded adaptive FIR resampling. Its tuning, filtering and sustained clock behaviour remain unverified. This build is not yet validated for unattended streaming. Launch capture is off by default. General → Resume routing when the app launches is explicit opt-in and also requires saved desired routing from Start; manual Stop overrides it. Every recovery attempt resolves the same UIDs from a fresh catalog and validates physical patches/formats; no default substitution. Settings show human-readable names; technical UIDs remain in Diagnostics.

Device loss, identity/format/buffer changes and confirmed callback stalls now stop routing and **require explicit local re-arming**. Reconnect, remote Start and relaunch cannot clear the persisted latch. The Bridge button explains and confirms re-arming before sound resumes. General → Device error notifications requests macOS notification permission explicitly; the red in-app fault remains visible even if notifications are disabled or denied. This user-approved safety change supersedes automatic device reconnect in [ADR-003](docs/decisions/ADR-003-reliability-and-operator-setup.md). Other recoverable helper/preparation failures retain bounded backoff (1, 2, 4, 8, 16, 30 seconds). Permission/configuration/render faults require action; unconfirmed callback teardown requires restart. A driver Stop error with confirmed callback detach does not itself require restart.

General → Start at login uses Apple's SMAppService for the main app, independently of audio resume. Install the signed bundle in `/Applications` or your user's Applications folder before enabling; temporary build locations are unsuitable. Registration occurs only when you use the toggle; no automatic installation or registration. Approval/status/errors are visible, with a System Settings link when needed. Actual registration, login launch, permissions after rebuild and recovery still need manual acceptance. Ad-hoc signing is not notarization or a stable Developer ID identity.

For a built-in microphone-to-speakers check, choose the microphone and speakers in Audio, then press **Mono → L + R** and output **Stereo** in Routing (review the displayed physical channel indices). Keep the Mac's speaker volume low to avoid acoustic feedback. Start becomes available only after the complete route and permission are valid; a reason is shown otherwise. Meters are inactive before Start and show measured local buffer peaks afterward. See [audio settings and deferred checks](docs/audio-settings-results.md).

Audio → **Simple** offers a shared rate and buffer request for both explicit devices; **Apply device settings** performs driver writes while stopped. Common rates are filtered by both device reports. The drivers must confirm the requested rate and buffer before Simple Start is allowed. Partial failures are reported and are not hidden by output substitution. Simple uses Balanced FIFO sizing and automatic AU blocks. **Expert** preserves independent device buffers, a custom FIFO reserve and optional 16–1024-frame power-of-two AU blocks (no larger than the reserve). Automatic AU blocks remain 16–256 frames. Existing configured routes migrate to Expert; new configurations start Simple. Expert device drafts start from the current driver value, with 64 frames only as a fallback. Switching modes alone never writes hardware; saved Expert FIFO/AU choices remain intact. General → Language switches the operator interface between English and Czech. Device/plugin names, third-party plugin interfaces and raw driver errors retain their supplied language; Copy Status and remote contracts remain English.

Settings → Audio → Device access can request Core Audio hog mode for both explicitly selected devices while routing. The request is off by default. If either selected device is owned by another process or does not expose writable hog mode, Start fails with the device identified; partial acquisition is rolled back. The request is released after callbacks detach on Stop. This is a driver-mediated ownership request, not a system-wide guarantee. See [exclusive access results](docs/exclusive-access-results.md).

The Bridge output card has a separate **Device volume** control for the selected output's writable Core Audio master-volume property. It is distinct from Audio Bridge's digital output gain, may change volume for other clients, and is disabled with an explanation when the output driver does not expose a writable master control. Device values may quantize to supported hardware steps. See [device volume results](docs/device-volume-results.md).

Input trim and output gain can change live, apply to both lanes, and persist; their −60 to +12 dB controls ramp over 20 ms. Input meters show samples after trim, while a separate warning tracks raw capture reaching full scale. Digital attenuation cannot repair capture clipping. See [buffer and gain follow-up](docs/buffer-gain-results.md).

Full-scale audio is a signal-level indication, not a routing glitch. Meter **CLIP** holds briefly; cumulative counts remain in Diagnostics. Delivery faults (underrun, overrun, invalid format/nonfinite data) affect routing status independently. For CPU comparisons use an optimized bundle: `make BUILD_CONFIGURATION=release DIST_DIR=/tmp/AudioBridge-phase2 sign`, then `make DIST_DIR=/tmp/AudioBridge-phase2 verify`. Quit the old process before opening the new bundle. Build 12 uses this release configuration; no measured CPU improvement or COMPER needle repair is claimed. See [clipping, AU UI and CPU follow-up](docs/clip-au-cpu-results.md).

Development builds are ad-hoc signed. This build's designated requirement is its code hash, which changes on rebuild; this may invalidate an earlier microphone grant. The user reported routing working after toggling AudioBridge's microphone permission. If a rebuilt app's grant appears stale, quit the app, toggle its entry in System Settings and reopen the same bundle. No permission reset or weaker signing requirement is applied automatically.

Settings → Diagnostics shows actual stream formats and property errors and exports a JSON report including permission context. `make probe` runs the same read-only catalog as a CLI. CLI microphone authorization is **not evidence of packaged-app authorization**; request/check permission in Settings → Audio. Raw local diagnostic snapshots under `.diagnostics/` are ignored by Git and contain no audio samples.

Artifacts normally go to `dist/AudioBridge.app`. `make run` packages and ad-hoc signs, refreshes that bundle's Launch Services registration (including its icon), then opens it. Quit an older running copy first: opening another build does not replace the running process. If System Settings has cached an old icon, close and reopen it after launching the current bundle. `make release` builds the release configuration, signs, verifies and creates a ZIP with a SHA-256 checksum file. Ad-hoc signing does not provide Developer ID trust or notarization. GitHub Actions build/test runs on macOS 14 for pull requests and pushes to `main`; pushing a `vX.Y.Z` tag matching the bundle version publishes the ZIP and checksum as a GitHub Release. `make clean` clears SwiftPM build products and retains distribution artifacts for review.

File Provider storage on the development machine attaches Finder metadata that can invalidate bundle signing. Use local output storage for reliable packaging, for example `make DIST_DIR=/tmp/AudioBridge-phase2 run` and `make DIST_DIR=/tmp/AudioBridge-phase2 release`. Temporary artifacts are disposable, not a stable deployment path. Tests automatically use isolated temporary build storage and remove it afterward. Packaging refuses to replace a bundle with another identifier or a symlink. There are no third-party dependencies or extra entitlements. Packaging converts `Resources/AudioBridge.png` into a complete `AudioBridge.icns` family using Apple's `sips` and `iconutil` and includes it in the app bundle.

See [Phase 0 results](docs/phase-0-results.md), [Phase 1 results](docs/phase-1-results.md) and [Phase 2 results and deferred checks](docs/phase-2-results.md) for actual checks and remaining acceptance steps.

## Installed Audio Unit effects

Settings → Bridge contains the single Start/Stop button, explicitly scaled device icons, equally sized endpoint cards, input trim/output gain sliders beside their meters, and a delay estimate. Settings groups use bold headings with explanations behind `(i)` popovers. Diagnostics and Copy Status present technical values in distinct sections. See [visual correction results](docs/ui-visual-correction-results.md). The menu popover retains the two-state control and output-device volume, but not digital trim sliders or Copy Status. Settings → Audio configures devices and interface-buffer drafts; permissions are in General. Settings → Effects lists installed AU effects. Add, reorder, enable or remove up to eight slots while routing; the helper prepares a replacement chain alongside the current one and switches between processing blocks. Close an editor before changing the chain. Preparation failures stop routing, preserving explicit device selection. Switching resets plugin histories/tails and is not guaranteed click-free or latency-matched.

Playback delay adds reported input/output device and routed-stream latency, safety offsets, callback buffer allowances, observed capture/processed queues and in-flight AU block, FIR lookahead and declared AU signal latency. Missing values remain Unknown; startup fill and processing wall time are not added twice. The displayed chain allowance is an **estimate**, not measured physical end-to-end latency. AU last/mean/max block wall time is separate performance telemetry, including scheduling/preemption; queue min/max is sampled while primed. Copy status includes the components. Expert interface requests begin with the current reported value (64-frame fallback), with no automatic hardware write. See [Playback/delay results](docs/playback-delay-results.md).

Build 14 separates the **bridge + callback buffer estimate**, **device-reported delay** and **combined accounting estimate**. Small hardware buffers do not eliminate a device's internally reported stream delay. In the user's screenshot, bridge/callback buffering is 4.54 ms and device reports add 48.90 ms; the 53.44 ms combined estimate is arithmetically consistent but is not verified physical transit. See [delay interpretation and warning recovery](docs/delay-health-results.md).

The effect catalog is cached locally. First launch without a valid cache scans metadata in a separate background helper, showing a spinner and found count; device discovery uses its own queue. Later launches use the saved list immediately. **Rescan** refreshes it manually after installing/removing plugins and keeps existing results usable meanwhile. A stale cache cannot guarantee plugin availability; loading the actual unit still validates it.

Adding an effect opens its editor; **Edit** reopens it. Editor windows fit the plugin's advertised size, clamped to the display, with scrolling for oversized legacy views. During routing the editor controls the **same plugin instance that renders audio**, so parameter changes apply immediately without app/HAL restart. **Close and save** persists its state; the live editor has no Cancel rollback. Close it before Stop if the latest settings must be saved. When stopped, editing uses a separate instance with Save/Cancel for the next Start. **Bypass chain** outputs dry audio while keeping effects processing and editable. Plugin windows display **Chain bypassed**; trim/gain stay active. Enable chain restores processed output. This explicit bypass is saved separately from individual slot enable flags and retains plugin CPU cost.

The chain order is physical input matrix → input trim → enabled AU effects → adaptive drift resampler → output gain → physical output fan-out. Effects must accept stereo planar Float32 at the route's sample rate; optional additional buses are disabled, with no sidechain or MIDI routing. Startup fill can be as small as 16/32 frames when both current device buffers permit it. Automatic AU processing uses 16–256-frame blocks; Expert can request 16–1024 frames within the FIFO reserve. Zero is unsupported. Smaller values are experimental and can underrun; presets remain conservative. Change interface buffers first, then bridge fill while stopped. Missing plugins, preparation timeout, helper exit, render error or stalled helper stop routing without silently substituting or bypassing an effect. Plugin latency is reported separately, not claimed as measured end-to-end latency. VST hosting is not included.

Plugins run in a separate signed helper using shared-memory audio queues, outside HAL callbacks. The helper remains present even for an empty chain to allow live insertion. This isolates process crashes, not security privileges: third-party code retains the user's access and may have its own licensing or network behavior. Compatibility and performance remain untested. Drift validation, automatic recovery, login startup and long-duration validation are still required for unattended operation. See [AU hosting results](docs/au-hosting-results.md), [live editor follow-up](docs/live-au-results.md) and [editable bypass/small buffers](docs/bypass-small-buffer-results.md).

## Decisions already locked

- Launch at login; automatically route when configured devices are present.
- Bind input and output by stable Core Audio device UID; **never silently fall back** to another device.
- N×2 input mix with mono/stereo presets, stereo AU/drift path and output fan-out within one selected output device; see [ADR-002](docs/decisions/ADR-002-stereo-mix-and-fanout.md).
- Silence is metered but **never generates silence notifications**.
- Menu-bar popover for monitoring; separate settings window.
- Device loss/change requires explicit re-arming (ADR-003); other recoverable failures use capped retry backoff, and deliberate Stop always wins.
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

Phase 3 implements a preallocated fractional FIR resampler with bounded occupancy control for small clock differences at equal nominal sample rates. Routing has physical input rows × Mix L/R columns, plus physical output rows × Mix L/R columns (after processing). Input meters show the trimmed stereo mix, not each raw physical channel. Commanded correction, rebuffer events, discarded frames and physical output full-scale counts appear in Diagnostics. **Copy status** in Diagnostics copies build, route, permission, effects and engine counters as plain text without audio/plugin state.

The menu waveform is grey when idle, green only for confirmed fresh local callbacks and buffers, amber while starting/rebuffering or after recent delivery loss (clears after five healthy seconds; historical counters remain), and red for action-required faults. Diagnostics identifies the current warning reason. Queue recentering and rebuffer bookkeeping alone do not trigger it. Text and accessibility labels accompany colour. Green does not verify upstream audio or downstream reception. Visual colour acceptance, filter quality, clock simulations and sustained hardware operation remain unverified. See [routing extension results](docs/stereo-routing-results.md) and [earlier Phase 3 results](docs/phase-3-results.md).

Settings → Remote starts/stops HTTP and OSC independently using one switch per service; each switch saves its own state. HTTP defaults to port 8765 and requires a random bearer token stored in Keychain. `GET /api/v1/status` reports route names, status, gains, bypass state and four linear peak values. `POST /api/v1/control` accepts `{"command":"start"}`, `stop`, `inputGain`/`outputGain` with `decibels`, or `chainBypass` with `bypassed`. OSC defaults to UDP 9000. Add the Companion sender IP to the exact-address allowlist for commands; configure Companion's address and feedback port to receive one-second status reports. To apply edits to an active service, switch that service off and on. See [OSC/HTTP protocol details](docs/remote-control.md). Both services are off by default. HTTP is unencrypted; OSC has no built-in authentication. Use only on a trusted LAN and configure macOS Local Network access/firewall accordingly. No audio is transmitted. No third-party package was added; macOS Network and Security frameworks provide the required services.
