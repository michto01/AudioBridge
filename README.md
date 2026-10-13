<p align="center">
  <img src="Resources/AudioBridge.png" width="112" height="112" alt="Audio Bridge icon">
</p>

# Audio Bridge

**Native macOS audio routing for live production.**

Audio Bridge connects an explicitly selected Core Audio input to an explicitly selected output. Mix physical inputs into stereo, add installed Audio Unit effects, and patch the stereo mix to physical output channels—all from a menu-bar app with a separate settings window.

**macOS 14+ · SwiftUI · Core Audio · Swift Package Manager · English / Czech**

## Features

- Device selection by persistent UID, with no automatic substitution of system defaults.
- Mono/stereo presets and an expandable N×2 input matrix with stereo output fan-out.
- Adaptive drift compensation between independently clocked devices.
- Smooth input trim, device output volume or digital gain fallback, stereo meters and clipping indicators.
- Installed AU effect chains with searchable selection, editors, live changes, bypass and DSP suspension.
- Simple shared device settings or Expert control of interface buffers, FIFO reserve and AU block size.
- Explicit device-loss re-arming, persisted manual Stop, optional login launch and resume.
- Optional HTTP/OSC status and control for tools such as Bitfocus Companion.

No audio recording, network audio transport or cloud service is built into the app.

## Project status

**0.7.1 / build 40 is a prerelease.** Local release packaging/signature checks pass on Apple Silicon. The last recorded automated audio/control suite passed **72 tests on 0.6.5**; subsequent menu and shell changes were not followed by a new suite run. A documented 12-hour hardware run, broader driver/plugin compatibility and clean-install acceptance remain open. See [validation history](docs/history/validation.md) and [acceptance gates](docs/testing.md).

## Requirements

- macOS 14 or later; Apple Silicon is the primary development platform. Intel and macOS 14 runtime acceptance are not yet established.
- Xcode with an Apple macOS SDK and Swift 5.9 or newer for building. Recent local checks used Swift 6.4.
- Two distinct Core Audio device UIDs with matching current sample rates and supported native packed Float32 PCM streams.

Built-in, USB, Thunderbolt and virtual devices are considered by their capabilities, not brand. Aggregate, Bluetooth and AirPlay devices require individual validation. Same-device duplex, arbitrary nominal-rate conversion, integer PCM and independently opened multiple output devices are not implemented. See [device compatibility](docs/device-compatibility.md).

## Build and run

From the repository directory:

```sh
make doctor
make BUILD_CONFIGURATION=release sign
make verify
make BUILD_CONFIGURATION=release run
```

The app is created at `dist/AudioBridge.app`. Quit an older running copy before rebuilding that bundle or opening another version. `make run` builds, packages and signs before launching; packaging refuses to overwrite a running destination.

For automated checks and a release ZIP:

```sh
make test
make release
```

`make release` creates `dist/AudioBridge-macOS.zip` and its SHA-256 checksum. Other public targets are `build`, `app`, `probe` and `clean`. SwiftPM is the canonical build system; there is no Xcode project or external package dependency. See the [build guide](docs/build.md) for command details and GitHub publishing.

### iCloud / File Provider storage

Finder metadata can invalidate signatures when the checkout is in File Provider storage, even beneath a `.nosync` folder. If signing or verification reports “resource fork, Finder information, or similar detritus,” use a local output folder:

```sh
make BUILD_CONFIGURATION=release DIST_DIR=/tmp/AudioBridge-local run
make DIST_DIR=/tmp/AudioBridge-local verify
```

Temporary output is for development, not a stable installation. No iCloud settings are changed by the build. See [troubleshooting](docs/build.md#file-provider-and-signatures).

## Usage

1. Open **Settings → Audio**, explicitly select input and output, and confirm matching sample rates. In Simple mode, apply shared device settings while stopped.
2. In **General**, grant microphone permission when requested. Device-error notification permission is optional.
3. In **Routing**, choose Mono → L + R or Stereo, then review the physical output patches. Keep monitoring volume low when connecting a microphone to speakers.
4. Optionally add and edit installed Audio Units in **Effects**.
5. Return to **Bridge** and press **Start**. The menu popover shows the selected devices, measured stereo levels, output-device volume and runtime.

| Menu status | Meaning |
|---|---|
| Grey | Stopped or unconfigured |
| Green | Confirmed fresh local callbacks and primed delivery |
| Amber | Starting or a recent delivery warning |
| Red | Action required |

Green confirms local delivery, not audible reception downstream. **Stop** persists and suppresses retries/resume. Device loss or route changes require explicit local **Re-arm**; remote Start cannot clear that latch. Closing Settings does not stop the engine.

The menu is for monitoring; device selection and digital trim stay in Settings. **Diagnostics → Copy Status** provides a technical report without audio or plugin state. See the [interface guide](docs/design.md) for effects, buffers, meters and delay estimates.

### Remote control

Enable HTTP and OSC independently in **Settings → Remote**. HTTP uses a Keychain bearer token; OSC commands require an exact source-IP allowlist. Both default off. These services carry status/control only, use no TLS/OSC cryptographic authentication, and belong on a trusted production LAN. Full endpoints and Companion setup are in the [remote protocol reference](docs/remote-control.md).

### Login and permissions

Install a verified bundle in `/Applications` or your user Applications folder before enabling **Start at login**. Login launch and **Resume routing when the app launches** are separate opt-ins. Development builds are ad-hoc signed, not Developer ID signed or notarized; rebuilding can invalidate microphone authorization. See [deployment and privacy](docs/compliance.md).

## Documentation

- [Documentation index](docs/README.md)
- [Product contract](docs/overview.md) and [architecture](docs/architecture.md)
- [Architecture decisions](docs/decisions/README.md)
- [Roadmap and review gates](docs/plan.md)
- [Testing and hardware acceptance](docs/testing.md)

## Contributing

Bug reports, documentation improvements and focused pull requests are welcome. For audio issues, include the version/build, explicit device setup, buffers/effects and a sanitized Copy Status report. Never include tokens or audio recordings. Follow [CONTRIBUTING.md](CONTRIBUTING.md), especially the realtime ownership and device-safety requirements.

## License

[MIT](LICENSE). Installed Audio Units and Apple tooling remain subject to their own licenses.
