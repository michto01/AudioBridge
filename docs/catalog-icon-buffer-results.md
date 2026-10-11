# Cached effect catalog, icon identity and buffer choices

2026-10-11, version 0.2.7/build 8. User reported recurring generic microphone privacy-list icon, slow first Settings use, and requested catalog caching/background/manual scans plus common/custom buffer choices. Runtime tests remain deferred.

## Effect discovery

Previously catalog enumeration ran off the main thread, but on the same serial queue as device probes and on every launch. It could delay discovery/readiness. Enumeration now runs in a separate metadata-only helper on a dedicated utility queue, with a spinner and count of effects found (total unknown). No plugin is instantiated by the catalog scan. First launch without a valid cache scans asynchronously; later launches use the versioned cached identities/names/timestamp without automatic scanning. Empty results are valid cached results. Rescan is explicit after installing/removing effects. Existing cache remains usable during rescans; failed/timed-out scans preserve it. Duplicate exact component identities are excluded consistently. Timeout is 120 seconds; owned helper is terminated on timeout and watches parent lifetime.

Cache is local UserDefaults JSON, validated for schema, duplicate IDs and bounds. It contains registry metadata, not audio or plugin state. A stale cache is not proof that a plugin remains installed: actual helper instantiation remains authoritative and can report failure. Saved enabled effects absent from a known catalog still require action/rescan. Device probes and settings edits no longer wait for the scan queue.

## Buffer controls

Interface and bridge fill sliders are replaced by common frame dropdowns with Custom text entry. Suggestions are 16/32/64/128/256/512/1024 and larger powers of two, filtered to the applicable range. These are **suggestions, not a driver-provided discrete capability list**. Core Audio's SDK defines `kAudioDevicePropertyBufferFrameSizeRange` as an inclusive AudioValueRange; it does not state a universal power-of-two restriction. Drivers can reject/round values. Custom supports such drivers and the software FIFO, whose startup fill need not be a power of two even though storage capacity is. The interface setter still validates the fresh explicit UID/range/writability and reports accepted readback. Nothing automatically changes hardware buffers.

## Icon scope and evidence

The existing bundle already declares `CFBundleIconFile=AudioBridge.icns` and includes a generated full icon family. The main executable now also embeds that same Info.plist using the installed linker, AppKit explicitly loads the bundle icon, and launch performs app-specific Launch Services registration on a utility queue. `make verify` extracts the executable's embedded section and compares it byte-for-byte with bundle metadata, in addition to existing signing/icon checks. No Xcode project, asset dependency, new bundle ID, TCC reset, broad cache deletion or signing-policy change.

This addresses missing executable metadata and runtime/registration ambiguity. It is **not a reproduced diagnosis or visual confirmation** of System Settings' cached microphone icon. After quitting the old app, reopen the current bundle and close/reopen System Settings. Ad-hoc identity changes and multiple older registered copies remain deployment considerations; a stable installation path is still required for later unattended release.

## Commands and deferred checks

`make build` passed (3.30 seconds). Final `make DIST_DIR=/tmp/AudioBridge-phase2 sign` rebuilt (1.77 seconds), packaged and signed successfully. `make DIST_DIR=/tmp/AudioBridge-phase2 verify` passed: `cz.bytelab.audiobridge`, 0.2.7/build 8, minimum macOS 14.0, icon file present, executable/bundle metadata byte-for-byte identical, strict helper and deep app ad-hoc signatures valid (arm64). `git diff --check` passed. Unit test source covers empty cached catalogs, round-trip timestamps, duplicate rejection and common buffer choices; these tests were not compiled or run.

No catalog helper launched, no app launched, no hardware buffer written, no microphone captured and no UI/runtime test executed. Deferred acceptance: first-run spinner while device controls stay responsive; cached relaunch without scan; manual rescan additions/removals/timeout; microphone privacy icon; common/custom choice, out-of-range input and driver-rounded readback. Remaining drift/recovery/login and hardware gates stay pending.

Primary references: [Apple buffer range](https://developer.apple.com/documentation/coreaudio/kaudiodevicepropertybufferframesizerange), [Apple CFBundleIconFile](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleiconfile).
