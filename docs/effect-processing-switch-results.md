# Effect processing switch — 0.5.7 / build 30

Implemented on 2026-10-12.

## Behavior

Effects has a saved Enable effect processing switch, defaulting on for existing installations. Turning it off stores a lock-free shared-memory flag. The helper samples that flag once for each block; after reading captured stereo, it writes those dry samples to the output queue and returns before deinterleaving, plugin render/pull calls or stage processing. The same direct forwarding path now applies to an empty chain.

The existing chain bypass remains separate. With processing enabled and bypass set, effects still render for live editor signal feedback while output uses dry samples. Turning processing off preserves bypass preference and loaded processors/settings. The bypass button is unavailable while processing is off and clearly says Remove bypass when set. Re-enabling processing respects that saved bypass state.

The helper process, shared queues, heartbeat, render-block timing and frame accounting continue running while processing is off. No HAL callback waits for or edits a plugin. Off does not unload plugins, bypass startup instantiation/validation, remove editor/background plugin activity or recover an already failed helper. Existing plugin crashes and faults still require the normal explicit recovery/action path. This feature avoids plugin audio rendering costs; it does not implement the previously discussed real-time worker scheduling refinement.

The flag applies at the next processing block; a block already rendering may complete and already queued wet audio can finish before dry audio arrives. No queue is flushed and no restart is required. Retained plugin DSP state and tails may produce audible transitions on re-enable; no seamless transition claim is made.

## Editor and reporting

Live editors receive processing-state changes and show a paused-signal-meter banner while off. Stopped editors receive the same saved state through a small settings indicator file. Parameters remain editable. Periodic plugin latency refresh is skipped while processing is off. Effective effect latency used for delay reporting is zero in processing-off or dry-bypass modes; cached loaded-chain latency remains available internally for re-enable. Previously queued processed audio may briefly precede the new path.

Diagnostics explicitly distinguishes enabled effect processing, rendering with dry bypass and processing off with dry forwarding. Copy Status and remote JSON expose requested and observed processing flags. AU processed/timed counts still refer to helper work and forwarded frames while off; they do not imply that plugin DSP ran. Reset diagnostic counters before comparing those modes.

The shared-memory protocol advances from version 4 to 5 and validates its new atomic flag. Both app and helper are rebuilt and bundled together. AU worker requests use an optional field so older request JSON defaults to processing enabled. Bundle metadata advances to 0.5.7/build 30.

## Checks

- Release compilation passed using `make build BUILD_CONFIGURATION=release SWIFT_BUILD_OPTIONS='--disable-sandbox --scratch-path /tmp/audiobridge-build'` with `SWIFTPM_MODULECACHE_OVERRIDE=/tmp/audiobridge-swift-module-cache`.
- Final release compilation, packaging and ad-hoc signing passed: `make sign BUILD_CONFIGURATION=release DIST_DIR=/tmp/AudioBridge-release` with the same build options.
- Bundle verification passed: `make verify DIST_DIR=/tmp/AudioBridge-release`. Version 0.5.7/build 30, bundle ID `cz.bytelab.audiobridge`, minimum macOS 14.0; app/helper signatures verified and embedded metadata matched.
- `git diff --check` passed.
- Automated tests, new-app launch, live switching, plugin/editor signal feedback, latency readback and real CPU/dropout comparisons were not run, following deferred manual acceptance. Phase 5 operational acceptance remains pending.

## Manual acceptance

With unchanged devices and buffers: reset counters and compare equal-length periods with processing on, bypass on and processing off. Verify live off/on without restarting, editing while off, saved settings after relaunch, preserved bypass after re-enable, paused editor signal meters and continuing main bridge meters. Check that processing-off reported effect latency is zero, timing/frame counters continue, and faults remain visible. A clean off run would narrow the problem to rendering/hosting work; it would not establish a particular plugin bug or a complete repair of scheduling.
