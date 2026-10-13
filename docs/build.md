# Build, package and publish

## Toolchain and public commands

macOS with Xcode/Apple SDK tools, Swift 5.9+, SwiftPM deployment minimum macOS 14. Recent local checks used Swift 6.4/macOS 27 SDK on arm64; macOS 14 and Intel runtime acceptance remain separate. No Xcode project or external Swift package dependency.

| Command | Action |
|---|---|
| `make doctor` | Print selected Xcode, Swift and macOS SDK |
| `make build` | SwiftPM build; debug by default |
| `make test` | Automated tests with isolated temporary scratch storage |
| `make probe` | Read-only Core Audio catalog CLI; its permission context is not the app's |
| `make app` | Build and assemble `.app` |
| `make sign` | Build/package, ad-hoc sign helper/host and verify |
| `make verify` | Check existing app identity/resources/embedded plist and signatures |
| `make run` | Sign, register with Launch Services and open app |
| `make release` | Release sign/verify, ZIP and SHA-256 checksum |
| `make clean` | Clean SwiftPM products; retain distribution artifacts |

Use release optimization for operator/CPU checks:

```sh
make doctor
make BUILD_CONFIGURATION=release sign
make verify
make BUILD_CONFIGURATION=release run
```

`DIST_DIR=dist` by default; bundle is `dist/AudioBridge.app`. Quit the destination app before rebuilding: packaging refuses running, unrelated or symlink app destinations. App/helper shared-memory protocol versions must match. Opening a new path doesn't replace an old process automatically.

Bundle identity is `cz.bytelab.audiobridge`, executable `AudioBridge`, `LSUIElement=true`, minimum 14.0, with microphone/local-network usage descriptions. `Resources/Info.plist` is also embedded in the executable; verification compares both. Packaging creates `AudioBridge.icns` from the source PNG, bundles language resources and the AU worker, then signs the complete pair. Development signatures have no TeamIdentifier/notarization.

## File Provider and signatures

Some File Provider/iCloud-managed paths reattach `com.apple.FinderInfo` to `.app` folders, causing strict signature failure even after removal. A `.nosync` parent or ignore attribute has not been demonstrated to prevent that on this development machine. This is a storage limitation, not a failed Swift compilation.

Use local output outside provider-managed storage:

```sh
make BUILD_CONFIGURATION=release DIST_DIR=/tmp/AudioBridge-local sign
make DIST_DIR=/tmp/AudioBridge-local verify
make BUILD_CONFIGURATION=release DIST_DIR=/tmp/AudioBridge-local run
```

A local directory behind a `dist` symlink can preserve commands, but relocation is an operator choice, not performed by these scripts. Temporary builds are disposable; install verified bundles at a stable Applications path for login use. Scripts remove only signing-invalid FinderInfo/ResourceFork attributes and preserve quarantine/other attributes. They don't disable iCloud or reset permissions.

Stock Bash 3.2 empty-array handling is supported even when `SWIFT_BUILD_OPTIONS` is empty. For development sandboxes/cache restrictions, the existing override can be used when necessary:

```sh
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/audiobridge-swift-module-cache \
make BUILD_CONFIGURATION=release DIST_DIR=/tmp/AudioBridge-local sign \
  SWIFT_BUILD_OPTIONS='--disable-sandbox --scratch-path /tmp/audiobridge-build'
```

Build options are a whitespace-separated argument list, not shell code; paths containing spaces inside that variable are not a supported quoting format. No `eval` is used.

## GitHub publishing

Keep generated `.build/`, `dist/` and `.diagnostics/` out of commits. Preserve scoped source history and accepted ADRs. Configure your own Git remote; no repository/account URL is assumed by this guide.

CI is configured for pushes to `main` and pull requests on macOS 14. Releases can be created manually on GitHub with the ZIP/checksum from `make release`. Alternatively, manually run `.github/workflows/release.yml` with a `vX.Y.Z` tag selected: it builds/tests/packages, requires the tag to match `CFBundleShortVersionString`, then publishes the ZIP/checksum. Pushing a tag does not automatically publish a release. Clean-install results are not established by local packaging.

```sh
make release
# After review, with origin configured and the bundle version matching:
git push origin main
git tag -a v0.7.2 -m 'Audio Bridge 0.7.2'
git push origin v0.7.2
```

The current workflow creates a regular GitHub release, not a prerelease automatically. Change that policy deliberately before publishing development tags if desired. No push, tag or release is performed by documentation updates. See [compliance](compliance.md) and [ADR-007](decisions/ADR-007-build-and-distribution.md).
