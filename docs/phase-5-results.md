# Phase 5 — Hardening and distribution

Implementation slice started 2026-10-12 after the user asked to advance phases. No test command, app launch, AU/plugin, login registration or audio operation was performed.

## Implemented

- Added macOS 14 GitHub Actions CI for toolchain inspection, build and automated tests on pull requests and pushes to `main`.
- Added a tag-triggered release workflow. It requires the `vX.Y.Z` tag to match the app's `CFBundleShortVersionString`, then runs the existing release target and attaches the ad-hoc signed app ZIP and SHA-256 checksum to a GitHub Release.
- The repository has no Git remote configured, so the workflows could not be dispatched or observed remotely. No release was published.
- Existing `make release` already performs optimized build, package, ad-hoc signature verification, ZIP creation with `ditto` and SHA-256 generation. It remains the local release entry point.

## Local command results

- `make doctor`: passed; Xcode selected, Swift 6.4, macOS 27 SDK, arm64 host.
- `make build`: passed (3.13 seconds).
- `make DIST_DIR=/tmp/AudioBridge-phase5 release`: passed; optimized build (10.87 seconds), plist lint, app/helper ad-hoc signing, bundle verification, ZIP and checksum file.
- ZIP SHA-256: `dec23aadff319b363ab2fc1949b49f23d7143b9f9289e5a3634331d87c107715`.
- Bundle identity verified as `cz.bytelab.audiobridge`, version 0.4.0/build 19, arm64, minimum macOS 14.0, with matching embedded metadata and app icon.
- `git diff --check`: passed. Automated tests intentionally not run.

## Source audit notes

The C HAL callbacks contain no heap allocation, mutex acquisition, synchronous logging, Swift/SwiftUI calls or property queries. Routing, FIFO and resampler storage are prepared before device callbacks start. Lock-free atomic properties are checked at engine construction. Shutdown disables the engine, stops/destroys output then input IOProc registrations on the lifecycle queue, and waits for in-flight callback references before buffers can be destroyed. If registration destruction or the bounded wait fails, the engine reports teardown failure and retains callback-owned resources; Phase 4 then blocks restart and asks for an app restart.

This is a source inspection only. It does not prove the HAL's runtime callback scheduling, absence of races, memory safety under stress, or audio continuity. Thread Sanitizer and hardware lifecycle runs remain necessary.

## Not run / release gate still open

- `make test`, CI execution, Thread Sanitizer, app launch, AU hosting, login registration, hardware audio, sleep/wake, unplug/replug, permission revocation and the 12-hour soak were not run.
- CI runner availability, workflow syntax and tag release publishing have not been verified against a GitHub repository.
- The current ad-hoc signature is not Developer ID signing or notarization. The workflow will publish a ZIP only when a matching version tag is pushed to a repository with GitHub Actions and Releases enabled.
- Clean install, Gatekeeper behavior, login approval and microphone permission need a second macOS account or Mac; the current bundle is not evidence of those flows.
- User hardware acceptance from Phases 2–4 remains outstanding. Phase 5 is not complete until the hardware test matrix, callback race/sanitizer review, clean install and 12-hour operational gate have evidence recorded.
