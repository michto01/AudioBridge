# Device compatibility and channel semantics

## Supported contract

Audio Bridge routes between two independently chosen Core Audio endpoints exposing PCM input/output streams. Compatibility is determined by runtime capability probing, not vendor name or USB class. No device-specific SDK or network-audio protocol is required.

## V1 channel semantics

[ADR-002](decisions/ADR-002-stereo-mix-and-fanout.md) supersedes the original two-lane restriction. Any explicitly patched physical channels on one input UID mix into stereo (N×2). A stereo AU/drift path feeds one output UID, with L or R copied to any number of physical outputs; L+R is explicit and can clip. Mono (1×2) and stereo (2×2) presets are simple defaults. Physical indices are never implicitly renumbered, including non-contiguous aggregate indices. Missing patches remain visible/actionable.

The current implementation supports validated native packed Float32 multi-stream interleaved/planar layouts at equal current device rates; other PCM and same-device duplex remain unfinished. Aggregate subdevice clocks/drift settings belong to macOS and the operator; app-level drift compensates between the selected endpoints, not each subdevice. Best-effort eligibility is not a hardware compatibility claim.

## Capability discovery

Query input/output scope, persistent UID, device name, transport, channel count and layout, stream format(s), nominal sample rates, buffer frame ranges, liveness, and relevant property listeners. Validate actual format support before starting. Distinguish unsupported format from absent device and missing permission.

## Format and clock policy

Prefer 48 kHz for live production but do not require it. Never force a global device rate change without an explicit documented policy. Convert supported PCM formats to an internal float processing format. Independent clock domains require adaptive drift compensation, including equal nominal rates. Treat unsupported encoded or proprietary streams as out of scope.

## Compatibility tiers

- **Primary validation:** built-in input/output, class-compliant USB interfaces, independent USB-to-built-in combinations.
- **Additional validation:** Thunderbolt and virtual PCM devices.
- **Best effort:** Bluetooth, AirPlay, aggregate/multi-output devices, devices with dynamic layouts or extreme latency.

## Required test matrix

Test different vendors, rates (44.1/48 kHz when available), interleaved/non-interleaved formats, mono/stereo/multichannel layouts, input/output device changes, default-device changes, UID persistence, sleep/wake, and 12-hour drift/soak tests. Record the actual device models and macOS versions; do not generalize one hardware pass to all devices.

## Example deployment (non-normative)

TightAV Dante USB 2×2 (class-compliant Core Audio input) → Audio Bridge → Mac 3.5 mm or external USB output → ATEM Mini analog input. No Dante, TightAV, or ATEM code should appear in the core engine.
