# Nuvi 2.2.3 (build 8) release
Publish the installed correctness/optimization changes as a new signed release and update Homebrew.
Branch: main (explicit single-branch preference). Strategy: coherent local commits, single release; no PR chain. Runner: SwiftPM, script fixtures, strict artifact verification and remote readback.

## Specs

- S1: User: “haz commit y push y actualiza homebrew tap y el release del repo remoto”; confirmed “si” to publishing2.2.3(build8), commits/mainpush/tag/releaseNuvi.zip in ForLess01/Nuvi_STT and version/hash-only update in ForLess01/homebrew-tap using existing Git identity, SSH authentication and GitHub CLI session, without overwriting2.2.2.
- S2: Preserve all pending implementation, commits, installed candidate and rollback. Retain conventional Git identity and existing Apple Development signing identity; no AI attribution, new signing key, paid notarization, trust/quarantine changes or automatic app launch/install.
- S3: Verify full deterministic suite, script tests, release build, signature/runtime/exact entitlement/resources/version/architecture; ZIP extraction and final SHA256. Independently verify artifact, published bytes and matching cask URL/version/hash. Report opt-in skips and unexecuted physical QA honestly, never infer physical acceptance from publication request.

## Tasks

- T1 [S1,S2] inline: preserve pending implementation in coherent commits on main; complete (7b2e8d2,981ab50,51f63af,a26273b,7ab2c30). Existing functional/native review outcomes retained, not re-presented as approvals.
- T2 [S1,S2] inline: metadata2.2.3(8), notes and README link; prepared, structural checks PASS. Passive metadata/doc checks, no meaningful behavior RED.
- T3 [S2,S3] delegated action: offline tests/build/sign/package with provenance; pending. Trigger long build/release action, risk5.
- T4 [S2,S3] independent verifier: signed archive extraction/payload/metadata/checksums/source provenance; pending. Risk5.
- T5 [S1,S3] inline: new tag/mainpush/draftupload/downloadverification/publication, no overwrite; pending.
- T6 [S1,S3] inline: fresh isolated tap mainworktree, version/hash-only update, validate/commit/push/readback; pending.

## Log

- L1: User request verbatim: “haz commit y push y actualiza homebrew tap y el release del repo remoto”. Explicit confirmation “si” to2.2.3(build8), Nuvi_STT+homebrew-tap, existingSSH/GitHubCLIsession and no overwrite2.2.2.
- L2: Preflight localmain917ff8b equals fetchedorigin/main, pending correction files retained; existingGitidentityRendo, existingGitHubCLILoginForLess01, originSSHForLess01/Nuvi_STT. Latestremote2.2.2/Nuvi.zip, tapmain. No remote mutations yet. Prior candidate installed2.2.2(7), signedhashbae165552125fb72b15a8a2fbfb4fdfb6ad94f55a6f2e482fe2a04e0aacbf232, rollbackpreserved; new release operation doesnot replace it. Prior338PASS+3optinSKIP,21scriptPASS,ReleasePASS andindependentartifact/installPASS, supplementalnative reviews explicitlydeclined afterbudget/binding failures; no nativeapprovalreceiptclaim. PhysicalQA remainsunreported.
- L3: Forecast~4,600 accumulated authored lines from alreadyimplemented coherent behavior units, metadata/docs<200 newlines.400-line guidance advisory; preserve coupled storage/engine and controller/insertion contracts together, no codegolf/artificial broken commits. Explicit localmain/noPR publication preference preserved. No new sourcebehavior changes authorized by this release step. Risk:item5(release/environment).

- L4: Existing implementation committed by behavior:7b2e8d2 audio;981ab50 speech/storage coupled SDK ownership;51f63af controller/insertion; a26273b UI lifecycle;7ab2c30 distribution/tests/docs/tasklog. No source bytes changed by commit operations; existing post-commit graphify hook ran without altering tracked files. Prior explicit native-review declines apply to unchanged implementation; no approval claimed or failed review re-opened merely for commits. New metadata/docs2.2.3(8) prepared; no new behavior/dependency/runtime change.
