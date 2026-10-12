# Real-time scheduling and display load — 0.5.9 / build 32

## Evidence

The operator reports approximately 45% of one core, startup lag, increased
underruns with effect processing enabled, and delay estimates increasing from
5–6 to 10–12 ms even after disabling DSP. These observations were not reproduced
with the new implementation. A read-only process snapshot of build 31 showed
37.5% main-app CPU and no AU helper at that moment. A three-second stack sample
showed substantial main-thread RenderBox/Core Animation/SwiftUI activity; sampled
HAL threads were mostly waiting. This is a candidate for display optimization,
not a precise CPU attribution, sustained benchmark or audio-quality result.

The FIFO value 1024 is the plan's minimum allocated capacity, calculated as the
next power of two at or above `max(1024, 2 × reserve, 4 × largest device buffer)`.
The chosen reserve remains separate. A direct route has one queue; an AU route
has capture and ready queues with that capacity each. Empty storage is not
added to signal delay. The conserved pending-source count includes accepted
capture not consumed/discarded across the AU path, without summing capacity or
double-counting the in-flight block.

## Implemented changes

- Replace quarter-block `usleep` polling with a precreated named semaphore.
  The helper arms then rechecks full-block input/output-space availability.
  Publication and arm fences prevent a store/load race from losing a wake.
  An atomic claim coalesces signals, and every claimed signal is consumed before
  the next wait. Capture and source-consumption callbacks issue a non-waiting
  `sem_post` only when the armed helper can proceed. No callback waits, allocates
  semaphore resources, acquires a userspace mutex or performs plugin setup.
  Shutdown also wakes an armed worker. Names are unlinked after readiness; each
  process retains its opened semaphore until its mapping closes.
- Request Mach `THREAD_TIME_CONSTRAINT_POLICY` once on the dedicated render
  thread: block period/constraint, half-period nominal computation. The Mach
  result is shown in Diagnostics and Copy Status. A failed request retains the
  thread's QoS fallback. Kernel scheduling can still miss deadlines or demote an
  overloaded thread; accepted setup is not continuous verification or audio
  workgroup membership. The render thread publishes readiness after setup,
  before the parent starts HAL.
- Remove the render-driver NSLock. A helper-local lock-free pointer mailbox
  publishes one prepared chain; the render thread adopts it between blocks.
  Main retains both owners until the adoption acknowledgment, then releases the
  retired renderer, including AU deallocation, on the helper main thread.
  Replies wait for adoption. No unbounded retirement queue is introduced.
- Fetch exact resampler input demand once per callback into preallocated
  scratch, instead of issuing queue reads and atomic index publications per
  sample. Shared-ring copying uses at most two contiguous memcpy spans around
  wrap. Mirrored FIR history removes circular indexing in convolution. Existing
  filter coefficients, demand/phase arithmetic, starvation history and PI
  bounds remain unchanged; signal equivalence needs deferred acceptance.
- Retain 5 Hz informational snapshots and 20 Hz health checks. Quantize visible
  meter targets to whole dB and animate a native gradient/mask layer rather than
  SwiftUI Animatable/Canvas draws. This reduces recurring display work; numerical
  diagnostics remain available independently of meter precision.
- Distinguish startup preparation/filling from later refill. Show Filling for
  unprimed delay, and average from the first collected valid sample during the
  initial five-second averaging window. Startup overflows and later lost frames
  remain counted. Ready audio, reserve and allocated per-queue capacity have
  separate diagnostic labels. Direct routing omits irrelevant AU queue rows.
- Wake telemetry now measures signal-to-resume delay, excluding legitimate idle
  waiting; older polling-wait maxima are not directly comparable. Wall block
  time/allowance percentage remains explicitly wall time, not CPU utilization.
  Transport protocol is 6; quit the old process and use the complete new bundle.

Live DSP-off still forwards through the retained helper. It does not flush
queued wet/dry audio. A backlog can therefore keep delay elevated after disabling
effects. Stop and Start with processing off selects the direct bridge. Underrun
counts represent missing output frames and refill silence, even if brief losses
are difficult to hear. The patch does not relabel such losses as harmless.

## Code review

### Overall Assessment

The source preserves single-producer/consumer ownership and existing lifecycle
teardown. New wake and pointer handoff invariants are explicit. Runtime race,
latency and plugin scheduling acceptance remain necessary.

