# Mix gain, AU feedback and small-buffer review — 2026-10-11

Version 0.3.2/build 11. This is a scoped Phase 3 follow-up; Phase 4 recovery/login remains gated.

## User evidence and limits

Build 10 report: built-in microphone/speakers, 48 kHz, both device buffers 32 frames, bridge startup fill 32, SSQ → EverClean → COMPER. Input/output callbacks are fresh, but 152,322 underrun frames, 69,824 overrun frames, 4,085 rebuffers and 15,526 recentered frames show interrupted delivery. Counts are cumulative for that run; the amber status currently latches glitches until the next Start. Commanded 814 ppm is occupancy feedback, not a measured device clock difference. This report does not establish which plugin or scheduling path causes interruptions.

32 frames at 48 kHz is about 0.67 ms. A separate asynchronously scheduled AU helper needs scheduling margin. Recommend stopping, setting **bridge startup fill** to 256 or 512 and starting again, initially preserving the 32-frame hardware buffers. No setting is automatically changed. This is an experiment for later manual acceptance, not a confirmed repair or latency guarantee. Drift control cannot repair lost frames or missed processing deadlines. If counters still grow rapidly, isolate the chain and compare larger hardware buffers during manual testing.

## Changes

- Source contribution gains now have a visible slider button beside each matrix patch. Both sides remain independently adjustable live (linear 0–2; 0.5 is approximately −6 dB). This attenuates a physical source's contribution before summing/effects. Linked input trim remains after the mix and affects both sides together. No extra persisted source-gain stage or normalization is introduced.
- Gain fields keep a local draft until Return/focus loss, allowing incomplete negative dB entry. Invalid/out-of-range entries restore the current value. Sliders remain live. Copy status now includes input trim and output gain.
- Both grids/meters use Mix L/Mix R. The flow description identifies input trim, AU chain, drift and output gain between the pre-effect mix and the processed copies patched to outputs.
- Bridge fills below 256 frames display a scheduling-margin warning; drift display calls its value a command.
- Each running AU receives a host transport callback with running/stopped/fault state and actual processed-frame position from the existing atomic shared transport. No invented tempo, recording or looping context. Render timestamps use the same processed-frame timeline, including chain replacement. The mapping outlives all units; the closure captures no renderer. This supplies missing AU host context, **not proof that COMPER's needle is fixed**. Editor and DSP still share the same running instance; plugin meter behavior requires manual inspection. Standalone stopped editors do not render audio.

SDK inspection: `AUAudioUnit.h` in the installed macOS 27 SDK documents `transportStateBlock` as bridging AUv2 HostCallback_GetTransportState/GetTransportState2; sample position is in output-rate frames. Existing `renderBlock` bridges AudioUnitRender. No new dependencies or HAL callback work.

## Actual checks

- `make build`: passed, 3.23 seconds.
- `make DIST_DIR=/tmp/AudioBridge-phase2 sign`: passed; final rebuild 2.17 seconds, packaging/plist lint and helper/app ad-hoc signing succeeded.
- `make DIST_DIR=/tmp/AudioBridge-phase2 verify`: passed. `cz.bytelab.audiobridge`, executable AudioBridge, macOS minimum 14.0, LSUIElement true, 0.3.2/build 11, AudioBridge.icns; embedded/bundle metadata match, helper/app signatures valid, arm64.
- Tests, app launches, audio/plugin execution and hardware measurements were **not run**, per the user's deferred execution instruction.

## Written manual acceptance cases (not executed)

1. Quit the old process; open `/tmp/AudioBridge-phase2/AudioBridge.app`. Confirm build 11 using Copy status.
2. Type −12 dB into input trim and press Return; check slider and Copy status. Try positive/negative valid values, Reset, out-of-range/non-numeric input, and commit by leaving the field. Verify live changes with an editor open.
3. Route mono to both sides, reduce both source cells to 0.5 using visible gain buttons. Verify lower pre-effect Mix L/R levels, independent side changes, smooth transitions and persisted gains. Reducing linked input trim must not change the saved cell values. Existing capture clipping cannot be repaired by digital attenuation.
4. Verify consistent Mix L/R names and pre/post-processing flow; patch copies to physical channels and confirm actual outputs by hand.
5. Stop, change bridge fill from 32 to 256/512, Start; compare **counter growth over equal intervals**, not cumulative counters from different run lengths. Compare enabled chain versus dry bypass and, separately, an empty chain. Note bypass still renders effects; it does not remove their processing cost. Larger buffers are not a guarantee of stable unattended operation.
6. Open COMPER while routing a safe signal; check native needle feedback, parameter changes and chain bypass indication. Stop and ensure host transport stops. Exercise live chain replacement, editor reopen and repeated Start/Stop. If frozen, record exact plugin version and whether SSQ/EverClean display meters. No feedback animation is synthesized by the host.

Remaining: COMPER feedback, low-buffer audio quality, long-duration drift, recovery and unattended operation are unverified. Stop for review before Phase 4.
