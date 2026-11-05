# Nuvi 2.2.2 (build 7) release
Publish the accepted audio correction and documentation as a signed release, then update Homebrew.
Branch: main (explicit single-branch preference). Strategy: single release; expected <250 authored lines. Runner: SwiftPM plus artifact and remote readback checks.

## Specs

- S1: User: “tienes que actualizar todo”. Confirmed “si” to: “¿Autorizás publicar **2.2.2 (build 7)** en `ForLess01/Nuvi_STT` y actualizar `ForLess01/homebrew-tap`, usando tu sesión existente de GitHub CLI y tu autenticación SSH?” Scope: bundle version/build, notes, signed Nuvi.zip, tag/GitHub release and cask version/hash.
- S2: Preserve the accepted implementation: user previously reported “Bien hasta aqui esta funcionando genial... commitea hasta aqui...”. No new audio behavior, dependencies, trust/keychain policy, notarization claims or forced remote overwrites. Source/test baseline is f43ad83588bd24fba5d9b45ebaaf12a62fb48f2b; earlier accepted correction is 582e305.
- S3: Preserve existing local candidates, receipts, backups and installed app. This release operation does not authorize automatic launch, microphone/PTT/music tests or coreaudiod restart. No new physical-fix claim beyond the user's reported acceptance.
- S4: Verify focused tests, one full-suite attempt, release build, signature/identity/entitlements/resources/version/architecture, archive extraction and SHA-256. Known full-suite SpeechAnalyzer signal 5 must remain partial, never PASS. Verify published asset bytes and matching Homebrew URL/version/hash.

## Tasks

- T1 [S1,S2] inline: prepare version, notes and README release link — complete; commit `1d675818ac2484636d4e257c7084f22d80ecdc1f`.
- T2 [S2,S3,S4] delegated verification/build: normal-permission focused/full checks, cleanly assembled signed archive and provenance receipt — complete; trigger: long build/signing action, risk item 5.
- T3 [S2,S3,S4] independent verifier: inspect candidate from fresh temporary copy and compare metadata/signature/payload/hash — complete; trigger: release risk item 5.
- T4 [S1,S4] inline: commit/tag/push, publish release and independently download/read back — complete; tag `v2.2.2` at `1d67581`, release ID 434714593.
- T5 [S1,S4] inline: fresh tap checkout, change only cask version/hash, validate/commit/push and read back — complete; tap commit `cc4010be1ce29de5d96d367e48f9227643aad0ae`.

## Log

- L1: User requests: “Creo que sobra decir que tambien debes de actualizar el release”; “tienes que actualizar todo”; “si” to explicit 2.2.2 build 7 / Nuvi_STT / homebrew-tap / existing GitHub CLI and SSH authorization.
- L2: Preflight: main clean at f43ad83; remote latest v2.2.1, archive name Nuvi.zip. v2.2.2 absent locally/remotely. Tap default branch main; cask 2.2.1 and SHA 5900004eb981a9f2329c135a40237b286135f40cc54bcd8843c3c3b2d1c020f8. Existing cask postflight quarantine operation is out of scope; do not run it or modify it during version/hash update.
- L3: No meaningful behavioral RED for metadata/docs-only changes; assert final version/build against spec, compare source/test/dependency trees to baseline and validate final artifacts. No new implementation is authorized. Preserve one local main rather than creating a feature branch, per explicit user instruction.

- L4: T2 verification: focused 109/109 PASS; full suite PARTIAL (228 passed, 2 opt-in probes skipped, then the known SpeechAnalyzer signal 5, no other observed assertions). Release build PASS 56.92s. No source/test/script/dependency changes; 106 input hashes stable. Existing signing identity 45CA1491D25AD6EC62C137B05AB1FFE63800DCFF / Team A2B56D7U5G, hardened runtime, audio-input-only entitlement, 2.2.2(7), arm64. Gatekeeper3/stapler65: non-notarized, not distribution-trust PASS. No app installation or launch.
- L5: Artifact `build/releases/2.2.2/Nuvi.zip`, 4,791,463 bytes, SHA-256 `72ddacc634ffc15a6cc89998f808a6ea26322ed4643ddce2bbb2e6222e6d6bdc`; signed executable `272bb24844ba12a88d61a78dd588f4ce51954a0ff572da6f66498c7b21f5717d`. Extracted full 18-entry/10-file inventory/signature matches; 39 Mach-O sections and UUID preserved by signing. Receipt and focused/full/build logs in the same build directory. Independent verification pending.

- L6: Independent T3 PASS: fresh scratch extraction verified ZIP/executable SHA, exact certificate fingerprint, Team/runtime/entitlement, 106 inputs and full payload. Installed accepted app unchanged. Parent repeated strict signature and ZIP hash PASS under normal permissions; sandbox-only CSSMERR_TP_NOT_TRUSTED was not reproduced with normal keychain access. No trust modification. Independent receipt copied to `build/releases/2.2.2/independent-verification.json`.
- L7: Native candidate assessment after explicit staging: medium, 84 changed lines, review_due=false/under_budget; no review lifecycle or approval claimed. Initial untracked-scope refusal was resolved by staging the intended files, not by excluding evidence. Risk: item 5 (release/environment); independent verifier completed.

- L8: Release commit `1d675818ac2484636d4e257c7084f22d80ecdc1f` contains version/build, README link, release notes and this log. Its committed native assessment was medium, 87 lines, review_due=false/under_budget. Annotated tag v2.2.2 pushed atomically with main; no older tag/release overwritten.
- L9: GitHub release ID 434714593 was created as a draft with asset Nuvi.zip ID 711788394; downloaded draft bytes/SHA matched. Published stable/Latest at https://github.com/ForLess01/Nuvi_STT/releases/tag/v2.2.2. Anonymous public-download verification repeated the exact ZIP hash and size. Remote tag dereferences to 1d67581. Public notes link to this log on main; no dependency/audio/runtime changes.
- L10: Fresh isolated tap worktree based on 77d6f5b; only version/hash changed. Ruby syntax PASS and Homebrew FromContentLoader PASS: version2.2.2, exact SHA and public release URL. `brew info` rejected a standalone file outside an installed tap; validated with Homebrew's content loader instead, without installing a tap/cask or executing postflight. Commit cc4010b pushed to ForLess01/homebrew-tap main; GitHub cask readback byte-identical. Existing postflight/security behavior remains untouched.
- L11: Publication receipt `build/releases/2.2.2/publication-receipt.json` plus signed package, full logs and independent receipt retained locally. No app installation, launch, microphone, PTT, music, coreaudiod or trust-policy mutation. The accepted installed 2.2.1(6) candidate is deliberately unchanged; release2.2.2(7) is available through GitHub/Homebrew. Full suite remains PARTIAL at the known signal5, despite 109 focused PASS. Risk: item5 (release/environment); independent artifact verification PASS, public bytes/cask readback PASS.
