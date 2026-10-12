# Overview — Audio Bridge

Current 0.6 amendment: [ADR-003](decisions/ADR-003-reliability-and-operator-setup.md) supersedes automatic re-arming after device loss/identity/format/buffer changes or confirmed callback stalls. Simple/Expert setup and English/Czech UI are described there. Operational acceptance remains pending.


## Problem

Audio Bridge is a universal native macOS utility for unattended routing between independently selected Core Audio input and output devices, which may use different hardware clocks. Version 1 supports N physical inputs mixed into stereo, a stereo AU/drift path and L/R fan-out within one selected output device (ADR-002). Built-in, USB, Thunderbolt, and virtual PCM devices are eligible based on capabilities; no hardware brand or transport is required.

## Product outcome

A small, reliable, native macOS menu-bar utility with no cloud dependency and no general-purpose mixing-console complexity. It must show whether routing is configured, running, degraded, waiting or deliberately stopped, and it must restore service automatically after recoverable device failures.

## Locked requirements

| ID | Requirement |
|---|---|
| P-01 | macOS 14+ native SwiftUI, Apple Silicon primary; Intel support desirable if CI supports it. |
| P-02 | Separate Core Audio input and output selection, persisted by device UID. |
| P-03 | Never substitute a missing device with the system default. |
| P-04 | Auto-launch at user login and auto-start when configured devices are available. |
| P-05 | Manual Stop suppresses recovery and auto-start until user explicitly starts again; persistence across app relaunch is specified in design. |
| P-06 | Recover indefinitely from recoverable device loss with bounded retry intervals. |
| P-07 | N×2 input matrix with mono/stereo defaults and smooth changes; stereo processing and physical output fan-out (ADR-002). |
| P-08 | Output gain, input/output peak meters and clipping/overrun/underrun counters. |
| P-09 | No silence alerts or notifications; silence is an informational meter condition only. |
| P-10 | Menu-bar popover and separate settings window; closing windows does not stop routing. |
| P-11 | Preferred 48 kHz, device format negotiation and independent clock compensation. |
| P-12 | CLI-first build via SwiftPM and Makefile; package a real `.app`. |
| P-13 | Free self-managed GitHub distribution via ad-hoc signing; notarization optional later. |

## Non-goals for v1

Built-in EQ, compressor, limiter (installed AU hosting is explicitly authorized), audio recording, network-audio protocol stacks, vendor-specific device APIs, arbitrary multichannel effects or independently opened multiple output devices, remote control, unattended system-daemon operation, automatic switching to alternate outputs, and a paid signing dependency.

## Operating constraints

- The application runs in an active macOS user session. It is not guaranteed to run at the login screen or across system reboot without login.
- A green status indicates healthy local callbacks and buffer state, **not** upstream signal delivery or downstream device reception.
- External analog equipment requires separate input-sensitivity and output-level calibration; the bridge does not control downstream equipment.
- An application cannot guarantee audio continuity across host sleep, system restart, USB hardware failure or power loss. A dedicated hardware signal path may be more fault-tolerant when absolute continuity is required.

## Product success criteria

- Operator can configure devices and matrix once and thereafter run with no UI interaction.
- Correct channel routing, no sustained drift or buffer growth, bounded audio latency, and no unhandled failures in an extended test.
- Recover after unplug/replug of either device without accidentally switching to other audio hardware.
- Full installation, launch, permission, login and recovery workflows tested from the packaged `.app` (not only `swift run`).

## Open decisions

- Exact matrix coefficient range and normalization/headroom policy: 0.0–2.0 per coefficient, 1.0 is unity (legacy duplicate-input sums may exceed 1), with optional future signed/negative coefficients. Explicit mono/stereo presets.
- Positive digital gain: provisionally cap at +12 dB; protect against clipping through indication, not a hidden limiter.
- Latency profiles: Low, Balanced (default), Robust; exact buffer sizes determined by device measurements.
- User-initiated Stop: recommended persisted `desiredRouting=false` across relaunch; explicit auto-start preference is only applied on first setup or when desired state is enabled. Document and test this carefully.

## Product boundary

The app works with compatible Core Audio PCM input/output devices regardless of their transport or brand. TightAV Dante USB to Mac headphones to ATEM Mini is a validation scenario, not a product dependency. See `device-compatibility.md`.
