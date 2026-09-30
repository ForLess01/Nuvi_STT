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
- Effective configured strict TDD: **not enabled**; no explicit project configuration was found. Runner: `swift test`. Requested regression-first observed RED/GREEN is recorded for all three units below. Sandbox/tool failure is not a behavioral RED.
- RDD: **on/default**, read-only status confirmed by parent. L1 native review is closed as recorded below; Parent assessed L2 as medium / under budget; L2 remains pending in the slice based at the reviewed L1 boundary. Parent owns the L2+L3 assessment after this handoff. This bounded writer runs no native review commands. Later parent owns assessment, exact native consent/continuations, and ordinary delivery decisions.
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

**Evidence (2026-09-30):** L2 implemented with focused proof; full-suite result remains partial at the known baseline failure. Local work-unit commit: `0c43c85cf3eca2b5abbe1e597abb3b26947748e4` (`fix(audio): keep quarantine recovery retryable without lock inversion`); the mechanical post-commit identity record is carried forward with the coherent L3 task update.

- First behavioral RED before any production edit: `/tmp/nuvi-l2-red.log`, **26 backend tests / 1 failure** in `testLaterAdmissionRecoversAfterMoreThanThreeTransientTeardownFailures`; five failed admissions still prevented recovery after native stop/uninitialize/dispose became successful. Direct deferred cleanup isolated the regression on the old implementation.
- Then the existing unsafe prune was extracted without changing its lock behavior into a narrow per-call inspection-barrier helper. `/tmp/nuvi-l2-lock-red.log`: **28 tests / 2 failures**, including deterministic `testQuarantinePruningAllowsConcurrentRetentionWhileLifecycleInspectionWaits`. The retainer timed out because quarantine held its lock while waiting for the lifecycle; bounded gates then released/drained workers, without wedging the test process.
- GREEN after the fix and final test readability/safety edits: `/tmp/nuvi-l2-backend.log`, **28/28 PASS**. Tests prove eventual recovery beyond three failures, bounded per-admission native work/no new unit before recovery, concurrent retention while lifecycle inspection waits, preservation of newly retained unresolved ownership, and 32 concurrent admission attempts capped at 16 reservations with all reservations released. Existing L1 route and listener/callback safety regressions remain green.
- `/tmp/nuvi-l2-service.log`: **6/6 PASS**. `/tmp/nuvi-l2-probe.log`: **1 SKIP / 0 failures**, environment `NUVI_RUN_NATIVE_DUCKING_PROBE=0`; no physical microphone/ducking QA.
- `/tmp/nuvi-l2-full.log`: **206 passed cases / 2 skipped / no assertion failures**, then actual signal 5 at `SpeechAnalyzerEngineTests/testAnalyzerInputQueueCountsDropsAndPreservesOldestSlices`. Exit 1; full suite **not PASS**, later suites incomplete. `/tmp/nuvi-l2-release.log`: **exit 0 / Build complete (37.49 sec)**. Existing unrelated capture warnings remain, no source workaround or policy change.
- Exact Swift commands used the planned flags with `CLANG_MODULE_CACHE_PATH=/tmp/nuvi-ptt-module-cache` and `--cache-path /tmp/nuvi-ptt-swift-cache`; GREEN/required checks ran with narrowly scoped normal compiler permissions. `git diff --check`: PASS.
- Production diff: **18 additions / 8 deletions** in backend quarantine/retry paths; tests **127 additions / 0 deletions**, **153 functional authored lines** before task-document changes. No L1 route-validation, service/controller/hotkey/render/updater changes.
- Recovery retries occur once per retained lifecycle per explicit admission/control operation, with no lifetime counter/timer/retry loop. Every quarantine-to-lifecycle inspection is outside the quarantine lock; pruning removes only fully released snapshot identities under the quarantine lock, preserving concurrent new entries and reservation accounting.
- Runtime harness: N/A for this dispatch; actual microphone/UI/native app validation remains excluded and the broader user reproduction is not claimed solved. Rollback boundary is only this L2 backend/test/task-evidence work-unit; preserve L1 route fix and its consumed review. Parent-reported committed L2 assessment against `7e2244cfab515aee6477e040e0cfc3b42f6ffdd8`: **medium / 188 authored lines / review_due false / under_budget**. Reviewed boundary stays L1; the pending slice includes L2 and L3. No L3 candidate consent or review was performed by this writer.


### L3 — Serialize native control off main and own all asynchronous work by session

- [x] L3: Keep the interface responsive through slow start/stop; honor release/cancel and immediate restart without overlap or stale feedback/completions.

**Route / ownership:** delegated direct, after L1/L2; `DictationController.swift`, `AudioCaptureService.swift` / `AudioCapturing` port, corresponding controller/service tests, and only required audio fakes/callers. Trigger: coordinated nontrivial API, session, and test changes. Discover exact additional callers before edits; return any scope expansion to parent.

**Work:** Introduce a narrow serial off-main native-control boundary rather than dispatching independent start/stop tasks. Keep UI state on `MainActor`; snapshot capture configuration and assign a session identity before awaiting control. Deliver start/stop completion, stream termination, level/spectrum feedback, silence timers, and errors only to their owning session. Associate feedback ownership when capture is created, not by reading the controller's current identity when an old callback arrives. A cancel/release during blocked startup must be recorded immediately and applied once native start returns; a later session cannot race pending cleanup. Preserve permission, engine preparation, live text insertion, history, and translation behavior.

