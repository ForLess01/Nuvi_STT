# Automatic Update Notices

Notify users about newer stable Nuvi releases automatically and show availability in Settings. Preserve the existing ducking implementation. Ship the verified source, release artifact, and matching Homebrew cask only after the applicable checks.

## Scope and authority

- Baseline: `44e883c`, branch `codex/automatic-update-notices`, inherited unpublished 2.2.1 (6).
- User authorized update notices, local commits and publication to `ForLess01/Nuvi_STT`, plus `ForLess01/homebrew-tap`, using the existing GitHub session and configured SSH.
- Public latest release and cask were verified as 2.2.0. Installed 2.2.0 has no checker; one manual upgrade is required before future automatic notices work.
- Do not alter audio/ducking/PTT, install or launch the app, request microphone access, change system audio, force-push, or mutate unrelated repositories.
- Notifications are advisory: do not download or execute updates automatically.
- Route: delegated direct. Preparation/writer triggers apply to service, app wiring, Settings UI, tests and release documents.
- No active strict-TDD configuration was found. Use observed test-first RED/GREEN with `swift test`; do not claim configured strict TDD.
- Delivery strategy: `exception-ok`. The maintainer explicitly approved a single-delivery `size:exception` after the 740-line implementation forecast and smallest cohesive 532-line detector/notifier/test unit were explained. Keep tests with behavior; no artificial slicing or PR creation is requested.
- RDD effective mode: on, default. Preserve native risk assessment, candidate consent and exact provider transitions.

## Acceptance

1. Startup and periodic public GitHub stable-release checks never block dictation and are throttled across restarts.
2. Version comparison, release URLs, network failures, request overlap and notification deduplication are tested using injected dependencies.
3. Settings shows installed version, check status, available version, refresh and a safe release-page action. Network/notification failures do not hide a known update.
4. A native notification announces a newer release once per version; permission denial leaves the Settings notice usable.
5. Rebuild and verify the final app/ZIP. Publish exact checked bytes, then update the cask version and SHA; do not claim hardware behavior or signature trust that was not verified.

## Tasks

- [ ] **U1 — Implement stable-release detection and native notices.** Add injected update service/adapters, persistence, regression tests and documentation. Route: delegated writer; reading prepares non-trivial writes. Check focused tests and build. Commit evidence: pending.
- [ ] **U2 — Surface update availability and wire the automatic lifecycle.** Inject the shared service into Settings, cover applicable UI states/localization/accessibility, wire startup/periodic checks and update release notes. Route: same bounded writer. Check focused tests, full suite, release build and structural UI review. Commit evidence: pending.
- [ ] **U3 — Package, publish and update Homebrew.** Verify final source/ZIP/signature and publication state before authenticated mutations. Update the cask only against the confirmed release asset SHA. Route: delegated production worker with independent prepublication verification. Commit/release/cask evidence: pending.

## Verification

- `swift test --filter AppUpdateServiceTests`
- `swift test`
- `swift build -c release`
- `git diff --check`
- Packaging: `./scripts/build-app.sh release`; documented `ditto` ZIP flow.
- Package readback: bundle version/build/architecture/resources, strict signature, archive integrity, SHA-256 and immutable source identity.
- Published readback: source commit/tag, release asset identity and SHA, cask version/SHA.
- Known historical failure: full-suite SpeechAnalyzer signal 5; recheck actual results. Existing 2.2.1 package had signature-trust failure; never silently waive it.
- Live notification delivery, physical audio/PTT and installed-app QA are unrun unless separately authorized; unit tests must not initialize live notification/AppKit singletons.

## Progress and rollback

- Read-only app/settings/release mapping completed; no update infrastructure exists.
- U1/U2 implementation is present: injected main-actor service, validated stable release domain, public HTTP adapter, native notification adapter, shared Settings card, startup/periodic/wake/activation wiring and user documentation. Audio/ducking/PTT files are unchanged.
- Focused proof: 14 `AppUpdateServiceTests` passed, 0 failures. Tests use isolated defaults and injected fetch/clock/notifier; no live GitHub, notification permission, app launch, microphone or audio QA.
- Test chronology: tests were authored first, but the initial command failed at sandbox module-cache permissions before compilation. Service drafts existed before the cache-adjusted negative compile check showed missing update types. This is NOT observed original test-first RED or configured strict TDD.
- Full suite: exit 1, unexpected signal code 5 at `SpeechAnalyzerEngineTests/testAnalyzerInputQueueCountsDropsAndPreservesOldestSlices`, matching the specifically documented historical test. One normal-permissions retry also exited 1 at that exact test with signal 5. No blanket waiver or unrelated fix was applied.
- Release build: passed with normal compiler permissions after the sandboxed attempt failed during debug-symbol generation (`Operation not permitted`). `git diff --check`: passed.
- Checks use `CLANG_MODULE_CACHE_PATH=/tmp/nuvi-updates-module-cache`, `--disable-sandbox --disable-automatic-resolution --cache-path /tmp/nuvi-updates-swift-cache` to keep caches writable without dependency updates.
- Structural UX/polish: initial/checking/current/error/rate-limit/retained-update/notification-denied-or-unavailable states exist; labeled native buttons/links, spinner accessibility, wrapping copy, existing palette/card spacing and timestamps are preserved. Runtime screenshots, keyboard/screen-reader operation and actual notification delivery remain unrun.
- U1/U2 remain unchecked until required closure evidence and commit/review decisions are reconciled by the parent. Commit identities pending; U3 not started. Engram mirror: updated full document saved and read back for this implementation handoff.
- Independent verification: focused updater tests passed 14/14. The filtered SpeechAnalyzer failure reproduces with signal 5 on both the current candidate and an untouched `git archive 44e883c` baseline; the relevant engine/test hashes match. This proves the failure predates the updater, not its root cause. Full-suite completion remains unavailable.
- Parent structural readback and `git diff --check` spot check passed. Independent verification found no deterministic updater requirement blocker; actual notification delivery and UI runtime remain unrun.
- Authored count at implementation handoff: U1 532 lines (549 with related README), U2 133, tracking 58; total 740 before subsequent progress notes. One honest slicing pass found the smallest cohesive detector/notifier/test unit already exceeds 400. The maintainer subsequently approved the single-release `size:exception`; record exact committed counts below.
- Native assessment over unstaged changes was unassessable due to undeclared untracked files. It did not classify this candidate as low risk. No native transaction or consent has begun; after the size decision and commit, assess the exact committed range and follow provider transitions.
- Rollback: remove only the new update service/tests and its app/settings integrations; preserve inherited audio fixes and other release work.

## Next step

Record the cohesive U1/U2 work-unit commit under the approved size exception, run the native committed-range assessment/consent, then package and independently verify U3 before publication. Preserve the baseline-proven full-suite limitation without changing unrelated audio. No source push, tag, release, or Homebrew mutation has occurred.
