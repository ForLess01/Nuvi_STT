# Repeated PTT Native Ducking

## Objective

Keep native VPIO ducking functional while preventing a repeated push-to-talk (PTT) capture from starting over a native audio unit whose teardown has not completed.

## Problem and evidence

The native lifecycle quarantines a unit when stop, uninitialize, dispose, or route-listener cleanup fails. The first failure-injection test proved that unresolved stop/uninitialize/dispose errors could be retried while a second VPIO capture was attempted, and that the previous retry path did not retry a failed stop. A follow-up review found the initial fix's blanket `entries.isEmpty` admission gate was too broad: a failed route-listener removal can retain an inactive listener registration after the AudioUnit itself is disposed, unnecessarily blocking later captures, including HAL. The bounded correction now distinguishes unresolved AudioUnit teardown from a disposed unit retained only for listener cleanup. These tests establish lifecycle admission behavior under injected failures; they do not prove audible attenuation or a wedged CoreAudio service.

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
3. A new native capture is refused while a quarantined AudioUnit is not disposed; a disposed unit retained only for failed listener removal does not block a later capture while quarantine capacity remains.
4. Existing enabled VPIO ducking behavior and HAL behavior when ducking is disabled remain covered by the existing suite.
5. The opt-in native probe attempts two sequential capture/stop cycles using the same service instance while continuing to avoid permission prompts and global volume/mute writes.
6. No physical audio validation is claimed; manual music/PTT QA remains pending for the user.

## Tasks

- [ ] **T1 — Prove and fix unresolved native teardown overlap.** Add the failure-injection regression first, run it against baseline and record RED, implement the lifecycle/quarantine fix, extend the opt-in hardware probe to two sequential cycles, then run the regression GREEN and required checks. Route: delegated. Acceptance: criteria 1–6. Work-unit commit: `bbe842e03d2cee5217dc05f16d30052b84ec9e05` (`fix(audio): prevent VPIO overlap after failed cleanup`). Implementation and focused tests passed; full-suite signal-5 and user-owned live QA remain pending.
- [ ] **T2 — Allow capture after disposed-unit listener cleanup failure.** Add a regression first for failed route-listener removal after AudioUnit disposal, observe RED, then allow admission only when quarantined AudioUnits are disposed and capacity remains; preserve blocking for unresolved native teardown. Run focused/backend/full tests, release build, and diff check. Route: delegated correction. Acceptance: criterion 3 and preservation of criteria 1–6. Rollback boundary: reverting only T2 restores the previous blanket admission gate while retaining T1's stop retry and unresolved-teardown protection. Work-unit commit: `2fd878474c4b2c103758f7deb2a3f510008caa26` (`fix(audio): admit capture after disposed listener failures`).

## Verification

- Targeted regression: `swift test --filter AudioCaptureBackendTests/testRepeatedCaptureWaitsForNativeTeardownAndRetriesStop` (expected RED on baseline, then GREEN after fix).
- Listener-only quarantine regression: `swift test --filter AudioCaptureBackendTests/testDisposedUnitWithFailedListenerRemovalDoesNotBlockNextCapture` (expected RED on the pre-correction candidate, then GREEN after correction).
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
- Initial full `swift test` was partial: after the audio backend suite passed, `xctest` exited with signal code 5 at `SpeechAnalyzerEngineTests/testAnalyzerInputQueueCountsDropsAndPreservesOldestSlices`; the same filtered test also exited with signal code 5, while the sibling locale-only test passed. The parent later confirmed the same failure on baseline `f812d32`; the unrelated SpeechAnalyzer failure remains outside this change.
- `git diff --check` passed.
- Work-unit commit: `bbe842e03d2cee5217dc05f16d30052b84ec9e05` (`fix(audio): prevent VPIO overlap after failed cleanup`) on `codex/repeated-ptt-ducking`.
- Engram mirror remains pending because multiple active runtime sessions matched and no authoritative session ID was available. Physical music/PTT QA remains user-owned and unrun.
- Follow-up candidate RED observed before the correction: `swift test --filter AudioCaptureBackendTests/testDisposedUnitWithFailedListenerRemovalDoesNotBlockNextCapture` failed because a VPIO whose AudioUnit had disposed successfully but retained five failed listener removals caused a subsequent HAL factory call to throw `microphoneUnavailable("Native audio cleanup capacity is temporarily exhausted")`.
- Follow-up correction: quarantine admission now rejects only snapshots containing an undisposed AudioUnit, retains the existing entry-count capacity bound, and rechecks snapshot identity before reserving a slot. Lifecycle state is inspected outside the quarantine lock to avoid reversing the lifecycle-to-quarantine lock order.
- Follow-up focused regressions GREEN: `swift test --filter 'AudioCaptureBackendTests/(testDisposedUnitWithFailedListenerRemovalDoesNotBlockNextCapture|testRepeatedCaptureWaitsForNativeTeardownAndRetriesStop)'` passed (2 tests, 0 failures). `swift test --filter AudioCaptureBackendTests` passed (21 tests, 0 failures).
- Follow-up full `swift test` remains partial: XCTest exited with signal code 5 at `SpeechAnalyzerEngineTests/testAnalyzerInputQueueCountsDropsAndPreservesOldestSlices`. The parent independently confirmed this same failure on baseline `f812d32`. The verifier's separate HistoryMenu failure was not reproduced: `HistoryMenuTests` passed 16/16 on the candidate and 16/16 on a local source archive of baseline `f812d32` with package resolution and update disabled.
- Follow-up `swift build -c release` passed (`Build complete!`); this run did not reproduce the verifier's reported `dsymutil` permission failure. `git diff --check` passed after the task-document update.
- Follow-up probe guard: `NUVI_RUN_NATIVE_DUCKING_PROBE=0 swift test --filter NativeAudioDuckingProbeTests/testPreauthorizedNativeDuckingCaptureDeliversFrames` skipped before any permission access (1 skipped, 0 failures). Physical probe remains unrun.
- Follow-up work-unit commit: `2fd878474c4b2c103758f7deb2a3f510008caa26` (`fix(audio): admit capture after disposed listener failures`) on `codex/repeated-ptt-ducking`. Native audio probe remains unrun, and manual music/PTT QA remains user-owned.

## Next step

Obtain the parent’s committed-range assessment and independent review of T2. Keep the task partial because the full-suite command still exits with the baseline-confirmed SpeechAnalyzer signal-5 failure and live audio QA remains user-owned.

## Relevant files

- `Sources/Nuvi/Infrastructure/Audio/AudioCaptureBackend.swift` — VPIO lifecycle, cleanup retries, and quarantine admission.
- `Tests/NuviTests/AudioCaptureBackendTests.swift` — injected native-operation lifecycle tests.
- `Tests/NuviTests/NativeAudioDuckingProbeTests.swift` — opt-in hardware probe now exercises two sequential captures without requesting permission.
- `odd/tasks/repeated-ptt-ducking.md` — durable task/progress record.
