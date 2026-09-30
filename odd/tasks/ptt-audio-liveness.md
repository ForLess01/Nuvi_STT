# PTT audio control and recovery liveness

## Objective and authorization

Restore reliable repeated push-to-talk capture and transcription while preserving native VPIO ducking. The user reports that the installed released Nuvi 2.2.1 (6) ducks for one or two seconds, then cancels without transcription, with interface freezes and an apparent recording/canceling loop.

The user authorizes local implementation of this correction, its regression tests, documentation, applicable checks, and Conventional work-unit commits. The user explicitly approved one integrated delivery with a new `size:exception` on 2026-09-30. Each implementation task receives a bounded parent dispatch. Hardware/microphone access, app launch/install, signing/packaging, version changes, remote operations, releases, and Homebrew changes remain excluded. Existing updater and repeated-PTT history must remain unchanged.

- Project: `nuvi_stt`; session: `01a0f024-df5f-7560-a461-01df6d79cc10`.
- Branch: `codex/ptt-audio-liveness`.
- Planning base: `54964b6d1582c58f73cfa75ccb8f771ffff2ebc4`; clean at inspection.
- Recovery mirror: `odd/ptt-audio-liveness/tasks`; repository locator: `odd/tasks/ptt-audio-liveness.md`.

## Evidence and root-class cluster

The installed version and executable were verified by the parent against the released 2.2.1 artifact. The user's physical failure is real reported behavior; its precise hardware/runtime cause is **not yet proven**. Plan the audio control/recovery root cluster rather than removing ducking or patching each UI symptom independently.

| Verified source finding | Consequence to test, not a physical-cause claim |
| --- | --- |
| `AudioCaptureBackend.swift:392–398,421–426,981–1012`: route callbacks ignore addresses and actual route values, then unconditionally request cleanup; registration precedes initialization/start. | Redundant or startup property notifications can terminate otherwise valid capture. |
| `AudioCaptureBackendTests.swift:578–642`: callbacks fire without changed route values and expect disposal. | Existing tests encode the suspected faulty semantic behavior; replacement regressions must distinguish notification from incompatibility. |
| `AudioCaptureBackend.swift:487,789–804,838–855`: three quarantine retries are counted over the lifecycle's entire lifetime; unresolved disposal blocks admission. | A transient stop/dispose failure can exhaust future recovery permanently. |
| `AudioCaptureBackend.swift:774–776` versus `833–835,864–872`: lifecycle-to-quarantine and quarantine-to-lifecycle lock acquisition paths. | Concurrent teardown/pruning can form an inversion; verify ordering with deterministic coordination. |
| `DictationController.swift:510,521,596`: synchronous native start/stop/cancel paths execute on `MainActor`. | Slow native operations can prevent release/cancel/UI events from being processed promptly. |
| `DictationController.swift:390–403`: audio feedback queues tasks without a capture-session identity; the silence timer only checks listening state. | Old feedback/timer work can affect a later session. |

No mapped code automatically restarts after route cleanup. The apparent loop is not proof of an automatic restart mechanism or a hotkey defect. Preserve intended `systemDefined`/`keyDown` hotkey semantics unless a specific failing regression establishes a necessary change.

## Invariants and implementation boundaries

- Preserve VPIO native ducking and explicit unavailable errors; never silently fall back to HAL when ducking is requested.
- No system/output volume, mute, or default-device writes. Preserve input selection, effective route/format/capacity verification, and existing HAL behavior when ducking is disabled.
- Keep native capture operations serialized with no overlapping active or unresolved units. Cancellation must suppress stale results without pretending a blocking native call has been interrupted.
- Keep unsafe callback-owned memory retained until native teardown is safe. Disposed units with listener-removal residue must retain the existing nonblocking admission behavior.
- Keep real-time callback/ring safety and drop policy. Do not expand ordinary render-error policy or add blind automatic retries/restarts.
- Prefer existing injectable native seams and narrowly scoped capture-control/session abstractions. No new audio framework or unrelated updater changes.
- Technical artifacts remain English; extend established localization only if user-visible copy actually changes.

## Delivery, slicing, and verification policy

