# Testing and acceptance

## Recorded status

Last recorded automated suite: **0.6.5/build 38, 72 XCTest tests, zero failures, 2026-10-13**. The suite covers route/persistence/recovery, FIFO/gain/FIR/drift, helper queue/wake primitives, remote parsing/epochs, editor state/completion, cancellation gates, sparse routes and timing accounting. It does not prove live HAL, Network.framework sockets or third-party plugin behavior. Subsequent menu/shell changes were not followed by a new suite run. See [provenance](history/validation.md).

Run `make test`; the script uses isolated temporary scratch storage. No new execution is implied by this checklist.

## Deterministic and stress cases

- Physical-channel addressing for planar/interleaved/multi-stream buffers; malformed/null/unequal-frame lists; nonfinite samples; missing patches and schema migration/backup.
- Matrix summation without hidden normalization, explicit mono/fan-out/Off, gain ramps and live coherent publication/fade reversal.
- FIFO wrap/capacity/full/empty, publication visibility, zero-fill underrun and bounded overrun.
- FIR exact demand versus consumption, near-integer ratios, short-read history, priming/reset, prepared-plan owner/generation rejection and sample equivalence.
- Fake clocks at positive/negative offsets with bounded occupancy/correction, anti-windup, starvation/refill and conserved pending source, including counter wrap.
- Both orders of worker arm/publication, capture/output-space wakes, coalescing, EINTR/shutdown and mapping/semaphore lifetime. Existing natural-order tests do not force every interleaving.
- Renderer adoption/acknowledgment/retirement, workgroup join/interval/leave, cached contexts, dirty latency notifications and callback-free teardown under stress/sanitizers where feasible.
- Start cancellation before/during preparation and HAL startup; no retained-attempt growth over retries; unsafe detach memory retention. Dummy-ID component tests do not exercise actual driver starts.
- Partial authenticated HTTP completion after disable, stale listener/feedback callbacks after restart, OSC exact tags/arguments/padding/integer/float/range checks; real sockets remain separate.
- Invalid/oversized AU state, exactly-once completion, previous saved state and a subsequent command after both editor close paths. Real plugin property calls need live checks.
- Simple capability filtering/readback/partial failure, expert preference retention, permission faults, manual Stop precedence, persisted latch and remote re-arm rejection.

## Lifecycle acceptance

| Scenario | Expected |
|---|---|
| Explicitly configured launch with resume opt-in and saved desired state | Start same UIDs only after readiness |
| Manual Stop, relaunch or recovery | Stay stopped; retries cancelled |
| Active input/output loss, changed identity/topology/rate/buffer or confirmed callback stall | Safe stop, actionable fault and persisted local re-arm latch |
| Reconnect, relaunch or remote Start after that fault | No automatic resume or substitution; local re-arm required |
| Permission/configuration/render fault | Action required; no prompt/retry storm |
| Other recoverable helper fault | Retry same route with capped 1/2/4/8/16/30-second backoff |
| Stop during preparation/retry/adoption | Cancel intent and prevent subsequent delivery |
| Unsafe callback detach | Retain memory; block new route until restart |
| Close Settings | Engine continues independently |

## Hardware and plugin procedure

Use known distinguishable L/R signals and at least two stated device pairs, including an external output. Record build SHA, OS/architecture, exact UIDs/current stream formats, patches, rates, input/output buffers, reserve, AU block and chain. Check actual physical numbering, unpatched silence, summation/clipping and selected UID stability when system defaults change.

For comparisons, keep settings fixed and use equal windows (at least five minutes initially). Reset observation counters after startup; compare loaded DSP off, empty chain, each plugin, full chain and bypass. All app routes retain helper transport; a no-helper baseline requires a separately identified harness/build. Bypass renders plugins. Repeat Settings/editor open versus closed. Compare queue bounds, losses, clock trend, per-plugin/DSP/cycle/wake timing and main/helper CPU, alongside listening. Wall time is not CPU attribution; a full-scale indication is not a delivery glitch.

Test unplug/replug each endpoint, external rate/buffer changes, callback stalls, sleep/wake, permissions, login and explicit re-arm. Confirm no substitute output and manual Stop remains authoritative. Check live DSP changes, adoption, state persistence and latency changes in legacy editors. Remote checks include tokens, denied IPs, partial requests at disable, restart generations, Local Network/firewall and Companion.

Measure analog end-to-end latency with physical loopback; callback sizes/accounting are not the measurement. Then run **12 hours** at accepted settings, dry and with the deployment chain: no crash/deadlock, bounded queues/CPU/memory/correction and no unaccounted underrun/overrun after a defined startup window. Document every loss and interruption; do not erase failures or relabel inaudible losses as harmless. No broad device compatibility claim follows from one pair.

## UI and release review

Review light/dark and English/Czech, long/missing names, scaled icons, device-volume/fallback/loading/error modes, inactive/CLIP meters, one Settings action, window focus, keyboard/VoiceOver and info-popover behavior. Verify debug defaults off and Reset counters doesn't change audio/health.

Clean-account ZIP extraction, Gatekeeper path, microphone/notification/local-network authorization, stable installation/login and host/helper signatures remain release checks. [Compliance](compliance.md) is the deployment checklist.

## Reporting

For each test record ID, build SHA, device/plugin setup, steps, expected/observed result, duration, metrics and pass/fail/not-run. Separate automated simulation, operator observation, source inspection and executed hardware evidence. Never include audio samples, plugin state or bearer tokens in public reports.
