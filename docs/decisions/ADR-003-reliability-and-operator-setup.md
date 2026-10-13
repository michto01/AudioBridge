# ADR-003: Device safety latch and operator setup for 0.6

Status: Accepted by the operator on 2026-10-12.

## Context

Periodic AU-path losses and high CPU have not been attributed to a specific plugin or host stage. Volunteer operation needs a clear stop on device failure, intentional re-arming, simple setup and Czech/English controls. Earlier automatic device reconnection is inappropriate for this requested safety policy.

## Decision

- Device disappearance, identity/topology/rate/buffer change and confirmed callback stalls stop the explicit route and persist a re-arm latch and stopped intent. Reconnect and relaunch cannot resume it. The operator checks the route and confirms Re-arm in Bridge. Remote Start cannot clear the latch. No alternative UID or physical channel is substituted.
- Native device-error notifications are opt-in in General, with explicit OS authorization; the in-app error is always available. Unsafe teardown retains callback memory, persists stopped intent and requires restarting the process before a fresh re-arm. A driver Stop error after confirmed detach is reported separately.
- The asynchronous, queued AU render worker uses its own AudioWorkIntervalCreate workgroup. It retains the signaled SPSC queues and dedicated thread; it does not join either independently clocked device's parallel workgroup. Supporting plugins receive the cached render-context observer on the actual render thread. Setup/interval failures are diagnostics with fallback, never a deadline guarantee.
- Cache AU render and pull blocks after resource allocation. Periodic AU latency property reads are replaced by KVO-driven refresh; legacy units are also refreshed on editor close. Missing legacy notifications can leave latency estimates stale while the editor is open; no periodic property-query fallback is added.
- AU blocks are explicit in Expert: Automatic or 16/32/64/128/256/512/1024 frames, configured before resource allocation and no larger than the FIFO reserve. Automatic remains bounded at 256 and follows the larger device buffer. Plugin rejection is an actionable error; blocks are not silently padded or changed.
- Simple exposes one shared nominal rate and hardware-buffer request. Rates are filtered by reported endpoint capabilities; writes are explicit, stopped and device-wide. Both driver readbacks must match before Start. Partial changes remain visible and are not silently rolled back or hidden. Balanced FIFO reserve and automatic AU block sizing are used. Existing configured users retain Expert; new configurations default to Simple. Expert retains independent buffer drafts and saved FIFO/AU choices.
- General offers English/Czech. Operator captions, explanations and host editor controls translate. Device/plugin names, vendor editor UIs and raw driver errors remain supplied text. Copy Status and remote contracts remain English.

## Consequences and acceptance

### Operator amendment — continuous DSP switching (2026-10-13)

The operator requests DSP on/off without stopping audio and reports stable recent delivery with an AU block half the larger device buffer (128 input / 32 output / AU 64). Automatic now tries that half size, rounded down to a power of two within 16–256; explicit Expert sizes remain unchanged. This is a starting heuristic, not a compatibility guarantee.

All app routes retain the queued helper transport so the switch does not restart HAL or flush audio. A DSP-off start prepares an empty chain without loading saved plugins. First enable prepares/adopts that chain while dry audio continues; only successful adoption enables rendering if still requested. Loaded chains remain editable while off. Dry/wet changes use a 20 ms sample ramp; plugin rendering stops after fade-out. Bypass keeps rendering. This supersedes the earlier direct-start/restart-on-enable behavior. The trade-off is helper/queue overhead and dependency while DSP is off. Plugin failure remains explicit; this amendment does not authorize silently continuing after a requested chain fails.

No claim is made that every transition is inaudible: dry/wet paths are not latency-aligned, stored plugin tails/state may resume, and expensive plugin setup/rendering can still disrupt scheduling. CPU and long-run acceptance remain required.

This supersedes automatic device-loss reconnection in the original overview/architecture/Phase 4 contract. Recovery of other typed recoverable faults retains capped backoff. No vendor-specific audio handling, independent nominal-rate conversion, routing expansion or recording is introduced.

Per-plugin wall timing and a bounded latest-starvation snapshot provide evidence, not proof of causality. Low latency and long-run reliability require matched comparisons, loopback and soak acceptance. See [testing](../testing.md) and [validation history](../history/validation.md). No Phase 5 operational gate is passed by this decision. Detailed AU ownership and telemetry choices are consolidated in [ADR-004](ADR-004-audio-unit-hosting.md) and [ADR-005](ADR-005-realtime-health-and-observability.md).

## Primary guidance

[Apple asynchronous audio workgroups](https://developer.apple.com/documentation/audiotoolbox/adding-asynchronous-real-time-threads-to-audio-workgroups), [AudioWorkIntervalCreate](https://developer.apple.com/documentation/audiotoolbox/audioworkintervalcreate), [cached AU render blocks](https://developer.apple.com/documentation/audiotoolbox/auaudiounit/renderblock) and [maximum frames](https://developer.apple.com/documentation/audiotoolbox/auaudiounit/maximumframestorender). No third-party package is required.
