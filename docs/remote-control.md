# Remote status and control

The listeners are opt-in in Settings → Remote and use native Apple Network and Security frameworks. No external Swift package is required.

HTTP and OSC each have one independent on/off switch and a status label. Configuration edits save automatically; switch a service off and on to apply edits to that listener. Starting or stopping one service does not stop the other.

## HTTP API

Default listener: TCP port 8765. Requests use a random bearer token stored in the macOS Keychain:

```http
Authorization: Bearer <token>
```

`GET /api/v1/status` returns JSON with app/version, current status, running and requested flags, selected human-readable input/output names, input/output peaks as linear amplitudes from 0 to 1+, linked gains in dB, and chain bypass state.

`POST /api/v1/control` accepts JSON commands:

```json
{"command":"start"}
{"command":"stop"}
{"command":"inputGain","decibels":-6.0}
{"command":"outputGain","decibels":0.0}
{"command":"chainBypass","bypassed":true}
```

Example read:

```sh
curl -H 'Authorization: Bearer YOUR_TOKEN' http://AUDIOBRIDGE-MAC:8765/api/v1/status
```

The API returns a conflict with a message when Start is unavailable. Control is limited to existing in-app Start/Stop, gain and whole-chain bypass behavior. It cannot choose devices or alter physical routing patches.

## OSC/UDP

Default input port: UDP 9000. Commands are standard OSC messages:

| Address | Type | Meaning |
|---|---|---|
| `/audiobridge/start` | no arguments | Start selected route |
| `/audiobridge/stop` | no arguments | Stop and suppress recovery |
| `/audiobridge/input/gain` | `,f` | Input trim in dB |
| `/audiobridge/output/gain` | `,f` | Output gain in dB |
| `/audiobridge/effects/bypass` | `,i` (0 or 1) | Set whole-chain bypass |

Incoming OSC commands are dropped unless the exact source IP is in the comma separated allowlist. To send status into Companion's OSC listener, configure its Mac address and receive port in Audio Bridge. It sends these messages every second:

| Address | Type | Meaning |
|---|---|---|
| `/audiobridge/status` | `,s` | Human-readable local routing state |
| `/audiobridge/running` | `,i` | 1 only when routing is primed with fresh input/output callbacks |
| `/audiobridge/input/left` | `,f` | Input Mix L linear peak |
| `/audiobridge/input/right` | `,f` | Input Mix R linear peak |
| `/audiobridge/output/left` | `,f` | Output L linear peak |
| `/audiobridge/output/right` | `,f` | Output R linear peak |

## Network safety and limits

Both listeners bind for network access when explicitly enabled. The HTTP API uses bearer authentication but currently has no TLS; token and command traffic are visible to a network observer. OSC itself has no authentication or encryption; the source IP allowlist reduces which peers can command the app but is not cryptographic identity. Use a trusted, isolated production LAN, keep macOS Firewall enabled as appropriate, and do not forward these ports to the public internet. The first outgoing OSC report may trigger macOS Local Network privacy approval. No audio samples, recordings, plugin state or device UIDs are exposed.

The HTTP parser accepts one bounded request per connection (16 KiB maximum) and closes the connection after the response. Companion polling interval and meter smoothing should be adjusted on the Companion side; OSC meter reports are sampled once per second and are for status/automation, not precision metering.

## Acceptance status

Source compiled locally, but no HTTP/OSC packet, Companion integration, firewall/privacy prompt or remote control was exercised. See `docs/ui-remote-control-results.md`.