- Route: **delegated direct**, not SDD. Each implementation unit needs analysis plus nontrivial source/tests; the parent has delegated this bounded planning writer. Sequential ownership is required where units share the backend or controller.
- One slicing pass separates independently testable route semantics, quarantine recovery, and application control/session ownership. Do not split by cosmetic line limits or omit regressions.
- `delivery_strategy: exception-ok`; chain strategy: **not applicable**; new `size:exception`: **explicitly granted** by the user's `si` on 2026-09-30 for this integrated correction. The updater's separate exception is not reused.
- Forecast authored additions plus deletions, including tests/docs: L1 **180–280**, L2 **160–240**, L3 **380–560**, shared planning/progress documentation **100–150**; accumulated **820–1,230**. L3 may exceed the approximately 400-line planning heuristic because its API integration and race regressions form one coherent behavior. This is an estimate, not an acceptance cap.
- The approved integrated delivery keeps the three coherent work-unit boundaries below; it does not authorize remote publication or a PR. Record actual authored counts from subsequent work-unit commits, generated files excluded. Preserve all necessary tests and documentation rather than shrinking code to fit the former budget.
- Effective configured strict TDD: **not enabled**; no explicit project configuration was found. Runner: `swift test`. Regression-first observed RED/GREEN is recorded for L1/L2 below; the same requested evidence remains pending for L3. Sandbox/tool failure is not a behavioral RED.
- RDD: **on/default**, read-only status confirmed by parent. L1 native review is closed as recorded below; L2 candidate risk remains unassessed by this writer and the parent owns its exact committed-range assessment. This bounded writer runs no native review commands. Later parent owns assessment, exact native consent/continuations, and ordinary delivery decisions.
- Checkboxes represent observed outcomes only, never review consent or delivery authority. Every later unit includes a Conventional Commit with its tests/docs, without AI attribution, after its applicable proof and authorized delivery-size resolution.

## Implementation tasks

### L1 — Validate route meaning before terminating capture

- [x] L1: Preserve capture on redundant/compatible startup and active VPIO notifications; terminate once on an actual incompatible effective route, format, or capacity change.

**Route / ownership:** delegated direct; `AudioCaptureBackend.swift` and `AudioCaptureBackendTests.swift`, with narrowly required capture-session integration in `AudioCaptureService.swift`. Trigger: native state analysis plus source/test writes.

**Work:** Replace tests that treat unchanged notifications as disposal with deterministic native-seam regressions. On the serialized non-real-time control path, read effective route state safely; compare against the accepted requested/effective configuration, respecting pre-start versus initialized/running phases. Coalesce redundant queued work where appropriate. Preserve existing startup readback guarantees and cleanup-once behavior; never do native property queries or teardown on the render callback.

**Acceptance / regressions:** unchanged callbacks before start and after start retain valid capture; startup notifications do not bypass post-start validation; compatible repeated events keep frames flowing; actual input/output/format/capacity incompatibility requests cleanup exactly once; readback failure follows an explicit safe failure path; queued callbacks after cleanup cannot touch disposed resources. Preserve listener-registration/removal failure tests and no-HAL-fallback assertions. Avoid timing-only sleeps as the proof of ordering.

**Checks:** backend and service focused suites, disabled native probe, applicable aggregate checks below.

**Evidence (2026-09-30):** L1 implemented with focused proof; full-suite proof remains partial at the known baseline failure. Local work-unit commit: `7e2244cfab515aee6477e040e0cfc3b42f6ffdd8` (`fix(audio): validate effective routes before canceling capture`). The post-L1 identity record is carried forward with the L2 task-document update, not a separate identity-only commit.

