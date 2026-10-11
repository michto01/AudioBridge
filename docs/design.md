# Design / UX specification

## Visual direction

Native macOS controls, compact spacing, restrained status colors, no dashboard clutter. Use system materials and SF Symbols. Follow system light/dark appearance and accessibility settings. Status must not be color-only.

## Menu-bar popover (primary)

```
┌──────────────────────────────────────────┐
│ ◉ Audio Bridge                  ● Running │
│                                          │
│ INPUT   Selected Core Audio Input       48 kHz 2ch │
│ L ███████░░░  -12 dBFS                  │
│ R ██████░░░░  -16 dBFS                  │
│                                          │
│ OUTPUT  Mac Headphones        48 kHz 2ch │
│ L ██████░░░░  -13 dBFS                  │
│ R █████░░░░░  -17 dBFS                  │
│                                          │
│ Gain   ─────●────────          0.0 dB   │
│ Matrix  Custom                        ⚙ │
│                                          │
│ ✓ Healthy    [Stop]   [Settings…]       │
└──────────────────────────────────────────┘
```

Meters must have numeric dBFS values, visible clipping flags, and an explicit inactive/unknown state. Static prototype meter values must never ship as production data.

## Settings window

Tabs or sections: `Audio` (devices, actual format, gain, effects, latency profile); `Routing` (input mix grid, presets, output patches); `General` (launch at login, auto-routing, appearance); `Diagnostics` (state, device identities, sample rates, FIFO occupancy, under/overruns, resampling correction, recovery history, Copy status/export); `About` (version, licences).

### Routing grid (ADR-002)

A Routing tab shows the selected input device name above a grid: physical input rows × Mix L/Mix R columns. Each cell toggles a connection (unity when enabled); right-click exposes exact linear gain and a slider, 0–2. One input to both sides is mono duplication; multiple inputs can sum to either side. Mono and Stereo preset buttons use the first displayed physical indices only after an explicit press. For each side, `mixSide = sum(input[channel] * cellGain)`; no hidden normalization.

A second grid shows selected output name with physical output rows × Mix L/Mix R columns (after processing). Select one side per output; multiple outputs can take the same side. Right-click explicitly selects mono L+R (clipping risk) or disconnect. Missing saved channels remain labelled with an explicit Remove patch action. Changing devices clears only that direction's patches, requires Stop and never substitutes defaults. Patches and cell gains change live with 20 ms ramps.

Stereo input meters show the mixed/trimmed bus before effects; output meters show stereo after effects/drift/gain. Physical input full-scale counts and physical output summation counts are separate diagnostics. Native names and physical indices stay in the product UI; technical UIDs remain in Diagnostics/Copy status. Original 2×2 settings migrate with a backup; the matrix moves ahead of effects, requiring listening acceptance.

Menu-bar waveform status: grey idle/unconfigured; green fresh healthy local callbacks/primed buffers; amber startup/rebuffering/degraded; red actionable fault. After a delivery fault, amber clears after 20 continuously healthy seconds with fresh callbacks, primed output and unchanged glitch counters; new glitches/callback gaps restart the window. Cumulative counters remain in Diagnostics. Clipping and silence do not enter delivery health. Colour is accompanied by popover text and an accessibility label. No signal/silence-based alarm or automatic recovery is implied. Copy status copies relevant plain-text diagnostics without audio or saved plugin state.

### Gain

Digital output gain: provisional -60 to +12 dB; 0 dB default; smooth changes. Display whether output device has an independent system/hardware volume setting, and do not silently change it. External analog destinations must be calibrated separately.

## Status vocabulary

Settings tabs: **Playback** (play icon) holds Start/Stop, stereo meters/linked gains and delay/processing telemetry; **Audio** holds UID device selection, current driver buffers, bridge fill and permission; **Routing** holds patch grids; **Effects** holds AU catalog/chain/editor controls. General, Diagnostics and About remain separate. Menu-bar quick controls remain available. The full-chain delay display explicitly distinguishes an estimated allowance from loopback measurement, retains Unknown device reports, and separates AU processing wall time from reported signal latency. Interface buffer drafts begin with the real current driver value, otherwise 128 frames clamped to a valid reported range; changes require explicit Apply while stopped.

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

All controls keyboard accessible with VoiceOver labels. Preserve menu-bar status while settings window closes. Provide a status text alternative to icon color. Show reconnect progress without blocking the UI. Do not provide a fake green success status before audio callbacks have started and health is confirmed.