### Prioritized Recommendations

1. Ensure publication/arming cannot both miss each other's stores — corrected
   before the final package using paired sequentially consistent fences.
2. Keep retired processors retained off the render thread until adoption —
   implemented with main-thread owners and an acknowledgment mailbox.
3. Validate wake races, shutdown, short-read equivalence and real-time policy
   behavior before accepting unattended operation — deferred below.

### Detailed Feedback

**Lost wake prevention — Correctness**

Original candidate:
```c
atomic_store_explicit(&s->workerWaiting, true, memory_order_release);
// Recheck queue; publisher separately stores queue index then reads waiting.
```

Implemented correction:
```c
atomic_store_explicit(&s->workerWaiting, true, memory_order_release);
atomic_thread_fence(memory_order_seq_cst);
// Publisher also fences after index publication and before reading waiting.
```

Rationale: release/acquire accesses on distinct atomics alone do not prevent
both threads observing old values. The paired store/load ordering closes that
lost-wake window without spinning or blocking a device callback. This review
used the local Fabric review_code pattern; no external reviewer was invoked.

## Actual checks

- Installed Xcode SDK resolved successfully; Swift 6.4, arm64 host, macOS 27 SDK,
  package deployment minimum macOS 14.0.
- Release `make build` passed for the worker/batching slice (11.34 seconds) and
  native meter/diagnostic slice (15.09 seconds), using isolated temporary build
  and module cache paths.
- Initial release `make sign DIST_DIR=/tmp/AudioBridge-0.5.9` passed (10.76-second
  build, packaging, plist lint and ad-hoc app/helper signatures).
- Final source rebuild passed (9.28 seconds), but packaging into the existing
  `/tmp/AudioBridge-0.5.9` destination correctly refused because that bundle had
  become running. No active executable/helper was overwritten.
- Final `make sign DIST_DIR=/tmp/AudioBridge-0.5.9-final` passed, with an up-to-date
  release build (0.62 seconds), packaging, plist lint and ad-hoc signatures.
- `make verify DIST_DIR=/tmp/AudioBridge-0.5.9-final` passed: identifier
  `cz.bytelab.audiobridge`, version 0.5.9/build 32, macOS 14 minimum, arm64,
  AudioBridge.icns, matching embedded/bundle metadata and valid helper/app
  signatures. `git diff --check` passed.
- Tests, launching the new app, plugin execution, audio comparisons, semaphore
  runtime stress and before/after CPU comparisons were not run. The existing
  app/audio session was not restarted or reconfigured. The short stack sample
  was read-only inspection of the already running build 31.

## Deferred acceptance

Use identical devices/buffers/reserve and equal measurement windows: direct
Start with DSP off; helper forwarding after live DSP-off; empty chain; one
effect; full chain; bypass. Reset diagnostic counters before each interval.
Compare lost frames, pending-source growth, mean block allowance, over-budget
counts, signal-to-wake delay, separate app/helper CPU, and audible continuity.
Check the reported Mach result and settings open/closed/editor open/closed.
Quit any earlier copy before opening
`/tmp/AudioBridge-0.5.9-final/AudioBridge.app`; this is the final reviewed artifact.

Later deterministic/stress checks must cover both sides of arm/publication,
capture readiness, output-space readiness, interrupted waits, shutdown while
armed, coalesced signals, mapping/name cleanup, queue wrap, renderer ownership
through adoption/teardown, starvation during FIR priming/advance, exact source
demand across 0.999/1/1.001 ratios and maximum callback size. Existing tests
remain unrun; no new test source was added in this slice.

Audio workgroups, workload measurement under competing load, per-plugin
attribution, physical latency measurement, lifecycle/sanitizer stress and the
12-hour Phase 5 soak remain outstanding. No zero-underrun or unattended-readiness
claim is made.

Primary guidance: [Apple audio workgroups](https://developer.apple.com/documentation/audiotoolbox/understanding-audio-workgroups)
and [asynchronous audio threads](https://developer.apple.com/documentation/audiotoolbox/adding-asynchronous-real-time-threads-to-audio-workgroups).
The installed SDK's mach/thread_policy.h documents period/computation/constraint
in absolute time units and its preemptible field as ignored; sys/semaphore.h
declares the named semaphore API. No third-party dependency was added.
