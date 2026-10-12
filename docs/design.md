# Design / UX specification

Current 0.6 amendment: [ADR-003](decisions/ADR-003-reliability-and-operator-setup.md) supersedes automatic re-arming after device loss/identity/format/buffer changes or confirmed callback stalls. Simple/Expert setup and English/Czech UI are described there. Operational acceptance remains pending.


## Visual direction

Native macOS controls, compact spacing, restrained status colors, no dashboard clutter. Use system materials and SF Symbols. Follow system light/dark appearance and accessibility settings. Status must not be color-only.

Group titles use a larger bold heading above the controls. Each settings group has an `(i)` button for explanations, limitations and detailed state; long notes do not occupy the main control surface. Keep the single Bridge status badge and one listener status per Remote group visible. Current delivery-warning causes remain directly readable in Diagnostics. Info popovers allow text selection and scroll within a bounded height.

Bridge device icons explicitly fit a 42-point square; device pickers retain compact icons. The endpoint layout measures both cards at the same column width, uses the larger intrinsic height for both and aligns their tops and bottoms. Device-volume or fallback-gain controls contribute to the measured height rather than a fixed empty-space allowance. Headers, meters and trim rows align between the cards.

Diagnostics groups delivery, queues/clocks, Audio Unit timing, signal levels and recovery into labeled value rows. Copy Status has the same distinct report sections. Keep device catalog and session history expandable instead of interleaving technical paragraphs with controls.

## Menu-bar popover (primary)

```
┌──────────────────────────────────────────┐
│ ◉ Audio Bridge                  ● Running │
│                                          │
│ INPUT   Selected Core Audio Input       48 kHz 2ch │
│ L ███████░░░  -12 dB                    │
│ R ██████░░░░  -16 dB                    │
│                                          │
│ OUTPUT  Mac Headphones        48 kHz 2ch │
│ L ██████░░░░  -13 dB                    │
│ R █████░░░░░  -17 dB                    │
│                                          │
│ Output device volume ────●──    70%     │
│                                          │
│ ✓ Running    [Stop]   [Settings…]       │
└──────────────────────────────────────────┘
```

The menu popover has compact endpoint names, meters, output-device volume and Start/Stop/Settings/Quit. Digital trim controls remain in the main Bridge settings window. Meters use whole-dB labels, visible clipping flags, and explicit inactive/unknown state. Static prototype meter values must never ship as production data.

## Settings window

Tabs or sections: `Bridge` (Start/Stop, runtime, equal input/output endpoint cards, linked trim sliders and delay); `Audio` (devices, actual format, interface buffer drafts and separate FIFO reserve); `Routing` (input mix grid, presets, output patches); `Effects` (AU chain); `General` (permissions, launch/resume, tab visibility); optional `Remote` (HTTP/OSC endpoints and independent status); optional `Diagnostics` (technical state, device identities, counters, Copy status/export); `About` (quick-start and settings guide).

### Routing grid (ADR-002)

A Routing tab shows the selected input device name above a grid: physical input rows × Mix L/Mix R columns. Each cell toggles a connection (unity when enabled); right-click exposes exact linear gain and a slider, 0–2. One input to both sides is mono duplication; multiple inputs can sum to either side. Mono and Stereo preset buttons use the first displayed physical indices only after an explicit press. For each side, `mixSide = sum(input[channel] * cellGain)`; no hidden normalization.

A second grid shows selected output name with physical output rows × Mix L/Mix R columns (after processing). Select one side per output; multiple outputs can take the same side. Right-click explicitly selects mono L+R (clipping risk) or disconnect. Missing saved channels remain labelled with an explicit Remove patch action. Changing devices clears only that direction's patches, requires Stop and never substitutes defaults. Patches and cell gains change live with 20 ms ramps.

Stereo input meters show the mixed/trimmed bus before effects; output meters show stereo after effects/drift/gain. Physical input full-scale counts and physical output summation counts are separate diagnostics. Native names and physical indices stay in the product UI; technical UIDs remain in Diagnostics/Copy status. Original 2×2 settings migrate with a backup; the matrix moves ahead of effects, requiring listening acceptance.

Menu-bar waveform status: grey idle/unconfigured; green fresh healthy local callbacks/primed buffers; amber startup/rebuffering/degraded; red actionable fault. After actual delivery loss, amber clears after five continuously healthy seconds; new underruns, overruns, format faults or callback gaps restart the window. Diagnostics names the current warning cause and clean-time progress. Queue recentering and rebuffer bookkeeping alone do not count as lost frames. Cumulative counters remain in Diagnostics. Clipping and silence do not enter delivery health. Colour is accompanied by popover text and an accessibility label. No signal/silence-based alarm or automatic recovery is implied. Copy status copies relevant plain-text diagnostics without audio or saved plugin state.

### Gain

Digital output gain is a fallback for devices without writable volume: -60 to +12 dB; 0 dB default; smooth changes. Writable device volume is the primary output level control, and digital gain stays at 0 dB in that mode. Device volume is changed only through explicit user control. External analog destinations must be calibrated separately.

## Status vocabulary