- Regression-first RED before production edits: `/tmp/nuvi-l1-red.log`, backend suite 24 tests, 8 failed assertions across four redundant/startup/compatible/backend-local-lifetime regressions; production diff was empty at that point. These were behavioral failures, not tooling errors.
- GREEN after implementation and readability normalization: `/tmp/nuvi-l1-backend.log`, **25/25 passed**. Real route-control queue barriers replace sleep-only ordering. Coverage includes compatible frame publication, pre-start and initialization/start notifications, final startup mismatch rejection, 10 incompatible device/client-format/capacity/liveness/readback cases, cleanup once, and late callback no-read safety.
- Service checks: `/tmp/nuvi-l1-service.log`, **6/6 passed**. Disabled native probe: `/tmp/nuvi-l1-probe.log`, **1 skipped / 0 failures**; no microphone or permission check performed.
- Initial sandbox full run: `/tmp/nuvi-l1-full.log`, pasteboard access assertions in `HistoryMenuTests/testCopyHelperWritesCompleteTextToInjectedPasteboard` and the known SpeechAnalyzer signal 5. Exact normal-permission rerun `/tmp/nuvi-l1-full-normal.log` removed pasteboard failures: **202 passed cases and 2 skipped**, then signal 5 at `SpeechAnalyzerEngineTests/testAnalyzerInputQueueCountsDropsAndPreservesOldestSlices`; no other assertion failure observed. Full suite is **not PASS**, and later suites were not completed.
- Initial sandbox release build: `/tmp/nuvi-l1-release.log`, `GenerateDSYMFile` failed with `Operation not permitted`. Same build under narrowly scoped normal compiler permissions: `/tmp/nuvi-l1-release-normal.log`, **exit 0 / Build complete (34.42 sec)**. No flags/policy/source workaround or dependency update.
- Commands used the planned flags plus `CLANG_MODULE_CACHE_PATH=/tmp/nuvi-ptt-module-cache` and `--cache-path /tmp/nuvi-ptt-swift-cache` for every Swift command. Exact probe environment remained `NUVI_RUN_NATIVE_DUCKING_PROBE=0`. `git diff --check`: PASS.
- Production ownership: only `AudioCaptureBackend.swift`; tests only `AudioCaptureBackendTests.swift`; no service API, L2 retry/lock paths, L3 controller, hotkey, render policy, or updater changes. Route validation reads accepted bound unit devices/client formats and allocated slice capacity plus read-only bound-device liveness under the lifecycle lock. Pre-initialized/closed phases do not query invalid handles; startup verifies after both initialize/start. Cleanup happens outside that lock, and listener ownership retains validation after the service's backend local disappears.
- Functional authored diff before task-document inclusion: backend **62 additions / 2 deletions**, tests **169 additions / 73 deletions**, total **306**. The new task document and all progress text are counted in the work-unit commit at handoff.
- Rollback scope: L1 backend/test/task-document work-unit only, with parent authorization; no installed app was changed. Physical ducking, UI responsiveness and user's exact reproduction remain unverified. L2/L3 stay open; no native review has been run by this worker.

- Parent-reported L1 review closure: the user granted the candidate; native single `review-reliability` returned no findings. Exact acknowledgement returned `gentle-ai.review-acknowledged/v1`, action `acknowledged`, authority burned, lineage `review-c5798ed9a88e250c`, consumed revision `63cda20bf60aecfe6e767a44b138b976d3e49b1698ef17ca7d7e81bf56a4546f`. Reviewed boundary is `7e2244cfab515aee6477e040e0cfc3b42f6ffdd8`; do not reopen this consumed transaction.

### L2 — Make quarantine recovery bounded per operation and eventually retryable

- [x] L2: Remove reverse lock acquisition and permanent lifetime retry exhaustion while retaining unresolved native resources and preventing overlap.

**Route / ownership:** delegated direct, sequential after L1; `AudioCaptureBackend.swift` and `AudioCaptureBackendTests.swift`. Trigger: shared native teardown state and concurrency regressions. This is a genuine independent recovery behavior, not a line-budget split.

**Work:** Snapshot quarantine state under its lock, perform lifecycle reads/retries outside that lock, then reconcile safely without stale removal or duplicate reservation. Establish one lock-order rule with no quarantine-lock-to-lifecycle-lock path. Bound retry work within each admission/cleanup control operation, but allow a later user attempt to recover after earlier transient failures; do not spin or schedule an endless retry loop. Preserve capacity protection and explicit failure while native units remain unresolved.

**Acceptance / regressions:** more than three transient stop/dispose failures followed by success permit a later capture; never start a new unit before unresolved teardown succeeds; disposal plus listener-only residue still permits capture; concurrent retain/prune/admission cannot deadlock, drop retained units, exceed capacity, or reserve twice. Use barriers/latches and injected operation counts for deterministic progress assertions; preserve callback lifetime and cleanup idempotence tests.