**Acceptance / regressions:** MainActor can process release/cancel while injected native start or stop is blocked; release during startup stops that session after start completes; canceled startup cannot publish listening or late text; immediate restart waits for old cleanup without overlap; old zero/nonzero level, spectrum, timer, termination, and errors cannot alter the new session; same-session speech-to-silence still stops correctly; start failure/cancel/stop races leave an actionable consistent state. Repeated cycles retain per-session configuration and ducking selection. Preserve hotkey behavior and existing controller insertion/history regressions.

**Checks:** service, controller, backend, actual `ModifierHotkeyTests` suite and disabled native probe, followed by aggregate checks below.

**Evidence (2026-09-30):** L3 implemented with focused injected proof and release compilation; full-suite proof remains partial at the known baseline signal 5. Local work-unit commit identity will be recorded mechanically after commit.

- Behavioral RED before production writes: `/tmp/nuvi-l3-red.log`, **37 controller tests / 9 assertion failures** across slow native start/stop, release during startup, and stale feedback/silence regressions. Gates self-release after a bounded timeout, so the old MainActor implementation fails rather than permanently wedging the test process. At this point only regression tests and the inherited mechanical task record were dirty; no production file was changed. Initial GREEN: `/tmp/nuvi-l3-green.log`, **37/37 PASS**.
- Final normalized candidate: `/tmp/nuvi-l3-controller.log`, **40/40 PASS**. Explicit native gates prove MainActor can process cancel/release while startup or teardown remains blocked; replacement starts only after old teardown, release finalizes once, canceled startup/error cannot publish into B, old level/spectrum/timer/transcription termination cannot change B, and late translation cannot insert or persist A into B. Repeated PTT cycles retain `[true, false, true]` ducking configuration and one final insertion each. Existing same-session silence, live insertion/history, preparation/reconfiguration and feedback tests remain green.
- The directly necessary Appearance microphone preview now uses the same serial adapter and capture identity; preview cancel/retrigger during blocked native start is also injected and checked. No UI strings, visual layout, hotkey semantics, backend/service/port, ducking selection, render policy or updater source changed. No runtime UI screenshot or app launch was performed.
- `SerialAudioCaptureControl` enqueues from MainActor in request order and executes every native start/stop/error/final teardown on one shared serial queue. Capture UUID/configuration are immutable per session. Queued cancellation never abandons a blocking native operation; B waits for teardown. Owned stops cannot stop a successor, and underlying service lifetime extends through final off-main teardown. No independent detached native tasks, timeout cleanup, automatic restart, or new framework was introduced.
- `/tmp/nuvi-l3-service.log`: **6/6 PASS**; `/tmp/nuvi-l3-backend.log`: **28/28 PASS**; `/tmp/nuvi-l3-hotkey.log`: actual `ModifierHotkeyTests`, **6/6 PASS**. `/tmp/nuvi-l3-probe.log`: **1 SKIP / 0 failures**, explicit `NUVI_RUN_NATIVE_DUCKING_PROBE=0`; not physical ducking QA.
- `/tmp/nuvi-l3-full.log`: **214 passed cases / 2 skipped / no assertion failures**, then exact `SpeechAnalyzerEngineTests/testAnalyzerInputQueueCountsDropsAndPreservesOldestSlices` signal 5, exit 1. One passed-case line was split by stderr; the count includes that case. Full suite is **not PASS** and later suites remain incomplete.
- Required commands below ran in foreground with `CLANG_MODULE_CACHE_PATH=/tmp/nuvi-ptt-module-cache` and `--cache-path /tmp/nuvi-ptt-swift-cache`, normal compiler permissions, no dependency updates. `/tmp/nuvi-l3-release.log`: **exit 0 / Build complete (42.47 sec)**. Only existing unrelated ModelDownloadService/TranslationCoordinator capture warnings were observed. `git diff --check`: PASS. Test gates and cross-queue fake observations are lock-protected; source normalization preceded final functional checks.
- Functional authored changes before task-document inclusion: controller **35/24**, preview **55/21**, tests **328/10**, new adapter **63/0**, total **536** additions plus deletions. Necessary concurrency/caller regressions exceed the advisory 400-line unit estimate within the approved integrated exception; no tests were omitted or code minified.
- Rollback scope: this L3 adapter/controller/preview/test/task-document unit only, after parent authorization, preserving L1 route and L2 quarantine corrections. Hardware/music/UI responsiveness and the user's exact reproduction remain unverified; no installed app or system/audio preferences were changed. Parent owns assessment of the pending L2+L3 committed slice and any subsequent native consent; this writer ran no review commands.

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

- L1/L2/L3: implemented with focused checks; full-suite proof remains partial at the documented baseline signal 5. L1 native review closed; L2 medium / under-budget assessment stays pending in the L2+L3 slice.
- L1 commit authored count: **442** (**367 additions / 75 deletions**). L2 commit authored count: **188** (**169 additions / 19 deletions**: backend **18/8**, tests **127/0**, task document **24/11**). Accumulated committed authored count: **630**; the mechanical L2 identity/count update is included in the L3 task record. L3 final authored count will be recorded after commit. Generated artifacts excluded.
- Required L3 checks and exact logs recorded above. Physical/native runtime QA remains unrun; no installation, version, package or remote changes.
- Delivery: integrated `size:exception` granted; no remote/install/publication authority added.
- Local L1 commit: `7e2244cfab515aee6477e040e0cfc3b42f6ffdd8`; local L2 commit: `0c43c85cf3eca2b5abbe1e597abb3b26947748e4`; L3 commit identity is pending at this pre-commit snapshot. Parent owns the pending L2+L3 exact-range assessment after handoff; this writer ran no native review operations.
- Next: parent assesses the committed L2+L3 range against the reviewed L1 boundary and follows native consent if due. Actual installed-app/device reproduction requires separate authorization; do not claim physical resolution from injected proof.
