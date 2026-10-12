# Czech terminology, permissions and scrolling — 0.6.3 / build 36

## Translation review

Reviewed the operator catalog against [Audacity's Czech source catalog](https://github.com/audacity/audacity/blob/master/au3/locale/cs.po), retrieved on 2026-10-13. No dependency or translation file was imported. Individual catalog entries vary in quality; Audio Bridge retains original help prose and terminology suited to its live bridge rather than copying editor-specific wording.

| Concept | Operator wording |
| --- | --- |
| Audio frames | vzorky, meaning samples per channel, not the sum across channels |
| Buffer | vyrovnávací paměť |
| Sample rate | vzorkovací frekvence |
| Gain / input trim | zesílení / vstupní zesílení, including negative dB attenuation |
| Meter | ukazatel úrovně |
| Clipping | přebuzení; compact CLIP indicator is retained |
| Resampling | převzorkování |
| Latency | zpoždění |

Corrected callback/correction labels, effect ordering, queue loss/refill labels and help prose. Added permission and common operation-status translations. Driver/plugin names, third-party editors, raw errors, Copy Status and HTTP/OSC contracts remain in their original language. The two operator catalogs now contain 435 matching unique keys with matching format placeholders.

## Permissions

General groups microphone and notification controls together, with details behind its info button. The notification preference and OS authorization are separate: disabling device-error alerts does not revoke macOS permission. Returning from System Settings refreshes both permission readouts. Notification authorization distinguishes allowed, provisional quiet delivery, denied and not yet requested. A shortcut opens notification settings; its deep link is best effort and has not been manually verified.

[Apple documents microphone authorization for both microphones and external audio interfaces](https://support.apple.com/cs-cz/102071). This app reads the explicitly selected Core Audio input. It creates no system-audio tap or screen/app capture session and requests no system-audio recording authorization. General states that system-audio capture is unused, rather than inventing its permission status. No new capture feature or unused usage-description key was added. Notifications can be permitted yet suppressed by Focus/presentation settings.

[SoundSource](https://rogueamoeba.com/soundsource/) has a similar menu-bar/device/effects interface, and additionally controls individual apps' volume and output destinations. Its public feature list does not establish how its proprietary processing pipeline performs or schedules work.

## Scrolling noise and pipeline limits

The operator reports faint hiss during scrolling and inertial rendering. It has not been reproduced here. [Apple's audio workgroup guidance](https://developer.apple.com/documentation/audiotoolbox/understanding-audio-workgroups) explains the importance of meeting real-time deadlines. Display/UI load can coincide with missed audio deadlines; that does not establish that a steady hiss is caused by this app. Plugin noise floors, microphone pickup and analog/device interference are alternative hypotheses, not findings.

Two read-only process snapshots of the running **0.6.2** app, about four minutes apart:

| Process | First CPU snapshot | Second CPU snapshot |
| --- | --- | --- |
| Audio Bridge | 10.0% | 9.7% |
| AU helper | 2.9% | 2.9% |
| coreaudiod | 26.0% | 25.4% |
| WindowServer | 78.8% | 16.6% |

These are per-process point readings, not a synchronized scrolling/noise experiment, benchmark or proof of causality. No process was stopped or profiled with an attaching sampler. The running app was not replaced.

Native meter layout previously rewrote layer geometry whenever AppKit requested layout. It now does so only when its bounds or appearance change, avoiding redundant writes and interference with meter animation during unchanged layout. CPU reduction and audible benefit are unmeasured. No DSP filter, drift tuning, queue size or audio callback was changed for this hypothesis.

The [whole-pipeline audit](continuous-dsp-pipeline-results.md) remains applicable: bounded C callbacks, preallocated SPSC queues, signaled asynchronous AU rendering, audio workgroup integration and bounded drift compensation are the intended structure. This is not established as optimal or reliable indefinitely. Persistent helper overhead remains with DSP off; plugin auxiliary threads are outside host control; dry/wet transitions are not latency aligned; recovery can discard audio. The finite FIR phase table also merits quality measurement before changing its cost/quality trade-off. Worst-case deadlines, loss timelines, physical loopback quality and a long soak remain the useful next evidence.

Suggested operator comparison, not performed here: reset counters after startup; compare DSP off (not merely chain bypass), each plugin and the full chain; scroll this app versus another app with matching audio settings; record losses/recentering and AU/wake timing at the noise event. Compare with settings closed. A noise change without delivery losses calls for signal/plugin/device investigation rather than automatically increasing FIFO reserve. No audio recording is added.

## Acceptance

Actual checks on 2026-10-13:

- English/Czech `plutil -lint` passed; 435 unique keys each, identical key sets and matching format placeholders. The first catalog-check script rejected the existing header comment; the corrected parser skips comments and passed.
- `make sign BUILD_CONFIGURATION=release DIST_DIR=/tmp/AudioBridge-0.6.3-final`, with the existing external scratch/module caches and `--disable-sandbox`, passed. Release build completed in 11.92 seconds; packaging/plist lint and strict ad-hoc helper/app signing passed.
- `make verify DIST_DIR=/tmp/AudioBridge-0.6.3-final` passed: identifier `cz.bytelab.audiobridge`, version 0.6.3/build 36, minimum macOS 14, `AudioBridge.icns`, both language tables, matching embedded/bundle metadata and helper/app signatures.
- `git diff --check` passed. The separate bundle is `/tmp/AudioBridge-0.6.3-final/AudioBridge.app`; the running 0.6.2 bundle was not replaced.

Unit tests, app launch, permission prompts/settings shortcuts, scrolling/audio comparisons, plugin execution and the 12-hour gate are not run for this revision, following the deferred runtime-test workflow. Build/signature checks do not complete the audio reliability gate.
