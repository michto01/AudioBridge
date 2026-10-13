# ADR-007: SwiftPM bundles and explicit development identity

Status: Accepted project baseline, consolidated 2026-10-13. MIT license selected by operator during documentation consolidation.

## Context

A native macOS utility needs real bundle identity, permissions, helper resources and reproducible CLI builds without an Xcode project or paid signing dependency.

## Decision

- SwiftPM is canonical, minimum macOS 14. Makefile exposes doctor/build/test/app/run/sign/verify/release/clean plus the read-only probe. No Xcode project unless a demonstrated limitation is separately approved.
- Stable `cz.bytelab.audiobridge` identity and `AudioBridge` executable. Embed the same Info.plist in the executable and bundle; package microphone/local-network descriptions, LSUIElement, complete source-icon ICNS family, localization resources and matching AU helper. Validate shared protocol/metadata.
- Ad-hoc sign the helper/host as one bundle and strictly verify final output. This isn't Developer ID trust, notarization or stable rebuild identity. TCC may require renewed authorization; don't weaken requirements or reset permissions automatically.
- Refuse unrelated/symlink app destinations and replacing a running bundle. Use stock-compatible shell scripts, quote paths and preserve quarantine; strip only known signing-invalid attributes from generated bundles. Tests use temporary scratch storage. File Provider may reattach metadata; support explicit local DIST_DIR instead of mutating cloud/system settings.
- Release ZIP/checksum via Makefile; GitHub tag workflow validates version before publication. Publishing/install/login registration require deliberate operator action. No credentials/certificates belong in Git.
- MIT covers project source/documentation; Apple tooling and installed plugins retain separate terms. No third-party package dependencies currently. Any addition needs capability rationale, license and maintenance review.

## Consequences and acceptance

Temporary output is disposable, not suitable for SMAppService login registration. A signed bundle in a stable Applications location still needs clean-account/permission/login/Gatekeeper checks. Apple Silicon is primary; Intel/macOS 14 runtime and CI execution remain distinct evidence. Cloud exclusions/symlinks are workstation choices, not app behavior. See [build](../build.md), [compliance](../compliance.md) and [testing](../testing.md).
