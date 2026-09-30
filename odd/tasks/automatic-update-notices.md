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

- [x] **U1 — Implement stable-release detection and native notices.** Add injected update service/adapters, persistence, regression tests and documentation. Route: delegated writer; reading prepares non-trivial writes. Check focused tests and build. Commit: `fee9831a97f8d7f09315ce638091d670179bd0b5`; 14 focused tests and release build passed; native review approved and acknowledged with authority burned.
- [x] **U2 — Surface update availability and wire the automatic lifecycle.** Inject the shared service into Settings, cover applicable UI states/localization/accessibility, wire startup/periodic checks and update release notes. Route: same bounded writer. Check focused tests, full suite, release build and structural UI review. Commit: `fee9831a97f8d7f09315ce638091d670179bd0b5`; focused tests/build/structural UI passed. Full-suite completion remains unavailable due to the independently baseline-proven SpeechAnalyzer signal-5 failure; runtime UI/notification/hardware checks remain unrun. Native review approved and acknowledged.
- [x] **U3 — Package, publish and update Homebrew.** Route: delegated production worker with independent prepublication verification. Published stable/latest `v2.2.1` from `b2289f74a6173a3ede55c375d74803d3282e2929`, release `399712293`, asset `600002342`; the published ZIP digest matches independently verified bytes. Cask work-unit commit `77d6f5b5f672e0ed320f2ab968404c849d822c8f` updates only version/SHA. Ruby syntax, exact-change/DSL assertions, diff and remote readback passed; Homebrew style/audit could not run without missing pinned Sorbet gems, which were not installed. Runtime and full-suite limits below remain unchanged.

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

