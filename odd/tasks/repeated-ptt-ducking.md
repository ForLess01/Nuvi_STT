# Repeated PTT Native Ducking

## Objective

Keep native VPIO ducking functional while preventing a repeated push-to-talk (PTT) capture from starting over a native audio unit whose teardown has not completed.

## Problem and evidence

The current native lifecycle quarantines a unit when stop, uninitialize, dispose, or route-listener cleanup fails. `NativeAudioUnitFailureQuarantine.acquireCaptureSlot()` retries quarantined units, but currently allows another capture whenever the quarantine is below its capacity. Also, a cleanup retry skips `stop()` once lifecycle state is `disposePending`, even when the earlier stop and uninitialize attempts both failed. These are source-level candidate causes for overlapping native capture/ducking lifecycles; injected failure tests must demonstrate the regressions before source changes.

This repository baseline is `f812d32` (`v2.2.0`, build 5 metadata); the worktree was clean on `main` before branching. Existing unit tests can inject native lifecycle failures, but they cannot prove real CoreAudio teardown behavior or audible attenuation. Physical PTT/music validation remains with the user.

## Scope and constraints

- Preserve functional VPIO ducking when `AudioCaptureConfiguration.duckOtherAudio` is enabled; do not remove the preference or substitute hardware-volume/mute writes.
- Change only native capture lifecycle handling, its regression tests, the opt-in two-cycle native probe, and this task document unless test evidence demonstrates another required file.
- No installed-app changes, app launch, microphone permission request, physical audio/PTT test, coreaudiod action, system volume/mute change, remote access, push, publication, or PR.
- Feature branch: `codex/repeated-ptt-ducking`.
- Route: delegated direct implementation (writer owns source/test preparation; parent supplied the initial lifecycle map). No SDD artifacts.
- TDD: no current strict-TDD setting was found in repository configuration; apply observed test-first RED/GREEN. Test runner: Swift Package Manager (`swift test`).
- Delivery strategy: `ask-on-risk` default. Forecast is below 400 authored changed lines; reassess from the final diff before any delivery planning.

## Acceptance criteria

1. A regression test fails on the unmodified baseline when native teardown remains unresolved and a second native capture is attempted.
2. Quarantined cleanup retries the failed stop in correct teardown order while stop and uninitialize remain unresolved.
3. A new native capture is refused until the previous quarantined native lifecycle is fully released; a fully cleaned lifecycle permits a later capture.
4. Existing enabled VPIO ducking behavior and HAL behavior when ducking is disabled remain covered by the existing suite.
5. The opt-in native probe attempts two sequential capture/stop cycles using the same service instance while continuing to avoid permission prompts and global volume/mute writes.
6. No physical audio validation is claimed; manual music/PTT QA remains pending for the user.

## Tasks

- [ ] **T1 — Prove and fix unresolved native teardown overlap.** Add the failure-injection regression first, run it against baseline and record RED, implement the smallest lifecycle/quarantine fix, extend the opt-in hardware probe to two sequential cycles, then run the regression GREEN and all required checks. Route: delegated. Acceptance: criteria 1–6. Estimated authored delta: under 400 lines. Commit and evidence: pending.

## Verification

- Targeted regression: `swift test --filter AudioCaptureBackendTests/testRepeatedCaptureWaitsForNativeTeardownAndRetriesStop` (expected RED on baseline, then GREEN after fix).
- Probe guard check: `swift test --filter NativeAudioDuckingProbeTests/testPreauthorizedNativeDuckingCaptureDeliversFrames` without `NUVI_RUN_NATIVE_DUCKING_PROBE=1`; expected to skip before permission access. Never enable this variable in this environment.
- Full tests: `swift test`.
- Release build: `swift build -c release`.
- Whitespace validation: `git diff --check`.
- Runtime harness: `N/A` for this environment; do not request microphone permission or exercise physical audio. User-owned manual music/PTT QA is pending.

## Progress

- Initial source map and graph query identify the native lifecycle/quarantine and existing injected native-operation test doubles.
- Engram mirror is pending: the save was rejected because multiple active runtime sessions match this project/worktree, and no authoritative session ID is available.
- Baseline RED observed before production edits: `swift test --filter AudioCaptureBackendTests/testRepeatedCaptureWaitsForNativeTeardownAndRetriesStop` failed with 6 assertions. It created a second VPIO despite the first unit's stop/uninitialize/dispose failures, did not retry `stop()` from quarantine (`stopCount` stayed 1), and could not later report cleanup success because the initial stop error remained.
- Implemented: quarantine admission now blocks a new capture while any native lifecycle remains in quarantine, and retries `stop()` after a failed uninitialize but before retrying uninitialize/dispose. The opt-in native probe loops over two sequential start/stop cycles on one service instance.
- Targeted regression GREEN: `swift test --filter AudioCaptureBackendTests/testRepeatedCaptureWaitsForNativeTeardownAndRetriesStop` passed (1 test, 0 failures). It verifies the pending teardown blocks creation, retries stop, permits capture after cleanup, and leaves enabled VPIO selection intact.
- `swift test --filter AudioCaptureBackendTests` passed (20 tests, 0 failures).
- `swift build -c release` passed; it emitted existing Swift 6 implicit-strong-capture warnings in `ModelDownloadService.swift`, `TranslationCoordinator.swift`, and `FerrofluidMicProbe.swift`.
- Unarmed probe guard: `NUVI_RUN_NATIVE_DUCKING_PROBE=0 swift test --filter NativeAudioDuckingProbeTests/testPreauthorizedNativeDuckingCaptureDeliversFrames` skipped before permission access (1 skipped, 0 failures). The real probe was not run.
- Full `swift test` is partial: after the audio backend suite passed, `xctest` exited with signal code 5 at `SpeechAnalyzerEngineTests/testAnalyzerInputQueueCountsDropsAndPreservesOldestSlices`; the same filtered test also exited with signal code 5, while the sibling locale-only test passed. This test/source is unchanged by this feature; cause and baseline behavior are unverified.
- `git diff --check` passed.
- Commit and Engram mirror: pending. Physical music/PTT QA remains user-owned and unrun.

## Next step

Review the final diff, run the required native assessment/review gates, and complete the work-unit commit if they permit. Report the full-suite signal-5 failure as unresolved; do not claim physical attenuation or live audio validation.

## Relevant files

- `Sources/Nuvi/Infrastructure/Audio/AudioCaptureBackend.swift` — VPIO lifecycle, cleanup retries, and quarantine admission.
- `Tests/NuviTests/AudioCaptureBackendTests.swift` — injected native-operation lifecycle tests.
- `Tests/NuviTests/NativeAudioDuckingProbeTests.swift` — opt-in hardware probe now exercises two sequential captures without requesting permission.
- `odd/tasks/repeated-ptt-ducking.md` — durable task/progress record.
