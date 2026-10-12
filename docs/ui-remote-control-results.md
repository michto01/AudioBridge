# Playback UI and remote control

Version 0.5.0/build 20. Implemented 2026-10-12. The user selected an exact source-IP allowlist for OSC commands and bearer-token authentication for HTTP.

## Changes

- Playback now uses a wider settings window with an input/output device card pair, device-class icons, a route arrow, colored textual status, meters and linked gain controls together. This follows the supplied product mockup while retaining the existing settings tabs.
- Meter bar motion animates on each sampled peak update: fast attack and slower release. Numeric dBFS, clipping indication and inactive state continue to use actual engine snapshots; the animation affects only the display.
- Added an opt-in HTTP JSON API and OSC/UDP listener/reporter using Apple's Network and Security frameworks. No third-party Swift package was introduced.
- HTTP status/control uses a random token stored in Keychain. OSC commands require a user-entered exact source-IP allowlist. Status and stereo meter peaks report once per second to a configured Companion IP/port.
- Remote commands can Start, Stop, change input/output gain and set whole-chain bypass. Device UID selection and physical patches are not remotely writable.
- Added `NSLocalNetworkUsageDescription`; bundle verification now requires it. Remote listeners are off by default.

## Local checks

- `make build`: passed after correcting device fact property names and remote HTTP parser diagnostics.
- `make BUILD_CONFIGURATION=release DIST_DIR=/tmp/AudioBridge-0.5 sign`: passed; optimized build completed in 13.38 seconds, app assembled and helper/app ad-hoc signatures verified.
- `make DIST_DIR=/tmp/AudioBridge-0.5 verify`: passed; bundle ID `cz.bytelab.audiobridge`, executable AudioBridge, macOS 14.0 minimum, version 0.5.0/build 20, icon, microphone/local-network usage descriptions, embedded plist match and helper/app signatures verified.
- `git diff --check`: passed. App was not launched; no HTTP/OSC packets or tests were run.
- Automated tests were not run. The user had deferred test execution until later manual stage checks.

## Pending acceptance

- Inspect the settings window on screen against the reference, including light/dark mode and small window behavior.
- Confirm meter response/hold looks natural with actual signal and does not obscure brief peaks.
- From Companion, test status poll and the five OSC control commands, verify statuses/gains/bypass update; verify denied source IPs are ignored.
- Test valid and invalid HTTP tokens, malformed/oversize requests, unavailable Start, and gain boundary values.
- Approve macOS Local Network access when prompted; verify firewall behavior and actual network interface addresses.
- Verify the Keychain token survives relaunch and regeneration invalidates the former token.
- HTTP currently uses plain TCP without TLS; token traffic is exposed to a network observer. OSC has no cryptographic authentication. Keep services on a trusted LAN, avoid port forwarding, and leave them disabled when not needed.
- No audio, plugin state, device UIDs or recordings are exposed by the remote API. Companion integration, firewall/privacy prompts and all real network traffic are untested.
