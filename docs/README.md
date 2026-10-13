# Documentation

Current contracts describe intended behavior and implementation limits. ADRs explain lasting choices; validation records distinguish executed checks from acceptance still required. Git retains the detailed historical stage reports removed during documentation consolidation.

| Guide | Purpose |
|---|---|
| [Overview](overview.md) | Product scope, invariants and non-goals |
| [Architecture](architecture.md) | Pipeline, modules, queues, clocks and ownership |
| [Design](design.md) | Operator interface and state semantics |
| [Build](build.md) | Makefile workflow, packaging and troubleshooting |
| [Device compatibility](device-compatibility.md) | Supported PCM/endpoints and physical-channel identity |
| [Remote control](remote-control.md) | HTTP/OSC wire contract and access model |
| [Testing](testing.md) | Deterministic coverage and hardware/soak acceptance |
| [Plan](plan.md) | Implementation milestones and remaining review gates |
| [Compliance](compliance.md) | Permissions, signing, deployment and release checklist |
| [ADRs](decisions/README.md) | Accepted architecture decisions |
| [Validation history](history/validation.md) | Compact provenance of checks and meaningful repairs |

Start with the [project README](../README.md) for usage and [contribution guide](../CONTRIBUTING.md) for changes. Implementation does not imply a passed hardware gate.
