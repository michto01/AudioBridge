# ADR-006: Opt-in LAN status and control

Status: Accepted by operator, 2026-10-12; lifecycle fixes consolidated 2026-10-13. Supersedes the original remote-control non-goal; network audio remains excluded.

## Context

Bitfocus Companion needs status and occasional control. The operator selected bearer authentication for HTTP and source-IP allowlisting for OSC. Apple's Network/Security frameworks cover the requirement without a package dependency.

## Decision

- HTTP/OSC default off, with independent persistent switches/listener status. Endpoint edits save as drafts; cycle only the affected service to apply them.
- HTTP uses a random Keychain bearer token, bounded single-request connections and versioned JSON paths. OSC accepts exact allowlisted source addresses and reports to an explicitly configured host once per second.
- Control existing Start/Stop, input trim, eligible digital output fallback and whole-chain bypass only. No remote UID/physical-patch selection and no ability to clear the device safety latch. Output-gain commands reject writable-volume/pending-check modes.
- Send status, human-readable endpoint names and linear meter peaks only; no audio, plugin state or device UIDs. Wire names/status remain English independently of UI language.
- Invalidate separate service generations before cancelling listeners/accepted connections. Guard acceptance, receive/dispatch, stale status/cleanup and feedback ticks. Parse OSC Int32 separately from Float, with exact tags/count/padding/length and finite/range validation.

## Consequences

HTTP is plain TCP without TLS; bearer traffic is visible to network observers. OSC allowlisting isn't cryptographic authentication and UDP has no encryption. Trusted isolated LAN only, no public forwarding; macOS Local Network permission/firewall still apply. No internet service or external dependency is needed. Native implementation keeps the protocol small; it isn't a general web server.

## Acceptance

The [wire reference](../remote-control.md) is normative. Parser/epoch component checks don't replace live sockets: verify token/IP rejection, partial commands completed after disable, obsolete callbacks after restart, latch/volume rejection, feedback and Companion/privacy/firewall behavior.
