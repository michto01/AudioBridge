# AU input pull correction — 0.6.1 / build 34

## Source finding

The AU input callback required every request to equal the entire host processing block and ignored its timestamp. A unit requesting a smaller portion would receive FormatNotSupported even when all requested samples were already available. This is a hosting compatibility restriction; no supplied runtime evidence establishes that it caused the reported periodic underruns.

[Apple's AURenderPullInputBlock contract](https://developer.apple.com/documentation/audiotoolbox/aurenderpullinputblock) supplies a requested frame count and timestamp, and permits either filling the caller's buffers or returning host-owned pointers valid for the render cycle.

## Change

- Cache each stage's current block sample time before invoking its render block.
- Resolve a pull's offset from its sample timestamp, allowing smaller and repeated reads inside that block. Do not use a consuming cursor or read more live FIFO data.
- Reject nonfinite, fractional, negative or out-of-block offsets; reject oversized requests. A missing sample timestamp is accepted only for a full-block pull, whose address is unambiguous.
- Validate both stereo planar buffers and destination capacities before writing either lane. Use overlap-safe copying when a caller supplies storage; retain host-owned pointer support when it does not.
- Keep the existing queue sizes, worker scheduling, FIR and drift controller. The pull closure remains cached during setup, with no allocation, wait, logging or property query added to its audio path.

The microphone-permission/system indicator icon remains a deferred cosmetic issue at the user's request. No running bridge was restarted or device configuration changed.

## Acceptance

Actual checks on 2026-10-13:

- `make sign BUILD_CONFIGURATION=release DIST_DIR=/tmp/AudioBridge-0.6.1-final` passed, including its release build (3.47 seconds), packaging/plist lint and ad-hoc helper/app signing.
- `make verify DIST_DIR=/tmp/AudioBridge-0.6.1-final` initially rejected the old hard-coded expected version. Updated the verifier for 0.6.1/build 34 and reran successfully: bundle identifier `cz.bytelab.audiobridge`, minimum macOS 14, app icon resource, English/Czech resources, identical embedded/bundle metadata and strict signatures.
- `git diff --check` passed. No automated tests, app launch, audio/device writes, runtime plugin check, profiling or soak were run. Bundle is `/tmp/AudioBridge-0.6.1-final/AudioBridge.app`.

Automated tests and plugin/hardware execution remain deferred. Required cases: full-block pulls with and without sample time; adjacent and repeated sub-block pulls; stereo offset/stride correctness; null versus caller-owned pointers; overlapping copies; invalid channel layout and undersized second lane with no first-lane modification; nonfinite/fractional/out-of-range times and oversized frames. Plugin requests outside the current prepared block still fail explicitly; this revision does not implement arbitrary-rate/time-stretch input provisioning.

Use the 0.6 comparison procedure in [release results](release-0.6-results.md), retaining 128 input / 32 output / 128 reserve / AU 128 when supported. Copy status from a failing run must include build, queue/starvation snapshot, individual plugin timings and worker wake data before attributing losses to a plugin or scheduler. Long-run reliability and CPU improvement remain unconfirmed.
