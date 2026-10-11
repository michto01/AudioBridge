# ADR-001: Universal Core Audio endpoints

Status: Accepted

## Context

The first deployment uses a TightAV Dante USB adapter and an ATEM Mini, but the user requires a reusable audio bridge independent of either device.

## Decision

Treat all compatible Core Audio PCM input/output devices uniformly. Select persistent device UIDs and explicit channel indices. Keep V1 routing limited to a 2×2 logical matrix, with internal interfaces that can later generalize to N×M. No transport/vendor special cases.

## Consequences

The app needs runtime format/capability probing, graceful rejection of unsupported devices, per-device recovery, independent-clock drift compensation and broader hardware tests. The TightAV-to-ATEM path is an example integration test, not a normative requirement.

## Alternatives rejected

- TightAV-specific implementation: unnecessarily narrows scope and creates vendor coupling.
- Dante SDK/network endpoint: unnecessary when the adapter already exposes Core Audio PCM.
- Assume every USB sound card behaves identically: invalid across stream layouts, rates, buffering and clock domains.
