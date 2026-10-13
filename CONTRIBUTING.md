# Contributing to Audio Bridge

## Before changing code

Read the [product contract](docs/overview.md), [architecture](docs/architecture.md), [accepted decisions](docs/decisions/README.md) and [current review gates](docs/plan.md). Keep changes focused. Propose an ADR for changes to endpoint identity, processing order, recovery, permissions, remote access or callback ownership.

## Development workflow

Use macOS with Xcode/Apple SDK tools; SwiftPM and the Makefile are canonical.

```sh
make doctor
make build
make test
make BUILD_CONFIGURATION=release sign
make verify
```

Use a separate `DIST_DIR` if the app is running or storage metadata prevents signing. Do not overwrite an active app/helper pair. See [build instructions](docs/build.md).

Add deterministic tests for changed routing, gain, queue, resampler, parser and supervisor behavior. Describe real device/plugin checks separately from simulations. For each pull request, explain the change, its reason, commands actually run and remaining limitations. Documentation-only changes need link/path checks; don't imply audio tests were run.

## Realtime rules

- HAL callbacks must not allocate, block, log synchronously, enter SwiftUI, await actors, query device properties or invoke plugins.
- Preallocate C storage and preserve single-producer/single-consumer queue ownership and publication fences.
- Confirm callback detach and in-flight quiescence before freeing resources; uncertain teardown retains memory and requires restart.
- Keep UID and physical-channel selection explicit. Never replace a missing device with a system default.
- Preserve manual Stop precedence and the local re-arm latch. Silence and clipping are not device-failure alarms.
- Benchmark bounded component changes before drawing CPU or deadline conclusions. Never remove safety checks solely for performance.

## Reporting an issue

Include macOS/architecture, app version/build, reproduction steps, expected/observed behavior, input/output devices, sample rate, interface buffers, FIFO reserve and effect/block settings. Attach a sanitized **Diagnostics → Copy Status** report when relevant. Remove bearer tokens and any identifiers you do not want public; do not attach audio, plugin state or licensing credentials.

For UI reports, include language, system appearance and a screenshot. For delivery problems, compare equal windows with DSP off, an empty chain, individual effects and the full chain. Bypass still renders plugins; it is not a DSP-off comparison.

## License and dependencies

Contributions are made under the project's [MIT license](LICENSE). Prefer Apple SDK capabilities. A new dependency proposal must explain why those are insufficient, its license and maintenance implications. Do not copy vendor DSP or translation catalogs without checking their license/provenance.
