# Nuvi 2.2.1 Fix Release Preparation

## Objective

Prepare a local, non-published Nuvi 2.2.1 fix-release candidate (build 6) on a release branch from the reviewed repeated-PTT ducking fix. Keep the app version, README release link, release notes, and packaging evidence consistent without changing the inherited audio implementation.

## Problem and why

The repeated push-to-talk/native-ducking fix is the intended 2.2.1 correction. The installed test build was reported as “genial,” but this release-preparation task does not independently verify physical microphone, PTT, audio-route, or acoustic behavior. The repository release metadata currently identifies 2.2.0 (build 5), so local release metadata and notes need to reflect the fix version.

## Scope and constraints

- Authorized paths: `Resources/Info.plist`, `README.md`, `docs/releases/v2.2.1.md`, and this task document.
- Local branch: `codex/release-nuvi-2-2-1`, created from exact baseline `2ea75d10e9a2d930078b5ae4b47b717585e015c4` (`codex/repeated-ptt-ducking`).
- Keep the inherited audio source unchanged; do not alter package/build scripts or the Homebrew tap.
- No remote GitHub/Homebrew operation, credential/session inspection, push, tag, release, or PR. No installed-app replacement/launch, microphone/PTT/audio test, `coreaudiod` action, or system volume/mute change.
- Report package signature state honestly, including any existing Apple Development trust failure; do not change signing policy.
- The user-reported installed test build is not independent physical QA evidence.

## Acceptance criteria

- App metadata reports version `2.2.1` and build `6`, supported by local version history.
- README points to the 2.2.1 fix-release notes as the current release-notes link.
- Release notes describe the repeated-PTT ducking fix without asserting unsupported physical QA, and preserve relevant compatibility, distribution, and known-limit information.
- Required local checks and the production bundle/ZIP validation are recorded with exact outcomes; no real-device behavior or publication is claimed.
- Changes are committed locally as one coherent Conventional Commit work unit; no push or publication occurs.

## Verification and packaging

- `plutil -lint Resources/Info.plist`
- `swift test` — report the exact result; previously reported SpeechAnalyzer signal-5 and intermittent HistoryMenu failures are not treated as baseline exclusions unless verified against this candidate.
- `swift build -c release`
- `./scripts/build-app.sh release`
- Create local `build/Nuvi.zip` with the documented `ditto -c -k --sequesterRsrc --keepParent build/Nuvi.app build/Nuvi.zip` flow, without touching `/Applications/Nuvi.app`.
- Verify the built bundle's version/build (`2.2.1`/`6`), bundle ID, executable architecture, required resources, signature status, ZIP contents, SHA-256, and local artifact provenance.
- `git diff --check`; final worktree status.
- Runtime harness: `N/A` for this version-and-documentation work unit; the inherited source fix's physical microphone/PTT/audio behavior is explicitly outside this preparation scope.

## Work plan and progress

Route: delegated direct, one bounded writer. The coordinated non-trivial work spans version metadata, release documentation, and packaging evidence; the parent assigned this release-preparation unit to this writer. No SDD artifacts are created.

Estimated authored diff: approximately 130 additions plus deletions, excluding generated build/archive outputs (planning estimate, not a budget).

| ID | Task | Status | Evidence |
|---|---|---|---|
| R221-1 | Confirm clean baseline and create the release branch and this tracking document before source edits. | Complete | Baseline `2ea75d10e9a2d930078b5ae4b47b717585e015c4`; branch `codex/release-nuvi-2-2-1`. |
| R221-2 | Set bundle version/build to 2.2.1 (6) and update the README's current release-notes link. | Complete | `Resources/Info.plist` identifies 2.2.1 (6); `README.md` links to `docs/releases/v2.2.1.md`. |
| R221-3 | Add accurate 2.2.1 fix-release notes and explicit validation limits. | Complete with review correction | Notes scope overlap prevention to serialized PTT capture, describe failed listener removal after AudioUnit disposal, and do not present quarantine removal as a trust fix. |
| R221-4 | Run the required checks, build the local app/ZIP, and record identity, signature, contents, hash, and provenance. | Blocked for publication | The previous local artifact predates the final documentation correction; strict signature/Gatekeeper checks fail and the test suite exits 1. Rebuild from the immutable final source commit and reverify before any publication. |
| R221-5 | Review the final diff, commit the coherent local work unit, and record the commit identity. | Complete | Work-unit commit `f4b163edfd4d04763a9045a4401869088b48fa0d`; no push or publication. |