Settings tabs: **Bridge** holds the two-state Start/Stop control, runtime, stereo meters/linked trim sliders and delay; **Audio** holds UID device selection and driver buffer drafts, with bridge FIFO clearly separate; **Routing** holds patch grids; **Effects** holds AU controls. General holds permission and tab visibility. Copy status is available in Diagnostics only. Delay is a five-second rolling average for dynamic bridge terms; detailed current snapshots remain available in Diagnostics. Device buffer drafts start at 64 frames when within the reported range, never write until explicit Apply while stopped, and show readback. FIFO Balanced defaults to `max(64, 2 × larger current device buffer)` and applies next Start.

- **Stopped** — operator disabled routing; no retry.
- **Waiting for input/output** — selected UID missing; automatic retry active.
- **Starting** — opening and configuring devices.
- **Running** — engine callbacks healthy and buffer in acceptable range.
- **Degraded** — sustained glitches, FIFO instability or abnormal callbacks; local audio may be impaired.
- **Recovering** — stopping/restarting after a device or engine fault.
- **Action required** — permission denied or invalid configuration.

Do not conflate silence with device failure. No silence notifications. Technical failure notifications should be rate-limited and optionally disabled.

## Persistence / first launch

On first launch, ask user to choose input and output; do not auto-select a potentially dangerous default output. After successful setup, enable `desiredRouting=true` by explicit confirmation; login launches and resumes if enabled. Manual Stop persists `desiredRouting=false` until Start. Store settings with a schema version and migrate safely. Reconfiguration failures should retain last known good configuration.

## Accessibility and interaction

Diagnostics contains a “Show debug information in the interface” toggle, disabled at each launch. Bridge and Audio hide technical runtime counters, queue/timing detail and detailed delay accounting until enabled. Normal meters, status, actionable faults, buffer configuration and a compact delay estimate stay available. Diagnostics, Copy status and export retain full information independently of this display choice.

All controls keyboard accessible with VoiceOver labels. Preserve menu-bar status while settings window closes. Provide a status text alternative to icon color. Show reconnect progress without blocking the UI. Do not provide a fake green success status before audio callbacks have started and health is confirmed.

### Output level control

Bridge retains input trim. Its output card offers one level control: writable Core Audio device volume where available; digital stereo gain otherwise, labeled as a fallback. Digital gain is held at 0 dB when device volume is available, while the saved fallback gain is retained. Same-device capability refresh preserves the active mode until readback completes; Start waits for pending capability checks. Software output meters are upstream of device volume. The menu keeps device volume only; fallback gain is configured in Bridge. Remote output-gain commands are rejected when device volume is available or its check is pending; status exposes applied and saved fallback gain separately.

### Diagnostic measurement window

Reset counters in Diagnostics zeros displayed cumulative delivery, callback, frame, drift-event, AU timing and clipping counts by taking a snapshot baseline. Engine counters, callback timestamps, queues, drift and health checks stay intact. Interval processing mean is derived from interval render nanoseconds and block count. Current queue/rate/latency/clock/last-block values stay live; lifetime maxima and queue range are labeled for the run. Copy Status includes the reset timestamp and interval counts alongside lifetime totals. New routing attempts clear the baseline.

### Effect processing enable

The Effects tab has a persistent Enable effect processing switch, default on for existing installations. Off skips all plugin render calls at the next helper processing block and forwards captured stereo unchanged. Loaded processors/settings remain available for editing and live re-enable. The helper and its queues remain active. Plugin DSP state and signal meters pause; editor banners explicitly identify this mode. Whole-chain bypass retains rendering for editor feedback and its saved state is preserved while processing is off. Existing queued audio can finish before dry output arrives; transitions and retained plugin tails are not guaranteed seamless. Starting with processing off skips plugin loading and the helper entirely, using the direct bridge. Enabling from that direct route safely restarts it to load effects. Changing the switch during preparation/recovery cancels the attempt and restarts using the saved mode; manual Stop overrides it. Controls remain usable during recovery. Switching off an existing live AU route still forwards dry audio through its retained helper. Diagnostics and remote status distinguish requested/observed processing state, and effect latency applied to a dry path is reported as zero.

### UI work and safe bundle updates

Engine health/worker supervision continues at 20 Hz; normal informational snapshots publish at 5 Hz. Fault, delivery-state and AU command-response transitions publish immediately. Meters quantize display targets to whole dB and animate native Core Animation layers, avoiding SwiftUI/Canvas interpolation at display refresh rate. Release optimization remains the packaging configuration used for operator builds. Packaging refuses to replace an app bundle whose executable is running, since a running old executable can otherwise spawn a newly replaced incompatible helper. Helper startup passes an explicit transport version and captures the tail of setup errors; incompatible/failed startup exits require action instead of automatic retries.

Startup distinguishes preparing devices/effects from filling audio queues. Delay shows Filling before output priming and averages collected samples from the first valid sample rather than displaying instantaneous values during the average's initial five seconds. This is presentation only; real startup overflows and later delivery losses remain counted. Diagnostics distinguishes reserve target from allocated capacity per queue (minimum 1024 frames). Capacity is headroom, not an additional fill target. An AU route has capture and ready queues; a direct route has one queue. Only occupied audio contributes to queue delay. A retained helper's backlog is not silently flushed when DSP is disabled.
