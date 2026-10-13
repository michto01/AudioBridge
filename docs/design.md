# Interface and operator behavior

Saved missing devices use an amber card background/border and an explicit warning icon/label in Bridge, Audio and the menu popover. The last observed name is persisted as display metadata only; UID and physical patches remain the routing identity. Older selections without a stored name show the generic missing-device label until that device is observed again. Unconfigured endpoints remain visually distinct from disconnected saved endpoints.

## Visual direction

Native macOS controls, system light/dark materials, bounded SF/driver icons and restrained status colors with text/accessibility alternatives. Settings groups use bold headings and `(i)` explanations; technical details belong in Diagnostics. Driver images are rasterized to font-size bounds for native pickers; larger device cards request explicit sizes.

## Menu popover

Prominent app icon/title/subtitle, compact status with explanation and runtime, matching rounded read-only input/output cards and a downward flow link. Current stereo meters span each card; live CLIP overlays the menu meter without an empty trailing column. A separate output-device volume row and footer provide one Start/Stop/re-arm button, one Settings action and Quit. Native MenuBarExtra owns the outer surface/corners. Device selection and digital trims stay in Settings.

Device names allow two lines at equal heights; menu names use 15-point semibold text. The Czech compact volume label is Hlasitost. Missing/unconfigured devices are explicit. Settings focuses/restores the actual native Settings window; closing it never stops routing.

## Settings tabs

| Tab | Controls |
|---|---|
| Bridge | Status/runtime, matched device cards, meters/input trim, output volume or fallback gain, delay and Start/Stop/re-arm |
| Audio | Explicit devices, Simple/Expert settings, interface buffer/rate drafts, FIFO reserve, AU block and exclusive access |
| Routing | Physical input rows × Mix L/R and physical output rows × Mix L/R; explicit presets |
| Effects | Searchable cached installed AU list, chain order, editors, DSP switch and chain bypass |
| General | English/Czech, microphone/notification permissions, login/resume and optional tab visibility |
| Remote | One switch/status per HTTP/OSC service and endpoint/access help |
| Diagnostics | Warning reason, delivery/clock/queue/AU/signal/recovery sections, Reset counters, Copy Status and device export |
| About | Quick-start and settings guide |

Bridge cards measure at equal column widths and use the larger intrinsic height for both. Channel/rate metadata sits beneath the device name. Clicking the header selects Audio configuration. No fixed empty card-height allowance.

## Routing and levels

Input cells toggle unity; right-click sets linear coefficient 0–2. Mono/stereo presets apply explicitly to displayed physical indices. Multiple inputs sum without normalization. Output rows choose Off, L, R or explicit L+R; one side can feed multiple outputs. Missing saved patches remain actionable; changing a device clears only its direction's patches while stopped. UID/physical indices are never renumbered by the UI ([ADR-002](decisions/ADR-002-stereo-mix-and-fanout.md)).

Input meters show the trimmed stereo mix before effects. Output meters show stereo after effects/drift/gain, upstream of device volume. Values use whole dB relative to digital full scale; inactivity is explicit. CLIP holds briefly; raw capture full-scale and physical output summation counts remain distinguishable. Digital attenuation cannot repair clipped capture.

Input trim persists and ramps over 20 ms. Output uses writable device volume first; digital gain is held at unity in that mode and the saved fallback remains available for other devices. Devices without writable master volume use −60 to +12 dB digital gain in Bridge. The menu exposes hardware volume only. Capability checks preserve the current mode until readback, and Start waits while pending. Volume may affect other clients and quantize to hardware steps; remote digital gain is rejected when device volume is available/checking ([ADR-008](decisions/ADR-008-output-level-and-device-access.md)).

## Buffers and effects

Simple requests one shared rate/hardware buffer while stopped; both driver readbacks must match. Switching mode alone writes nothing. Expert drafts start from current reported values, with 64 frames only as fallback, and retain independent device buffers, reserve and AU choices. Driver ranges do not promise arbitrary values. Common presets plus custom requests expose rejection/readback explicitly; zero buffers are unsupported.

Balanced FIFO reserve is `max(64, 2 × larger current device buffer)`. Capacity is separate headroom with a 1024-frame minimum, not added occupied delay. Automatic AU blocks try half the larger device buffer, rounded down to a power of two within 16–256 and constrained by reserve. Expert can request 16–1024 powers of two within reserve. All changes take effect at the appropriate stopped Apply/next Start, with no silent hardware writes.

AU search matches cached display names, case/accent-insensitive and all query words. Initial/manual metadata scans run in a separate helper with progress; cached results remain usable. Loading still validates availability. Live editors control the rendering instance; Close and save persists state without Cancel rollback. Stopped editors use a separate instance with Save/Cancel. Close an editor before chain changes/Stop if state must be saved. Serialization failure completes once with an error and keeps previous saved state, without undoing parameters already changed live.

DSP off fades to dry then suspends plugin rendering; bypass keeps rendering for editor feedback. Both keep loaded units editable. First enable after a dry start loads/adopts the saved chain while audio continues. No latency alignment or guaranteed click-free transition. See [ADR-004](decisions/ADR-004-audio-unit-hosting.md).

## Status, diagnostics and accessibility

Grey means idle/stopped/unconfigured; green requires fresh callbacks/priming/delivery; amber means startup or recent delivery loss; red means action required. Five continuously healthy seconds clear a display warning only. Actual frame losses/format faults and later callback gaps restart the window. Rebuffer bookkeeping/occupancy alone are not proof of loss or recovery; actual recenter discards remain counted. Silence and clipping do not affect delivery health. Diagnostics states the reason directly. Supervisor backoff reset uses a separate 20-second healthy window.

Device loss/change/stall persists stopped intent and local re-arm confirmation; reconnect/relaunch/remote Start cannot clear it. Manual Stop suppresses retries/resume. Permissions require explicit interaction; denied notification permission does not hide in-app faults. System-audio capture is marked unused. Login/resume are independent opt-ins ([ADR-003](decisions/ADR-003-reliability-and-operator-setup.md)).

Show debug information defaults off at launch. It reveals optional queue/drift/timing/accounting in normal views; Diagnostics/Copy Status always retain technical detail. Reset counters takes an observation baseline without changing queues, drift, warnings or engine totals. Maxima, slot timing and complete-cycle counters remain labeled run totals. Delay is an accounting estimate, not physical loopback; missing reports remain Unknown.

Controls remain keyboard/VoiceOver accessible; status is never color-only. Info buttons suppress persistent focus decoration but retain button activation. English/Czech translates host UI; supplied names/vendor editors/raw errors stay supplied. Copy Status and remote wire contracts remain English. [Testing](testing.md) tracks pending visual/accessibility acceptance.
