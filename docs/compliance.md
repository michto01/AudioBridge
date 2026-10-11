# Compliance, deployment and operational safeguards

This is an engineering checklist, not legal advice. Verify current Apple platform requirements when implementing or distributing.

## Licensing and toolchain

- Xcode is available without a paid developer subscription, subject to Apple's Xcode and SDK licence terms. SwiftPM and `xcodebuild`/`swiftc` may be invoked from the terminal.
- The application does **not** require App Store distribution or an `.xcodeproj`.
- Review licences for all third-party DSP/resampling code; record SPDX identifier, copyright notices and source provenance. Prefer Apple frameworks or permissively licensed dependencies; do not copy proprietary code.
- CI macOS runners may have usage limits and charges; do not assume free unlimited build minutes.

## Microphone / audio capture privacy

- Supply `NSMicrophoneUsageDescription` in the actual app bundle; request/check capture permission and present actionable recovery guidance.
- Device behavior and TCC requirements must be tested on the supported macOS releases, including built-in, external and virtual Core Audio devices.
- Do not transmit, record or persist audio in v1. No telemetry, cloud upload or network connection is required by the application itself.
- Avoid logging user audio samples; diagnostic logs contain technical device identifiers, status and counters only.

## Code signing and distribution

- Free **ad-hoc signing** (`codesign --sign -`) provides a code signature but **not** a trusted Developer ID identity and **not** notarization.
- GitHub ZIP distribution is possible; downloaded builds may be quarantined and blocked by Gatekeeper. Document the official macOS 'Open Anyway' path where available, and any deliberate quarantine override only for verified builds on owned devices.
- Normal frictionless Gatekeeper-trusted distribution outside the App Store generally uses Apple Developer ID signing plus notarization, which ordinarily requires Apple Developer Program membership.
- Signing after packaging changes invalidates the signature; sign the final assembled `.app`, verify it, then ZIP with `ditto` preserving metadata.
- Maintain a stable bundle ID, version/build numbers and release checksums. Reproducibility and provenance should be tracked even for ad-hoc releases.
- An Apple Developer Program fee waiver may exist for eligible organizations; do not rely on it for v1.

## Login and background operation

- `SMAppService` login registration and its packaging prerequisites must be verified with the deployed bundle, installed in a stable location (e.g. `/Applications`).
- A user-session menu-bar app does not run before login, through shutdown or across power loss. If kiosk/auto-login is used, assess the security implications separately.
- Do not use privileged helpers, persistent launch daemons or broad entitlements without demonstrated need.
- For unattended use, explicitly configure macOS power/sleep and automatic update/restart policy at the workstation level. App-level sleep prevention is not a default requirement.

## Audio safety and live-production risk

- Calibrate analog input sensitivity and output level for each deployment; a headphone jack is not necessarily a fixed-level professional line output.
- Digital matrix mixing and positive gain can clip; show peak/clipping indicators and avoid hidden gain compensation.
- When a configured device disappears, do not route unexpectedly to internal speakers or a different output.
- A software bridge is not a guaranteed fail-safe. Recommend a dedicated hardware path if interruption cannot be tolerated.
- Do not claim that 'Running' verifies upstream transport health or downstream reception; it verifies local engine status only.

## Accessibility and system integration

- Support keyboard navigation, VoiceOver, system appearance and text alternatives to status colors.
- Avoid unrequested notifications for audio silence; rate-limit notifications for technical failures.
- Include app version, licence notices, diagnostic export and clear instructions for uninstalling/disabling login item.

## Release checklist

- [ ] Bundle identifier, minimum OS and version are correct.
- [ ] `Info.plist` includes required privacy descriptions.
- [ ] App runs as real bundle and microphone permission is tested.
- [ ] `codesign --verify --deep --strict` passes.
- [ ] ZIP extraction and first launch are tested on a clean user account.
- [ ] Login item enable/disable behavior is tested.
- [ ] No unexpected network traffic or stored audio.
- [ ] Third-party licences included, if applicable.
- [ ] Known limitations and hardware requirements documented in release notes.
