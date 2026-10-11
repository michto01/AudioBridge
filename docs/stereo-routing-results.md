# N×2 mix, stereo fan-out and status UX — 2026-10-11

Approved in [ADR-002](decisions/ADR-002-stereo-mix-and-fanout.md), superseding the old two-input-lane scope. Version 0.3.1/build 10. No phase acceptance gate is claimed passed; test execution and live audio remain deferred.

## Implemented

- One input UID's physical channels mix into stereo before the AU helper: physical inputs → N×2 mix → linked input trim → stereo AU effects/dry bypass → adaptive FIR drift → linked output gain → physical fan-out on one output UID.
- Native Float32 stream addressing supports multiple consistent interleaved/planar streams, preserving HAL stream order and actual physical starting indices. Buffer topology, frame lengths, representation and device rate are validated; overlapping/reordered/unknown/inconsistent layouts fail explicitly. Maximum 4096 physical channels/direction and 4096-frame current device buffers are safety bounds, not measured performance promises. Integer formats, unequal nominal rates and same-device duplex remain unsupported. Aggregate subdevice clocks/drift configuration are managed by macOS/operator and need separate acceptance; no hidden aggregate is created.
- Version-2 route saves UID and physical patches together. V1 lanes and the saved 2×2 coefficients migrate, combining duplicated input contributions and retaining explicit duplicated output L+R sums. Original route data is backed up once; old matrix data is retained. Corrupt/future data blocks editing/Start without overwriting it. Coefficients support 0–2 to retain legacy combined duplicate gains; default connected gain is 1. Moving mixing ahead of non-linear effects changes processing semantics and requires listening acceptance.
- Preallocated C addressing, targets, candidate snapshots and per-channel ramps. Separate input/output callback-owned states; lifecycle publishes coefficients with sequentially consistent integer atomics and bounded version checks. Partial snapshots are ignored until the next callback, without spinning. Each direction is coherent, not synchronized across independently clocked callbacks. New physical topology requires Stop; no callback resource replacement. Routing storage is freed only after callback detach succeeds; failed detach retains it.
- N×2 Routing grid with named input endpoint, physical rows, Mix L/R columns and explicit Mono/Stereo presets; click toggles patches and right-click opens gain slider/exact entry. Output grid maps each physical channel to L, R or Off; multiple channels receive identical side copies. Explicit row context menu selects L+R mono sum. Live patches ramp over 20 ms. No hidden normalization/limiter; headroom warning for excessive sums. Device names remain visible; missing saved channels remain actionable without fallback. Selecting a different UID clears only its direction's patches.
- Mix L/R meters show trimmed stereo before effects; Out L/R meters show stereo after gain. Raw routed physical-input full-scale counts are distinct from stereo mix clipping. Physical output peak/full-scale counters cover mono summation/copies; output meter bars remain stereo bus measurements, not downstream reception.
- Menu waveform uses an original/non-template 18-point NSImage: grey idle, green fresh local callbacks with primed buffered output, amber startup/rebuffering/degraded, red action required. Glitches latch degraded for the run; silence does not trigger failure. Popover/settings text, accessibility label and tooltip accompany colour. No fake recovering state is shown: recovery is not implemented.
- Copy status in menu/Diagnostics copies build, timestamp, permission, device names/UIDs, matrix/fan-out, effect names/enable state and current or last-fault engine counters. No audio or plugin state is included. Existing JSON device-facts export remains available.

## Reported editor/timeout issue

User currently uses Analog Obsession and Everclean. Earlier TDR Nova crash reports establish a generic formatter crash path, now removed; they do not diagnose the current effects. Native-view loading no longer transiently renders generic controls. See [crash investigation](au-editor-crash-results.md). Current plugin failure remains unresolved pending the new Copy status report/exact effect identity and later runtime acceptance.

Engine fault reporting now preserves AU failures rather than overwriting them with startup/device checks. Startup timeout identifies missing input/output callbacks or processed buffer with captured/processed/queued counts. No permission reset, device substitution or claimed hardware repair.

## Actual evidence

