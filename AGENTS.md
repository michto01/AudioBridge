# Codex agent guide — Audio Bridge

You are implementing a **native macOS 14+ SwiftUI menu-bar audio bridge**. Read `README.md`, the current contracts listed in `docs/README.md`, and the accepted ADRs before modifying code. They are the product contract. Validation history is evidence, not a behavior specification. If a requirement conflicts with actual macOS APIs or hardware evidence, surface the conflict with a recommended correction; do not silently reinterpret it.

## Non-negotiable requirements

- SwiftPM (`Package.swift`) is the canonical build system. No Xcode project unless a demonstrated platform limitation requires it and the user approves.
- `make doctor`, `make build`, `make test`, `make app`, `make run`, `make sign`, `make verify`, `make release`, `make clean` are the public workflow.
- Native SwiftUI `MenuBarExtra` and separate settings window; audio engine independent of UI lifecycle.
- Input/output selected by Core Audio UID. Never automatically substitute system defaults.
- Auto-start on login after first-time explicit configuration; manual Stop persists and overrides retries.
- N×2 input mix, stereo AU/drift processing and physical output fan-out (ADR-002), smooth gain, stereo meters, no silence notifications. Mono/stereo presets remain simple defaults.
- Independently clocked input/output require actual drift compensation; do not claim a plain FIFO solves clock drift.
- Device loss/identity/format/buffer changes and confirmed callback stalls require explicit local re-arming under ADR-003 (0.6 user amendment). Other recoverable faults retain bounded retry backoff. Permission/configuration faults require action, not retry storms.
- No audio recording, network transport or cloud service. User explicitly authorized installed third-party AU effect hosting on 2026-10-11; other extra DSP remains outside scope.

## Engineering practices

- Prefer small testable modules and explicit invariants. Audio callbacks must not block, allocate, log synchronously, call SwiftUI, await actors or free resources concurrently.
- Treat callback lifetime and memory ownership as safety-critical. Audit ARC and Swift concurrency interactions before using Swift inside real-time callbacks.
- Use real device capabilities and SDK documentation; do not invent HAL APIs, sample-rate support, latency numbers or hardware behavior.
- Make state transitions deterministic; desired state and observed state must be separate.
- Add unit tests for matrix, gain, FIFO, drift controller and supervisor. Use fake device clocks/catalogs for integration tests.
- Never assert hardware compatibility or a hardware test passed unless executed on the stated physical or virtual Core Audio devices.
- Preserve clear error diagnostics and avoid UI claiming audio health before callbacks and buffer state are confirmed.

## Execution protocol

1. Inspect repository and macOS toolchain; identify current phase in `docs/plan.md`.
2. Propose the smallest working slice and note risks.
3. Implement that slice, including tests and relevant docs.
4. Run build/tests (and bundle verification when relevant). Report **actual** command outputs and what could not be run.
5. Stop at the phase gate and summarize changed files, acceptance results, known issues and next slice.

**Current stage:** Follow `docs/plan.md` for the active review slice and open gates. Phase 0–5 implementation exists; hardware/soak acceptance is still separate. Do not treat historical stage reports or old deferred-test instructions as current execution results or authorization to expand scope.

## Important conventions

- Keep deployment scripts POSIX shell or bash compatible with stock macOS where practical.
- Use a stable bundle identifier (`cz.bytelab.audiobridge` provisional) and consistent binary/product name (`AudioBridge`).
- Ensure scripts quote paths, fail on errors, and do not overwrite unrelated app installations.
- No secret keys are required for ad-hoc signing; never add developer certificates or credentials to Git.
- When adding a dependency, explain why the Apple SDK cannot cover the requirement, its licence, and maintenance implications.

## Universal compatibility requirement

Implement a generic Core Audio PCM input-to-output bridge, not a TightAV/Dante/ATEM-specific solution. Read `docs/device-compatibility.md` and `docs/decisions/ADR-001-universal-core-audio.md`. TightAV/ATEM is only a hardware test scenario. Preserve explicit device UID and physical-channel selection.
