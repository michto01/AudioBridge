# ADR-002: N-input stereo mix and physical output fan-out

Status: Accepted by the user, 2026-10-11

## Decision

Replace the two selected input lanes and post-effect 2×2 matrix with an expandable N×2 input matrix. Rows are physical channels of one explicitly selected Core Audio input UID; columns are Mix L and Mix R. Each cell has a linear amplitude coefficient, 0–2 (1 is unity; the upper bound preserves legacy duplicated-input sums), with smooth live changes and no hidden normalization. Mono (1×2) and stereo (2×2) presets are the simple defaults, applied explicitly by the operator.

Processing order: physical inputs → N×2 mix → linked input trim → stereo AU chain (or explicit dry bypass) → stereo adaptive drift resampler → linked output gain → physical output fan-out.

One explicitly selected output UID supplies destinations. Each physical output is Off, L, R, or an explicit L+R mono sum. Multiple channels may receive identical L/R copies. Effects and drift processing run once. L+R can clip and is never selected implicitly; migration of a previously duplicated output retains its explicit sum.

Use Core Audio physical indices, including non-contiguous indices, rather than renumbering channels. Persist UID and patches together in a versioned route. Retain missing mappings and block Start until corrected. Migrate existing two-lane/matrix settings transactionally, retaining the original payload; moving mixing ahead of non-linear effects changes their sound and requires listening acceptance.

Aggregate Devices created/configured by the operator are eligible as one endpoint per direction. The app does not create aggregates, control their subdevice clocks, or independently open multiple output clocks. Native Float32 multi-stream layouts may be supported only when their reported stream/buffer topology is consistent; ambiguous layouts are rejected. Same-device duplex and other PCM representations remain separate backend work.

## Consequences

- Supersedes only the 2×2 scope restriction in ADR-001, overview, architecture and agent guidance. Universal device independence and explicit UID selection remain locked.
- Preallocate per-channel addressing, coefficient targets, snapshots and ramp state before HAL registration; no callback allocation, locks or resource replacement. Live patches are published coherently with bounded reads.
- Stereo transport, plugin buses, resampling and stereo meters stay stereo. Input meters show the stereo mix; physical capture full-scale warnings remain distinguishable from mix clipping.
- Output fan-out does not add independent clocks or repeated plugin processing. All destinations share the selected output device's HAL clock; aggregate subdevice drift is managed through macOS/operator configuration and needs hardware validation.
- Channel and CPU limits must be explicit safety limits, not a claim of unlimited processing. Missing/unsupported streams require action without fallback.

## Alternatives deferred

Arbitrary N×M effects, independent per-output-device clocks/recovery, multichannel AU chains and hidden aggregate creation. These greatly expand timing, state and UI complexity beyond the approved stereo processing path.

## Acceptance

N×2 isolated signals/summation/ramping; mono/stereo defaults; exact physical numbering; multi-stream planar/interleaved addressing; stereo fan-out and Off silence; schema migration/corruption; live coherent publication; status colours with textual accessibility; CPU/latency and sustained drift tests. Component regressions passed in the recorded 0.6.5 suite; physical/long-run acceptance remains separate. See [testing](../testing.md).
