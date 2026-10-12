# Remote controls and delivery-warning follow-up — 0.5.2 / build 25

Implemented on 2026-10-12.

## Changes

- Remote settings now have one switch per service. HTTP and OSC state changes affect only that listener. The former Start/Stop buttons and shared Apply action are removed. Remote configuration persists as fields change; cycle only the service being configured to apply edits to its listener.
- Bridge Diagnostics identifies newly counted output underruns, input overruns and format faults with the counter delta. When callback freshness is lost after healthy delivery, it identifies the input or output callback path. Copy Status includes the current warning reason and recovery timer.
- A delivery warning clears after five seconds of healthy callbacks and no new lost frames. This timer is separate from Phase 4's 20-second supervisor backoff reset. FIFO occupancy crossing a threshold is not used to declare recovery: brief occupancy changes do not prove continued callback delivery. Recenter and rebuffer bookkeeping alone remain excluded; cumulative loss counters remain visible.
- Bridge endpoint cards size to their contents. Removed the fixed 285-point card height and the invisible input-side spacer.
- Version and bundle verification expectations advance to 0.5.2/build 25.

## Checks

- `make build` with isolated SwiftPM scratch/module caches: passed.
- `make sign` with `DIST_DIR=/tmp/AudioBridge-refine`: passed, including helper and app ad-hoc signatures.
- `make verify DIST_DIR=/tmp/AudioBridge-refine`: passed. Bundle identity is `cz.bytelab.audiobridge`, version 0.5.2/build 25, minimum macOS 14.0, arm64.
- `make test` was not run. Live audio, network and visual acceptance were not run.

## Manual acceptance

- Confirm HTTP and OSC switches independently start and stop their listener and persist across app launch.
- Change each listener's settings while active, cycle its own switch, and confirm the new port/allowlist/destination is used without affecting the other service.
- Observe Diagnostics after a real frame loss and callback interruption; verify the displayed reason and five-second clean interval. Confirm recentering alone does not warn and historical counters remain cumulative.
- Confirm the Bridge device cards remain visually balanced without the former large empty area.
