# Architecture decisions

These records preserve accepted choices and their trade-offs. Consolidation records capture existing behavior; they do not approve new scope or certify hardware acceptance. Current contracts apply superseding decisions instead of retaining contradictory stage instructions.

| ADR | Decision |
|---|---|
| [001](ADR-001-universal-core-audio.md) | Universal Core Audio endpoints, explicit UID/physical channels; original 2×2 scope superseded by 002 |
| [002](ADR-002-stereo-mix-and-fanout.md) | N×2 stereo mix and one-device output fan-out |
| [003](ADR-003-reliability-and-operator-setup.md) | Device safety latch, intentional re-arm and Simple/Expert/localized operation |
| [004](ADR-004-audio-unit-hosting.md) | Isolated stereo AU hosting, live editing/adoption and persistent dry transport |
| [005](ADR-005-realtime-health-and-observability.md) | Bounded realtime ownership, drift/queues and honest health/latency telemetry |
| [006](ADR-006-remote-control.md) | Opt-in native HTTP/OSC, bearer token/IP allowlist and generation-safe lifecycle |
| [007](ADR-007-build-and-distribution.md) | SwiftPM/macOS bundle identity, ad-hoc packaging and distribution limits |
| [008](ADR-008-output-level-and-device-access.md) | Hardware volume first, digital fallback and optional driver-exclusive access |

For a new decision, document context, decision, consequences, alternatives and acceptance. Include the date and status; state which earlier choice it supersedes. Do not use an ADR to turn an unrun test into a passed gate. Full historical stage discussions remain in Git; [validation history](../history/validation.md) keeps concise evidence.