`make doctor` passed: Xcode developer path, Swift 6.4 arm64 and macOS 27 SDK; deployment remains macOS 14+. Initial routing build passed (3.70 seconds); status integration passed (4.18 seconds). Copy status initially failed Swift type inference on optional rate/buffer formatting; explicit locals corrected it, and rebuild passed (3.08 seconds). `make DIST_DIR=/tmp/AudioBridge-phase2 app` passed (build 1.63 seconds and plist lint). Final `make DIST_DIR=/tmp/AudioBridge-phase2 sign` passed (build 2.38 seconds, packaging and app/helper ad-hoc signatures). `make DIST_DIR=/tmp/AudioBridge-phase2 verify` passed after the final rebuild: identifier `cz.bytelab.audiobridge`, binary `AudioBridge`, minimum macOS 14.0, menu-bar mode, 0.3.1/build 10, `AudioBridge.icns`, embedded executable Info.plist byte-identical to bundle, valid helper/deep app signatures (arm64). `git diff --check` passed. Local `/tmp` output preserves the File Provider signing workaround; runtime on macOS 14/Intel, privacy-list icon and stable deployment/TCC identity remain unverified.

`StereoRoutingTests.swift` is written but **not compiled or run**: summation/headroom, invalid/duplicate patches, legacy backup/duplicate migration, missing channels, multi-stream addresses, C physical mix/fan-out/Off/mono and status classification. Existing tests also remain deferred. No app launch, HAL start, buffer write, plugin execution, screenshot or soak/audio-quality check by automation.

SDK source inspection: macOS 27 `AudioHardware.h` stream-configuration property describes the IOProc buffer topology; `AudioHardwareBase.h` starting-channel property defines device elements. Output callbacks receive zero-filled storage, with null pointers possible for disabled streams; this implementation rejects null/ambiguous active topology rather than guessing. References: [Apple AudioBufferList](https://developer.apple.com/documentation/coreaudiotypes/audiobufferlist), [Apple AudioDeviceIOProc](https://developer.apple.com/documentation/coreaudio/audiodeviceioproc). Source audit covers ownership/bounded processing, not runtime/sanitizer evidence.

## Review and pending gate

Quit the older instance and open the new bundle. Review Audio devices, then Routing patches/presets. Confirm migrated route and levels, stereo lane isolation, multiple input sums, live ramping and duplicated output pairs. Review native plugin editors and Copy status on failure. Validate actual Aggregate Device addressing/subdevice clocks, CPU/memory, low-buffer scheduling, latency, colour appearance/VoiceOver, coherent update stress and sustained drift. High channel counts have not been benchmarked.

Stop for review before Phase 4 supervisor/recovery/login. Unattended use, automatic reconfiguration/recovery, stable signing/install/TCC identity, wider PCM support and long-duration hardware gates remain outstanding.

## Changed files

- Contract: `AGENTS.md`, `README.md`, `docs/decisions/ADR-001-universal-core-audio.md`, new ADR-002, `overview.md`, `architecture.md`, `design.md`, `device-compatibility.md`, `plan.md`, `testing.md` and this results document.
- Routing/persistence: `AudioBridgeCore/RouteSelection.swift`, new `StereoRouting.swift`, `AudioBridgeEngine/Phase2Plan.swift`, `AudioBridgeEngine.swift`, `AudioBridgeRealtime.c`/header and new C `StereoRouting.c`/header.
- UI/status: `AudioBridge/AppModel.swift`, `AudioBridgeApp.swift`, `AudioIndicators.swift`, `MatrixSettings.swift`, new `MenuStatusIcon.swift` and core `RoutingActivity.swift`.
- Acceptance sources: new `StereoRoutingTests.swift` (unrun).
- Bundle: `Resources/Info.plist`, `scripts/verify-app.sh`.
- Separate crash fix: `AudioBridgeAUWorker/Editor.swift` and `docs/au-editor-crash-results.md`.

Commits are scoped to the accepted ADR/plan, the separately evidenced editor formatter fix, and this routing/status implementation. No Phase 4 supervisor/login implementation was started.