**Checks:** backend focused suite, disabled native probe, applicable aggregate checks below.

**Evidence (2026-09-30):** L2 implemented with focused proof; full-suite result remains partial at the known baseline failure. Local work-unit commit pending at this pre-commit snapshot.

- First behavioral RED before any production edit: `/tmp/nuvi-l2-red.log`, **26 backend tests / 1 failure** in `testLaterAdmissionRecoversAfterMoreThanThreeTransientTeardownFailures`; five failed admissions still prevented recovery after native stop/uninitialize/dispose became successful. Direct deferred cleanup isolated the regression on the old implementation.
- Then the existing unsafe prune was extracted without changing its lock behavior into a narrow per-call inspection-barrier helper. `/tmp/nuvi-l2-lock-red.log`: **28 tests / 2 failures**, including deterministic `testQuarantinePruningAllowsConcurrentRetentionWhileLifecycleInspectionWaits`. The retainer timed out because quarantine held its lock while waiting for the lifecycle; bounded gates then released/drained workers, without wedging the test process.
- GREEN after the fix and final test readability/safety edits: `/tmp/nuvi-l2-backend.log`, **28/28 PASS**. Tests prove eventual recovery beyond three failures, bounded per-admission native work/no new unit before recovery, concurrent retention while lifecycle inspection waits, preservation of newly retained unresolved ownership, and 32 concurrent admission attempts capped at 16 reservations with all reservations released. Existing L1 route and listener/callback safety regressions remain green.
- `/tmp/nuvi-l2-service.log`: **6/6 PASS**. `/tmp/nuvi-l2-probe.log`: **1 SKIP / 0 failures**, environment `NUVI_RUN_NATIVE_DUCKING_PROBE=0`; no physical microphone/ducking QA.
- `/tmp/nuvi-l2-full.log`: **206 passed cases / 2 skipped / no assertion failures**, then actual signal 5 at `SpeechAnalyzerEngineTests/testAnalyzerInputQueueCountsDropsAndPreservesOldestSlices`. Exit 1; full suite **not PASS**, later suites incomplete. `/tmp/nuvi-l2-release.log`: **exit 0 / Build complete (37.49 sec)**. Existing unrelated capture warnings remain, no source workaround or policy change.
- Exact Swift commands used the planned flags with `CLANG_MODULE_CACHE_PATH=/tmp/nuvi-ptt-module-cache` and `--cache-path /tmp/nuvi-ptt-swift-cache`; GREEN/required checks ran with narrowly scoped normal compiler permissions. `git diff --check`: PASS.
- Production diff: **18 additions / 8 deletions** in backend quarantine/retry paths; tests **127 additions / 0 deletions**, **153 functional authored lines** before task-document changes. No L1 route-validation, service/controller/hotkey/render/updater changes.
- Recovery retries occur once per retained lifecycle per explicit admission/control operation, with no lifetime counter/timer/retry loop. Every quarantine-to-lifecycle inspection is outside the quarantine lock; pruning removes only fully released snapshot identities under the quarantine lock, preserving concurrent new entries and reservation accounting.
- Runtime harness: N/A for this dispatch; actual microphone/UI/native app validation remains excluded and the broader user reproduction is not claimed solved. Rollback boundary is only this L2 backend/test/task-evidence work-unit; preserve L1 route fix and its consumed review. Parent owns L2 native assessment/consent. L3 remains open.


### L3 — Serialize native control off main and own all asynchronous work by session

- [ ] L3: Keep the interface responsive through slow start/stop; honor release/cancel and immediate restart without overlap or stale feedback/completions.

**Route / ownership:** delegated direct, after L1/L2; `DictationController.swift`, `AudioCaptureService.swift` / `AudioCapturing` port, corresponding controller/service tests, and only required audio fakes/callers. Trigger: coordinated nontrivial API, session, and test changes. Discover exact additional callers before edits; return any scope expansion to parent.

