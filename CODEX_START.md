# Initial Codex prompt

Read `README.md`, `AGENTS.md` and every file under `docs/` in full. This is a macOS-only SwiftUI/Core Audio utility for unattended live-streaming audio bridging. Respect all locked design decisions and the phase gates.

**Implement Phase 0 only** from `docs/plan.md`: create a Swift Package Manager macOS 14+ executable target named `AudioBridge`, a native SwiftUI menu-bar app shell with a separate settings window, a minimal test target, and complete the existing `Makefile`/`scripts/package-app.sh` packaging flow. Do not create an Xcode project. Do not implement audio HAL or fake a working audio signal. Label all UI audio status as unconfigured/not yet implemented until real hardware functionality exists.

Check installed Apple SDK/toolchain; run `make doctor`, `make build`, `make test`, `make app`, `make sign`, `make verify`, and `make run` when possible. Fix actual failures. Confirm `Info.plist` and bundle identity. Report files changed, command results, unresolved macOS requirements and next-phase prerequisites. Do not claim tests were run if they were not. Then stop for review before Phase 1.

## Universal compatibility requirement

Implement a generic Core Audio PCM input-to-output bridge, not a TightAV/Dante/ATEM-specific solution. Read `docs/device-compatibility.md` and `docs/decisions/ADR-001-universal-core-audio.md`. TightAV/ATEM is only a hardware test scenario. Preserve explicit device UID and physical-channel selection.
