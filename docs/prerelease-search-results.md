# Prerelease acceptance and effect search — 0.6.4 / build 37

## Operator acceptance — 2026-10-13

The operator reports that scrolling noise now seems acceptable, the running setup has zero drops/underruns/overruns, and English/Czech UI looks acceptable. Device-loss behavior was checked partially and is sufficient for their present use case. Exact build, duration, hardware and chain configuration were not supplied with this acceptance; retain the prior detailed hardware snapshots separately. This is operator evidence, not an agent-executed or timed 12-hour test. Wider driver/plugin compatibility, full fault coverage and unattended deployment gates remain open.

The operator explicitly authorized the previously deferred automated checks. No live app restart, plugin instantiation, hardware audio test or recording was performed here. The existing running bundle was not replaced.

## Effect navigation

Add effect opens a focused search field and a scrollable list of cached registry names. Matching accepts partial words, ignores case and accents, and requires every query word to appear in the supplied display name, in any order. For example, `analog comp` narrows manufacturer/effect names together. Empty/whitespace search displays the full cached catalog. Clear search restores it; Escape closes the picker. Selecting a result closes the picker and uses the existing add/editor workflow. Chain limits and editing eligibility are checked at selection time.

Searching reads metadata only: it performs no scan, plugin instantiation or audio operation. Rescan remains the explicit catalog refresh. Registry display names remain unmodified; English/Czech search, clear and empty-result labels are provided. Search matching has two unit tests for empty/whitespace, partial names, multiword queries, case, accents and no-match behavior. No package dependency was added. Manual picker layout/keyboard acceptance remains pending.

## Automated checks and corrections

The first test build failed on an existing routing fixture calling a nonexistent `UnsafeMutableAudioBufferListPointer.allocate`. Use the existing SDK `AudioBufferList.allocate` API and explicitly set one buffer. The next run executed 58 tests with two assertions failing in a stale fallback expectation: the approved implementation requests a 64-frame fallback, while the test still expected 128. The corrected test now describes/asserts 64 without changing device behavior.

Added three helper transport tests covering capture publication, output-space release and shutdown against a worker wait. Each repeats 32 times to exercise natural ordering; timeouts fail the test, and mappings are never freed before worker exit. These checks do not force every arm/fence interleaving, inject EINTR or prove all callback/plugin lifetime races. Existing suite also checks FIFO wrap/overflow/starvation, source conservation, FIR demand/history, simulated drift convergence, matrix/gain, reporting and recovery policy. Live renderer adoption/retirement, actual HAL teardown and plugin scheduling remain separate checks.

Release `make sign BUILD_CONFIGURATION=release DIST_DIR=/tmp/AudioBridge-0.6.4-final` passed with external scratch/module caches and `--disable-sandbox`; build completed in 15.03 seconds. Packaging, plist lint and strict ad-hoc helper/app signing passed. `make verify` passed: `cz.bytelab.audiobridge`, 0.6.4/build 37, minimum macOS 14, AudioBridge.icns, matching executable/bundle metadata, both language tables and helper/app signatures. Translation plist lint and `git diff --check` passed. No `make run`, distribution signing, notarization or publishing was performed.

Final `make test SWIFT_BUILD_OPTIONS=--disable-sandbox` passed on the final sources: **61 XCTest tests, zero failures**, in 0.317 seconds after compilation. The preceding corrected run also passed 61 tests. Logs are `/tmp/audiobridge-0.6.4-tests-final.log` (final) and `/tmp/audiobridge-0.6.4-tests.log` (preceding). Build/signature checks do not establish physical audio quality or close the unattended reliability gate.