## Verification results

- `plutil -lint Resources/Info.plist`: PASS (`Resources/Info.plist: OK`).
- `swift test`: FAIL (exit 1). The `NuviTests` target reports a failure; output stops after `SpeechAnalyzerEngineTests.testAnalyzerInputQueueCountsDropsAndPreservesOldestSlices` starts and provides no final test count or root cause. The log separately shows an expected child-process signal-5 event within `SingleInstanceGuardTests.testOpenFailureIsReportedAsInfrastructureFailure`, which itself passes; it is not established as the suite failure cause. Do not attribute this to the release metadata/docs or assume it is baseline without a comparative run.
- `swift build -c release`: PASS (`Build complete!`, 32.78 seconds).
- `./scripts/build-app.sh release`: PASS; generated `/Users/rendoaltar/Nuvi/build/Nuvi.app` and returned without installing or launching it.
- Built bundle and ZIP metadata: version `2.2.1`, build `6`, bundle ID `com.nuvi.app`; executable is arm64. Bundle resources include `ModelsCatalog.json`, `Nuvi.icns`, and the Nuvi Swift package resource bundle with SVG assets.
- `codesign --verify --deep --strict --verbose=2 build/Nuvi.app`: FAIL with `CSSMERR_TP_NOT_TRUSTED`. Signature details report authority unavailable. `spctl --assess --type execute --verbose=4 build/Nuvi.app`: FAIL with `internal error in Code Signing subsystem`. The existing signing configuration was not changed; trust/notarization is not claimed.
- `ditto -c -k --sequesterRsrc --keepParent build/Nuvi.app build/Nuvi.zip`: PASS. `unzip -t` reports no compressed-data errors; archive contains the app bundle paths and 26 `__MACOSX` AppleDouble entries from the documented sequestered-resource flow, with no `.DS_Store` entries. ZIP size: 4,710,296 bytes. SHA-256: `6f2dcf0885238971894c55d3fcfddfacab862b6bae11645ee93bb8f28efaa4fd`.
- This local artifact was built from the release branch at baseline `2ea75d10e9a2d930078b5ae4b47b717585e015c4` plus the version and documentation changes tracked here; it is not a published or hardware-validated release.
- `git diff --cached --check`: PASS. Post-commit `git status --short --branch`: clean on `codex/release-nuvi-2-2-1`.
- Work-unit commit: `f4b163edfd4d04763a9045a4401869088b48fa0d` — `fix(release): prepare Nuvi 2.2.1 fix release`.

## Independent review correction and provenance blocker

- The review found that the original notes overstated non-overlap beyond the serialized PTT flow and incorrectly described a callback arriving for a disposed listener. The notes now scope the guarantee to serialized PTT and describe route-listener removal failure persisting after AudioUnit disposal.
- The original quarantine-removal command could be read as a remedy for the candidate's trust failure. It has been removed; the notes now state that quarantine removal does not resolve `CSSMERR_TP_NOT_TRUSTED` or the Gatekeeper assessment error.
- The README's 2026-08-14 verification is explicitly historical and is not evidence for 2.2.1.
- Documentation correction commit: `be421e0ad49f9cf30ebaaea8b5c26f147c394bf7` — `docs(release): correct Nuvi 2.2.1 candidate notes`.
- `/Users/rendoaltar/Nuvi/build/Nuvi.app` and `/Users/rendoaltar/Nuvi/build/Nuvi.zip` were built before this correction, from commit `f4b163edfd4d04763a9045a4401869088b48fa0d`. The recorded ZIP hash is historical and must not be used for publication. After the final documentation/source commit is immutable, rebuild and reverify the app, ZIP, signature status, and hash before any publication decision. Do not claim the current artifact is ready.

## Persistence status

The full-document Engram mirror at `odd/nuvi-2-2-1-release/tasks` is pending. Engram rejected the save because multiple active runtime sessions matched this project and directory; no session ID was available to disambiguate safely. Do not attach this artifact to an invented or guessed session. The local task document remains the progress source for this run.

## Next step

The documentation correction is committed. The existing package is not ready or valid for publication; rebuild and reverify from the immutable final source commit, then resolve test/signature blockers. Remote release, Homebrew, push, tag, and PR actions remain unauthorized.