- Initial read-only app/settings/release mapping confirmed there was no update infrastructure before U1/U2 implementation.
- U1/U2 implementation is present: injected main-actor service, validated stable release domain, public HTTP adapter, native notification adapter, shared Settings card, startup/periodic/wake/activation wiring and user documentation. Audio/ducking/PTT files are unchanged.
- Focused proof: 14 `AppUpdateServiceTests` passed, 0 failures. Tests use isolated defaults and injected fetch/clock/notifier; no live GitHub, notification permission, app launch, microphone or audio QA.
- Test chronology: tests were authored first, but the initial command failed at sandbox module-cache permissions before compilation. Service drafts existed before the cache-adjusted negative compile check showed missing update types. This is NOT observed original test-first RED or configured strict TDD.
- Full suite: exit 1, unexpected signal code 5 at `SpeechAnalyzerEngineTests/testAnalyzerInputQueueCountsDropsAndPreservesOldestSlices`, matching the specifically documented historical test. One normal-permissions retry also exited 1 at that exact test with signal 5. No blanket waiver or unrelated fix was applied.
- Release build: passed with normal compiler permissions after the sandboxed attempt failed during debug-symbol generation (`Operation not permitted`). `git diff --check`: passed.
- Checks use `CLANG_MODULE_CACHE_PATH=/tmp/nuvi-updates-module-cache`, `--disable-sandbox --disable-automatic-resolution --cache-path /tmp/nuvi-updates-swift-cache` to keep caches writable without dependency updates.
- Structural UX/polish: initial/checking/current/error/rate-limit/retained-update/notification-denied-or-unavailable states exist; labeled native buttons/links, spinner accessibility, wrapping copy, existing palette/card spacing and timestamps are preserved. Runtime screenshots, keyboard/screen-reader operation and actual notification delivery remain unrun.
- U1/U2 are closed against the observed proof and acknowledged native review, with the baseline-proven full-suite and unrun runtime checks explicitly retained. U3 is locally in preparation; publication and Homebrew remain pending.
- Independent verification: focused updater tests passed 14/14. The filtered SpeechAnalyzer failure reproduces with signal 5 on both the current candidate and an untouched `git archive 44e883c` baseline; the relevant engine/test hashes match. This proves the failure predates the updater, not its root cause. Full-suite completion remains unavailable.
- Parent structural readback and `git diff --check` spot check passed. Independent verification found no deterministic updater requirement blocker; actual notification delivery and UI runtime remain unrun.
- Authored count at implementation handoff: U1 532 lines (549 with related README), U2 133, tracking 58; total 740 before subsequent progress notes. One honest slicing pass found the smallest cohesive detector/notifier/test unit already exceeds 400. The maintainer subsequently approved the single-release `size:exception`; record exact committed counts below.
- Native assessment over unstaged changes was unassessable due to undeclared untracked files. It did not classify this candidate as low risk. The subsequent exact committed-range assessment and transaction are recorded below.
- U1/U2 work-unit commit: `fee9831a97f8d7f09315ce638091d670179bd0b5` (`feat(updates): announce new releases automatically`), 11 files and 744 authored changed lines. The source and tests remained unchanged after functional verification.
- Committed-range native assessment: high risk, `review_due=true`. The maintainer granted candidate review. All four native captures completed concurrently; the final admitted event approved the candidate without a correction. Exact acknowledgement returned `gentle-ai.review-acknowledged/v1`, `action=acknowledged`, `authority=burned`, lineage `review-766b8e4d0463716b`, target `sha256:398a2b8c2e327c407fd1f3bf08ef5ab7bb7f3ea37a248663af87d5950ca447ff`.
- Non-blocking follow-up: duplicate reliability/resilience observations about truncating a server `Retry-After` greater than 12 hours to the regular polling interval. No correction was offered; keep this separate from the approved candidate and do not reopen its review.
- Fresh U3 initial package from `fee9831a97f8d7f09315ce638091d670179bd0b5`: `./scripts/build-app.sh release` passed using the existing stable Apple Development identity. Normal-permissions `codesign --verify --deep --strict --verbose=2` exited 0 (`valid on disk`; `satisfies its Designated Requirement`), and signed entitlements match `Resources/Nuvi.entitlements` (`com.apple.security.device.audio-input=true`). The earlier strict trust failure did not reproduce in this fresh check; no trust/keychain/policy change was made.
- Fresh metadata/resources: 2.2.1 (6), `com.nuvi.app`, arm64, macOS 26.0, `nuvi.Nuvi.resources`, icon, loose/bundled ModelsCatalog and all three required SVGs present. Gatekeeper exited 3 (`rejected`) under the unchanged Apple Development/non-notarized policy, not the earlier internal code-signing error. Live app/audio/notification checks remain unrun.
- Release notes were updated only from this fresh package proof and preserved test/runtime limitations. This factual docs/tasks work unit is committed before the final rebuild/ZIP; the production handoff records the exact final HEAD, artifact hashes and checks externally to avoid self-referential commit identities. Independent package verification, publication and Homebrew remain pending; no remote mutation occurred.
- Final release source: `b2289f74a6173a3ede55c375d74803d3282e2929`, following docs-only preparation commits `d62fd727408983389c47d211494e20398d2a296e` and `b2289f74a6173a3ede55c375d74803d3282e2929`. Source/tests/resources/scripts remained identical to the reviewed implementation. Fresh final app/ZIP and independent extraction passed strict signature integrity, metadata/resources/entitlements, safe archive paths and byte/mode equivalence. Gatekeeper rejection and absence of notarization remain the declared distribution policy, not approval.
- Final ZIP: 4,769,186 bytes, SHA-256 `5900004eb981a9f2329c135a40237b286135f40cc54bcd8843c3c3b2d1c020f8`. GitHub release `399712293` and asset `600002342` report the same size/digest. Published release: https://github.com/ForLess01/Nuvi_STT/releases/tag/v2.2.1. Annotated tag object `2d495ac098a2b04e44bc33eba4701c6b3ebefc64` peels to the final release source; latest endpoint reports stable `v2.2.1`.
- Published tap main: `77d6f5b5f672e0ed320f2ab968404c849d822c8f`; public `Casks/nuvi.rb` reports 2.2.1 and the exact published ZIP SHA. Compatibility, URL, caveats, postflight and zap remained unchanged. Native cask assessment: default/on, medium risk, four changed lines, `review_due=false` (`under_budget`); no native cask review or approval was fabricated.
- Registered live tap stayed clean on its original `main/0acba8be3a4cf7e1ed1da983efc5a2a9810064b7`; publication used an owned isolated worktree, which was removed afterward. No force push, overwrite, app install/launch, permission prompt or new audio/UI/notification QA occurred. Parent independently read back the published release/asset digest, source main/tag and public cask.
- Rollback: remove only the new update service/tests and its app/settings integrations; preserve inherited audio fixes and other release work.

## Next step

Perform one manual `brew update` and `brew upgrade --cask nuvi` from installed 2.2.0 to receive the checker; subsequent newer releases can produce notices. Live notification/UI/audio validation remains user-owned and unrun. Track the non-blocking server-backoff observation as separate future work; do not reopen the completed review. Release tag and package provenance remain fixed to the final release source above; later factual task-history commits do not change the release artifact.
