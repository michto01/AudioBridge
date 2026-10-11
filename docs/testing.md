# Test strategy

## Test layers

1. **Pure unit tests**: matrix math, gain conversion/ramping, PCM layout conversions, ring buffer wraparound/overrun/underrun, resampler controller stability, schema migrations and retry policy.
2. **Simulated integration tests**: fake device catalog, fake callback clock, deterministic input signals, device disappearance, format changes, permission denial and manual Stop precedence.
3. **Hardware tests**: independent Core Audio input/output pairs (built-in, external USB, virtual where available), analog loopback or audio analyzer; optional deployment-specific end-to-end tests.
4. **Operational soak tests**: extended streaming, recovery, login and power transitions.

## Deterministic DSP tests

- Identity matrix preserves each channel with numerical tolerance.
- Swap routes L/R correctly; mono sum uses 0.5+0.5; mono input 1 duplicates only first channel.
- Full-scale simultaneous summation shows expected clipping risk, not hidden normalization.
- Gain 0 dB is unity; -6 dB approximately 0.501 amplitude; changes ramp without discontinuity.
- FIFO ordering, exact wraparound, full/empty boundary, no stale data on underrun, bounded occupancy on overrun.
- Simulate input/output clock offsets ±50, ±100 and ±200 ppm (test values, not device claims); verify bounded long-run occupancy and rate correction.
- Verify sample format conversion and planar/interleaved handling against golden signals.
- Meter silence = -infinity dBFS, clipping detection and correct per-channel isolation.

## Supervisor tests

| Scenario | Expected |
|---|---|
| Login with configured devices | Start automatically if desiredRouting=true |
| Login missing input | Waiting; no fallback; retry |
| Login missing output | Waiting; no fallback; retry |
| Input unplug/replug | Recover same UID and resume |
| Output unplug/replug | Recover same UID; never use speakers instead |
| Both missing | Report both; continue bounded retries |
| Permission denied | Action required; no repeated permission prompt storm |
| Stop during recovery | Cancel retry; remain stopped |
| Restart app after manual Stop | Remain stopped until explicit Start |
| Change device UID in settings | Reconfigure transactionally |
| Format/rate change | Re-probe/rebuild safely |
| Repeated failure | Retry capped at 30 seconds, no CPU spin |

## Hardware verification procedure

- Use a known stereo test signal with distinguishable L/R content.
- Verify actual input device identity and stream format in diagnostics.
- Route between at least two distinct device pairs, including an external output if available; confirm selected UID remains fixed when the system default output changes.
- Measure analog waveform levels and clipping before feeding downstream equipment; configure downstream input sensitivity separately.
- Measure end-to-end latency using an external reference/loopback; do not infer latency solely from frame buffer size.
- Run 12 hours with logged FIFO occupancy, ppm correction, underrun/overrun counts, callback stalls, CPU and memory.
- During separate runs: unplug/replug input; unplug/replug output; change nominal rate; switch system default output; sleep/wake; restart app; test permission denial and reauthorization.
- Record interruption duration and whether audio resumed without operator action. Recovery cannot guarantee zero audible interruption when hardware is physically disconnected.

## Quantitative provisional acceptance targets

- No crashes or deadlocks in 12-hour nominal hardware test.
- No persistent FIFO occupancy trend toward full/empty; correction converges within configured bounds.
- No unaccounted underruns/overruns; target zero during stable nominal run, document any occurrence.
- CPU/memory reported, not assumed. Set thresholds after first measured baseline.
- No unintended output-device substitution in any test.
- Manual Stop remains authoritative across app restart and device events.

## Reporting template

For each test record: test ID, OS/architecture, input/output UID and format, build SHA, steps, expected, observed, metrics/log attachment, pass/fail/not-run, and issue link. Do not mark simulated tests as evidence of hardware compatibility.
