# Device compatibility and channel semantics

## Supported contract

Audio Bridge routes between two independently chosen Core Audio endpoints exposing PCM input/output streams. Compatibility is determined by runtime capability probing, not vendor name or USB class. No device-specific SDK or network-audio protocol is required.

## V1 channel semantics

Two logical input lanes (`in1`, `in2`) and two logical output lanes (`out1`, `out2`) are bound to explicitly selected device channel indices. A 2×2 matrix mixes logical lanes. A multi-channel interface can be used by selecting two channels; the remaining channels are untouched where device I/O permits. If a device is mono, expose a clearly labelled mono duplication option, or explain why the selected route cannot run. No implicit channel remapping.

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
