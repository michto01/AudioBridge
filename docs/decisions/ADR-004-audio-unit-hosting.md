# ADR-004: Isolated stereo Audio Unit hosting

Status: Accepted behavior, consolidated 2026-10-13 from operator-authorized AU work on 2026-10-11 and continuous-DSP amendment on 2026-10-13. No new DSP scope.

## Context

The operator needs installed third-party compression/EQ/limiting without implementing those processors in the bridge. Plugin render/setup/editor work and crashes must not run inside device callbacks. Live changes need predictable ownership and must preserve the selected route.

## Decision

- Host up to eight ordered installed effects in a separate signed SwiftPM helper, sharing preallocated stereo queues with the host. Effects accept stereo planar Float32 at the route rate; optional buses are disabled. No VST, MIDI, sidechain or multichannel plugin path.
- Persist exact component identity/state. A cached metadata catalog is populated by an isolated background helper and manually rescanned; search reads cache only. Actual load validates availability. Missing/incompatible effects and failed preparation/rendering are explicit faults, never silently substituted or bypassed.
- Cache render/pull/context blocks after allocation. Configure maximum render frames before allocation. Automatic tries half the larger device callback, rounded down within 16–256 and reserve; Expert requests 16–1024 powers of two within reserve. Zero is invalid. No universal safe size or deadline guarantee.
- The asynchronous renderer uses its own AudioWorkInterval workgroup and reports scheduling/join/interval failures. Retain per-block autorelease pools and queue wake fences. Prepare replacements on helper main; adopt via lock-free mailbox between blocks, acknowledge, then retire old owners on main.
- Live editor controls the rendering instance. Closing saves; no live Cancel rollback. Stopped editing uses a separate instance with Save/Cancel. Fit advertised native/legacy editor size within the display and scroll oversized content. Failed/oversized state serialization preserves previous saved state, closes/cleans up and replies exactly once; already changed live parameters aren't rolled back.
- Retain helper transport for every app route, including DSP off. A dry start loads no saved plugins. First enable prepares/adopts them while dry forwarding continues. On/off and bypass use a 20 ms dry/wet ramp without HAL restart or queue flush. DSP off suspends plugin render calls after fade-out; bypass outputs dry but continues rendering for editor feedback. Loaded units remain editable.
- Latency properties refresh outside rendering via dirty notifications/editor-close fallback; legacy units omitting notifications may remain stale while editing.

## Consequences and alternatives

Process isolation contains crashes, not privileges: plugins run with user access and their own licensing/network behavior. Persistent transport adds helper/queue overhead even with DSP off; it replaces earlier direct-start/restart-on-enable behavior. Dry/wet latency is unaligned, histories/tails can change and transitions are not guaranteed inaudible. A silent fallback after requested-chain failure is rejected. Driver/plugin property/teardown calls can still block outside callbacks.

## Acceptance

Test rendering/pull boundaries, queue throughput/wakes, ownership through adoption/teardown, live editing/state failures, DSP switch/bypass, latency notifications and plugin timing at equal settings. Component tests don't establish third-party compatibility; physical and soak checks remain in [testing](../testing.md).
