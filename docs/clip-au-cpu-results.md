# Clipping, COMPER UI and CPU follow-up — 2026-10-11

Version 0.3.3/build 12. Phase 3 follow-up; no Phase 4 work or acceptance claim.

## Signal-level semantics

User requests that occasional clipping be treated as normal incoming signal behavior. Inspection confirms that previous routing health already excluded input/output/raw capture full-scale counts. The previous CLIP display was confusing because it latched until Stop.

- CLIP now indicates recent full-scale samples with a one-second hold (refreshed on the existing snapshot cadence), rather than a permanent fault-looking flag. Latest full-scale peaks also light it; inactive meters hide it. Diagnostics retain cumulative counts.
- Capture text explicitly identifies historical full scale as signal level, not a routing fault. No hidden limiter, attenuation or normalization is added.
- Menu and status text share one `RoutingActivity.hasGlitches` predicate: underrun/overrun/format faults. Clip counts deliberately are not accepted by this predicate. Nonfinite samples are still invalid data; ordinary finite values at or above full scale are not a delivery failure.
- A regression test source separates a clipped `MeterLevel` from healthy delivery and checks each actual fault counter. It is written, **not compiled or run**.

## COMPER editor investigation

User reports COMPER needles still frozen after build 11's transport callback change. That change did not establish a repair. The editor still receives the rendering instance, not a duplicate. No fake compression meter is introduced.

Before this follow-up, asynchronous preparation was not isolated to the main actor, and all AVAudioUnit creation used the asynchronous factory. Setup now runs on the main actor. Components that do not require asynchronous instantiation use synchronous `AVAudioUnitEffect` creation on AppKit's thread; components advertising `AudioComponentFlags.requiresAsyncInstantiation` retain the async factory. Standalone and live editors use the same creation function. Explicit component identity is resolved before creation; missing components fail. Plugin creation remains entirely in the isolated helper. Some plugin constructors initialize GUI infrastructure; correcting this host-side threading risk is a compatibility attempt, **not a confirmed COMPER diagnosis**. Synchronous setup can temporarily block the helper's UI while loading a plugin; rendering the old chain remains on its separate queue during replacement, with existing parent timeout behavior.

Primary-source inspection: Apple's installed `AVAudioUnit.h` says the async factory completion uses an arbitrary thread/queue and components requiring async instantiation must use it. `AVAudioUnitEffect.h` supports an effect component description constructor. JUCE's [AU wrapper](https://github.com/juce-framework/JUCE/blob/master/modules/juce_audio_plugin_client/juce_audio_plugin_client_AU_1.mm) constructs GUI initialization alongside its processor; its [macOS message manager](https://github.com/juce-framework/JUCE/blob/master/modules/juce_events/native/juce_MessageManager_mac.mm) integrates with AppKit. Current JUCE sources do not establish the internals/version used by this installed COMPER. No framework code is copied or added as a dependency.

The helper's own control timer is registered in common run-loop modes to continue servicing controls during tracking. This does not rewrite the plugin's timers or synthesize needle movement. Actual compression, signal reaching the compressor, its native meter and live editor behavior still need manual acceptance.

## Avoidable CPU work

- Previously the helper read and decoded the last `command.json` ten times per second even after replying. A chain command includes base64 plugin state; reading and decoding it repeatedly is unnecessary. Now it consumes the command file once before dispatch. The parent enforces one outstanding command and waits for a reply before writing the next, so removal cannot consume a later valid command under that protocol. Removal failure returns a command error. Filesystem/JSON work stays outside all audio callbacks.
- Bypass status publishes only on a change, avoiding repeated editor SwiftUI invalidation for identical state.
- The supplied bundle is built with **release** optimization instead of debug. Makefile defaults remain unchanged; use `BUILD_CONFIGURATION=release` when rebuilding for performance comparisons. Plugin code itself is not rebuilt or optimized by the host.

No process profiling, CPU baseline or performance measurement was run. AU DSP cost, helper wakeups, low device/bridge buffers, FIR processing and UI remain possible contributors. Whole-chain bypass deliberately keeps effects rendering and therefore is not a zero-plugin-cost comparison. Compare an actually empty chain separately. Do not interpret the existence of these optimizations as a measured CPU reduction.

## Actual commands

Initial `make build` failed on the C flag spelling not imported into Swift; corrected to `AudioComponentFlags.requiresAsyncInstantiation.rawValue`. Subsequent debug build passed (2.49 seconds). Final `make BUILD_CONFIGURATION=release DIST_DIR=/tmp/AudioBridge-phase2 sign` passed: production build 15.17 seconds, package/plist lint, helper/app ad-hoc signatures. `make DIST_DIR=/tmp/AudioBridge-phase2 verify` passed: identifier `cz.bytelab.audiobridge`, executable AudioBridge, macOS minimum 14.0, LSUIElement true, 0.3.3/build 12, AudioBridge.icns, embedded/bundle metadata match, valid helper/app signatures, arm64. `git diff --check` passed.

Tests, app launch, plugin execution, live audio and CPU profiling were **not run**, per the user's deferred execution instruction. Bundle remains `/tmp/AudioBridge-phase2/AudioBridge.app`; quit the old process before opening it. macOS 14/Intel runtime, TCC identity and unattended readiness remain unverified.

## Written acceptance (not executed)

1. Confirm build 12 after reopening. Occasional full-scale input must briefly show CLIP and increment Diagnostics without degrading routing colour/text when delivery counters remain zero. Silence and stopping must not trigger faults.
2. Confirm COMPER receives audible above-threshold signal at appropriate trim/threshold, then check needles and parameter changes while routing. Compare reopening its editor, stopped versus live editor, chain insertion/replacement and bypass. Record plugin version and whether other native effect meters animate if still frozen.
3. Compare AudioBridge and AudioBridgeAUWorker CPU separately, same route/buffers and interval, settings closed/open, editor closed/open, empty chain versus SSQ/EverClean/COMPER. Record percentages, frame/callback and counter growth. Dry bypass still incurs plugin DSP. Compare release versus the earlier debug baseline without running both routing copies together.
4. Exercise successive live commands and saved state after replacement, editor close, remove/re-add, and app relaunch; confirm commands aren't replayed or lost. Stress setup/teardown and native UI thread affinity before claiming compatibility.

Changed: app meter/status UI, core health predicate, helper setup/editor/polling, deferred test source, README, bundle version/verification and this results document. Stop before Phase 4; COMPER feedback and CPU acceptance remain pending.
