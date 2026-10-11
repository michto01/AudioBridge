# Phase 0 results — 2026-10-11

## Scope

Implemented SwiftPM executable `AudioBridge`, independent `AudioBridgeCore` shell-status library, one XCTest, native SwiftUI `MenuBarExtra` popover and separate Settings scene. Start is disabled. Meters are unavailable and endpoint status is unconfigured. No audio engine, HAL, device selection, channel mapping, persistence or login registration exists. No vendor-specific dependencies or external packages were added.

## Environment

Apple Silicon arm64; macOS 27.0 (26A428). `xcode-select -p` returned `/Applications/Xcode.app/Contents/Developer`. Swift 6.4 (swiftlang-6.4.0.34.1); macOS SDK 27.0. Package deployment minimum is macOS 14.0. Runtime behavior on macOS 14 and Intel is not verified.

## Command evidence

| Command | Observed result |
|---|---|
| `make doctor` | Passed; toolchain and SDK paths resolved. Sandbox emitted Xcode cache/event-stream warnings. |
| `make build` | Passed: `Build complete!`. Initial sandbox attempt failed accessing compiler caches; approved cache access allowed build. |
| `make test` | Passed: `Executed 1 test, with 0 failures`. Default SwiftPM builder; isolated temporary build path. |
| `make app` | Passed: plist `OK`; created `dist/AudioBridge.app`. |
| `make sign` | Passed on some attempts; File Provider metadata causes intermittent failures in checkout output. |
| `make verify` | Metadata confirmed; strict signature verification passed on some attempts and failed when FinderInfo reappeared. |
| `make run` | Passed on a signed attempt; `open` returned success and process observed at packaged executable path. |
| `make DIST_DIR=/tmp/AudioBridge-phase0 run` | Passed; local-storage signed bundle launched. |
| `make DIST_DIR=/tmp/AudioBridge-phase0 release` | Passed: release build, strict signature verification, ZIP and SHA-256. |

Release archive SHA-256: `537fb82f18b8b8f93c22d6f2cea45396cea6916e50ea77a5bd23375b2aa295ed` (this build only).

Signing uses a temporary local bundle then copies back and verifies. File Provider can reattach `com.apple.FinderInfo` to checkout output; use the `DIST_DIR` override outside that storage. Tests initially failed signing generated `.xctest` bundles in the checkout; temporary scratch storage resolved this without a deprecated SwiftPM builder. The installed `/usr/local/bin/shasum` has an incompatible Perl interpreter; release uses stock `/usr/bin/shasum`.

## Bundle identity

`CFBundleIdentifier=cz.bytelab.audiobridge`, executable/name `AudioBridge`, package type `APPL`, minimum system `14.0`, `LSUIElement=true`, version `0.1.0`, build `1`. Microphone usage text refers generically to explicitly selected input/output devices. Signature reports `Signature=adhoc`, `TeamIdentifier=not set`. No capture permission is requested in Phase 0.

## Acceptance gate and next prerequisites

Update 2026-10-11: user reported that the packaged UI works and authorized progression to Phase 1. This is user verification of the shell, not an automated accessibility audit or audio/hardware result.

Screen capture failed with `could not create image from display`; visible menu item, SettingsLink interaction, keyboard/VoiceOver behavior and settings close/reopen remain **not verified**. Confirm these manually from the packaged app before accepting the Phase 0 gate. Local-storage artifacts avoid the observed File Provider signing issue; the default checkout distribution path remains unreliable on this machine.

After review and Phase 0 visual acceptance, Phase 1 must probe real Core Audio PCM endpoints, stable UIDs, explicit physical channels, formats/rates/buffers and permission behavior. Gather built-in, external and virtual device facts and reconnect/UID evidence before selecting HAL APIs. Microphone TCC, SMAppService/stable installation behavior, audio clocks, routing, latency and hardware compatibility have not been tested. No Phase 1 implementation was started.
