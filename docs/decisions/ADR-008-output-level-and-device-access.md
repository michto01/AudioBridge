# ADR-008: Device volume first and optional exclusive access

Status: Accepted operator changes, 2026-10-12; consolidated 2026-10-13.

## Context

While exclusive access is held, system controls may no longer adjust the selected output. Requiring both hardware volume and independent digital output gain creates unnecessary operator complexity; device support varies.

## Decision

- Retain linked smooth input trim. Prefer the explicitly selected output's writable Core Audio master volume; hold applied digital gain at 0 dB in that mode. Persist saved fallback gain for devices without writable volume. Never change hardware volume just by entering that mode.
- Resolve UID afresh and perform narrow property operations outside callbacks. Verify readback, expose driver rounding/errors and preserve current mode through same-device capability checks. Start waits for unresolved capability checks.
- Bridge shows device volume or −60 to +12 dB digital fallback; menu exposes hardware volume only. Output meters are upstream of hardware volume. Remote outputGain is accepted only in fallback mode.
- Optional exclusive access is off by default. Request/recheck driver hog ownership for both explicit devices before IOProc registration; identify unsupported/busy endpoints and roll back partial acquisition. Release only after callback detach; retain unsafe context instead of claiming release.

## Consequences and alternatives

Hog mode is a driver-mediated request, not a system-wide guarantee. Volume may affect other clients and quantize. Unity digital gain doesn't repair capture/mix/plugin clipping; attenuation can't undo already clipped input. Removing redundant gain is a usability choice, not evidence it caused audible artifacts. Don't synthesize writable hardware volume or change system defaults.

## Acceptance

Verify shared/exclusive ownership with competing apps and stated drivers, partial acquisition/release, writable/read-only/absent volume, saved fallback/same-device refresh and remote rejection. Check safe audible levels separately from software meters ([testing](../testing.md)).
