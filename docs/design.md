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

Tabs or sections: `Audio` (device UIDs, actual format, matrix and presets, gain, latency profile); `General` (launch at login, auto-routing, appearance); `Diagnostics` (state, device identities, sample rates, FIFO occupancy, under/overruns, resampling correction, recovery history, export); `About` (version, licences).

### 2×2 matrix semantics

Let `x1`, `x2` be input channels, `yL`, `yR` output channels:

```
yL = m11*x1 + m21*x2
yR = m12*x1 + m22*x2
```

Rows are inputs, columns are outputs. Defaults `[[1,0],[0,1]]`. Presets: Stereo `[[1,0],[0,1]]`; Swap `[[0,1],[1,0]]`; Mono input 1 `[[1,1],[0,0]]`; Mono sum `[[0.5,0.5],[0.5,0.5]]`. Show clipping risk if total contributions exceed unity; do not silently normalize custom settings. UI should expose 0.00–1.00 per cell with numeric entry for precision; advanced signed mixing deferred.

### Gain

Digital output gain: provisional -60 to +12 dB; 0 dB default; smooth changes. Display whether output device has an independent system/hardware volume setting, and do not silently change it. External analog destinations must be calibrated separately.

## Status vocabulary

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