**Work:** Introduce a narrow serial off-main native-control boundary rather than dispatching independent start/stop tasks. Keep UI state on `MainActor`; snapshot capture configuration and assign a session identity before awaiting control. Deliver start/stop completion, stream termination, level/spectrum feedback, silence timers, and errors only to their owning session. Associate feedback ownership when capture is created, not by reading the controller's current identity when an old callback arrives. A cancel/release during blocked startup must be recorded immediately and applied once native start returns; a later session cannot race pending cleanup. Preserve permission, engine preparation, live text insertion, history, and translation behavior.

**Acceptance / regressions:** MainActor can process release/cancel while injected native start or stop is blocked; release during startup stops that session after start completes; canceled startup cannot publish listening or late text; immediate restart waits for old cleanup without overlap; old zero/nonzero level, spectrum, timer, termination, and errors cannot alter the new session; same-session speech-to-silence still stops correctly; start failure/cancel/stop races leave an actionable consistent state. Repeated cycles retain per-session configuration and ducking selection. Preserve hotkey behavior and existing controller insertion/history regressions.

**Checks:** service, controller, backend, actual `ModifierHotkeyTests` suite and disabled native probe, followed by aggregate checks below.

**Evidence:** pending; no source edits, tests, or commit.

## Planned verification commands

Run during the bounded authorized implementation tasks. These commands use injected tests; no live microphone/device/permission prompt is authorized. The probe's environment guard skips before querying permission when set to zero.

```sh
swift test --disable-sandbox --disable-automatic-resolution --filter AudioCaptureBackendTests
swift test --disable-sandbox --disable-automatic-resolution --filter AudioCaptureServiceTests
swift test --disable-sandbox --disable-automatic-resolution --filter DictationControllerTests
swift test --disable-sandbox --disable-automatic-resolution --filter ModifierHotkeyTests
NUVI_RUN_NATIVE_DUCKING_PROBE=0 swift test --disable-sandbox --disable-automatic-resolution --filter NativeAudioDuckingProbeTests
swift test --disable-sandbox --disable-automatic-resolution
swift build -c release --disable-sandbox --disable-automatic-resolution
git diff --check
```

Perform source-mutating normalization before final functional checks/candidate freeze. Use existing caches or narrowly scoped temporary cache paths if compiler permissions require them; do not update dependencies or install tooling implicitly. Record exact commands, pass/fail/skip counts, and observed errors per unit.

Known historical limitation: `SpeechAnalyzerEngineTests/testAnalyzerInputQueueCountsDropsAndPreservesOldestSlices` exits with signal 5, proven previously on baseline `44e883c` and candidate. This is not a blanket waiver: report the current actual full-suite outcome and investigate any other required failure within authorized scope or return partial. A disabled native probe is a skip, not physical ducking QA.

## Rollback and runtime validation boundaries

Keep each unit reviewable with tests/docs and explicit commit identity; preserve inherited fixes. If a regression is found, revert only the owning unit (respecting L3's integration dependency) after parent authorization; do not remove ducking or reset unrelated work. L1 changes only the backend, its tests, and this task document; preserve the inherited updater and prior audio history. No installed-app rollback is needed because the application was not replaced.

Future separately authorized real-device validation should cover long held PTT, immediate release, cancel during startup, repeated restart, app/system restart, redundant route events, real device switch/disconnect, and music duck/restore. Until then, automated liveness proof does not establish hardware ducking, UI smoothness, or reproduction resolution. No installation, package, version, publication, or Brew task is included.

## Progress and next step

- L1/L2: implemented with focused checks; full-suite proof remains partial at the documented baseline signal 5. L1 native review closed; L2 native assessment pending. L3 remains open.
- L1 commit authored count: **442** (**367 additions / 75 deletions**). L2 functional authored count: **153**, plus task-document changes; exact L2 commit and accumulated numstat recorded at handoff. Generated artifacts excluded.
- Required L2 checks and exact logs recorded above. Physical/native runtime QA remains unrun; no installation, version, package or remote changes.
- Delivery: integrated `size:exception` granted; no remote/install/publication authority added.
- Local L1 commit: `7e2244cfab515aee6477e040e0cfc3b42f6ffdd8`; local L2 work-unit commit pending at this snapshot. Parent owns its exact-range assessment after handoff; this writer ran no native review operations.
- Next: parent checks the L2 committed range against the reviewed L1 boundary, then separately dispatches L3; do not claim the full renewed audio failure solved before control/session ownership and authorized physical validation.
