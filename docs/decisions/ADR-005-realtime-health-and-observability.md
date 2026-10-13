# ADR-005: Realtime ownership and honest delivery telemetry

Status: Accepted engineering behavior, consolidated 2026-10-13 from drift, scheduling, diagnostic and audit corrections. No filter/scheduling retuning authorized by consolidation.

## Context

Independent device clocks cannot be bridged indefinitely by a FIFO alone. Plugin/scheduler/UI pressure can resemble clock drift. Delay, clipping and historical counters must not be mistaken for current health or measured transit time.

## Decision

- Preallocate C callback storage and lock-free counters; preserve SPSC ownership/publication and paired arm/recheck fences. No blocking waits, allocation, ARC/UI/property/plugin work in callbacks. Confirm detach/quiescence before free; retain uncertain callback memory. Per-attempt irreversible gates make Stop visible before queued lifecycle teardown without locks across HAL calls.
- Use adaptive fractional FIR source consumption at matching nominal rates with bounded correction/anti-windup/refill. Retain history across starvation and avoid speculative reads after the last requested frame. Conserved pending source is accepted capture minus consumed/discarded source, not a sum double-counting in-flight work. Measured clock-rate difference, controller command and last applied correction stay separate.
- Reserve target differs from allocated queue capacity. Exact callback demand/refill includes retained FIR state; unused capacity adds no signal delay. Small reserve can't cover arbitrary stalls or sustained overload. Don't automatically raise buffers or infer physical skew solely from near-limit ppm.
- Optimize with active/ramping sparse routes, coherent version caching, generation-validated FIR demand plans, narrow runtime discovery and minimal metrics reads. Preserve filter arithmetic, ramps, output zeroing and safety checks. SIMD/cache-line/scheduling changes need separate evidence.
- Green requires real callback freshness, priming and delivery. Underrun/overrun/format deltas and later callback gaps cause amber; five continuously healthy seconds clear only the display warning. Full-scale audio/CLIP and silence are signal conditions, not delivery faults. Recenter bookkeeping alone is not loss, but actual discarded frames remain counted. Supervisor backoff reset is separately 20 healthy seconds.
- Reset counters takes an observation baseline only: no queue flush, drift/health reset or engine counter mutation. Maxima, queue range, slot timing and complete-cycle values are explicitly run totals. New routing sessions reset their own observation baseline.
- Separate estimated bridge/callback allowance, device/stream/safety reports and combined known subtotal. Average dynamic display values over five seconds; missing facts remain Unknown. AU reported signal latency differs from DSP wall time; startup reserve isn't added twice. Physical transit requires loopback.
- Report DSP block, per-plugin, wake and complete cycle/adoption timings separately. Cycle includes adoption/context hooks and pool drain but excludes idle waiting; metric recording follows that scope. Wall time includes preemption and is neither CPU utilization nor causal proof. Different slot-instance windows cannot be summed as aligned means.
- Health supervision stays at 20 Hz; normal informational updates use 5 Hz/native-layer metering. Publish faults/state/command transitions immediately; visible precision needn't match raw diagnostics.

## Consequences and acceptance

Real losses remain losses even if hard to hear; startup events remain counted. An accepted Mach/workgroup setup isn't a deadline guarantee. Synthetic component speedups don't prove whole-app CPU reduction or hardware quality. Preserve local-only diagnostics without audio/state. Test demand/history/clock/queue/wake/lifetime edges, compare plugin modes at equal settings, and complete physical latency/12-hour gates ([testing](../testing.md)).
