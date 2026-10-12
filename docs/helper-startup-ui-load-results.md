# Helper startup recovery and UI load — 0.5.8 / build 31

## Evidence and changes

A read-only process snapshot showed the running app launched on 2026-10-12 at
14:49:26, before its app and helper executables were replaced at approximately
15:02:31. Build 30 changed the shared-memory protocol from 4 to 5. An old app
starting the newer helper is therefore a plausible explanation for the reported
preparation exit; the failure was not reproduced live, and no particular plugin
has been established as the cause.

- Packaging refuses to replace an identified running destination bundle. A
  separate versioned destination avoids changing the current app's helper.
- The app passes its transport protocol version to the helper. The helper
  reports mismatches and shared-memory open errors explicitly. Preparation exit
  diagnostics include exit/signal status and up to the last 4 KiB of startup
  stderr. Startup exit requires action rather than scheduling retries.
- Startup stderr is redirected to the null device after successful preparation;
  unattended plugin output is not collected indefinitely.
- The processing switch remains usable during preparation/recovery. Changing it
  cancels the attempt and safely restarts with the saved mode. A subsequent
  manual Stop cancels that restart. Effect rows are editable between attempts;
  opening an offline editor cancels scheduled recovery.
- Starting with processing off skips plugin loading, catalog availability
  checks, and the helper. The direct C audio bridge retains routing, gain and
  drift compensation. Enabling processing from that route restarts it to load
  plugins. Switching off a running AU route still suspends DSP with its helper
  retained; Stop then Start with processing off removes the helper too.
- Normal UI snapshots are published at approximately 5 Hz. The engine watchdog
  and loss accounting remain at 20 Hz; faults, delivery-state changes and AU
  replies bypass display throttling. Meter animation uses Canvas drawing within
  fixed bounds instead of nested geometry readers and changing mask layouts.
  Audio callbacks and drift cadence are unchanged.

## Actual acceptance results

- Release `make build` passed using `/tmp/audiobridge-build` and the temporary
  Swift module cache (12.05 seconds).
- Final release `make sign DIST_DIR=/tmp/AudioBridge-0.5.8` passed, including
  rebuild, packaging and ad-hoc signing (final build 10.35 seconds).
- `make verify DIST_DIR=/tmp/AudioBridge-0.5.8` passed: app and helper signatures,
  embedded executable metadata, bundle identifier `cz.bytelab.audiobridge`,
  executable `AudioBridge`, macOS 14 minimum, icon `AudioBridge.icns`, and
  version 0.5.8/build 31. This artifact is arm64 and ad-hoc signed.
- Tests, app launch, hardware audio, plugin/editor behavior and CPU comparisons
  were not run, honoring the deferred testing instruction. The running app was
  left untouched. The existing-destination running-bundle refusal branch was
  not exercised by packaging into the fresh versioned destination.

## Next acceptance and remaining work

Quit the old app completely before opening
`/tmp/AudioBridge-0.5.8/AudioBridge.app`. First start with effect processing off
to inspect direct-route delivery, then enable effects and inspect any precise
startup error. This is an acceptance procedure, not a claim of restored sound.

The AU worker still uses the existing polling/thread scheduling. This change
reduces display work and offers a route without that helper; it does not claim
an event-driven audio worker, measured CPU savings or proven long-run stability.
Worker scheduling refinement and Phase 5 operational acceptance remain pending.
