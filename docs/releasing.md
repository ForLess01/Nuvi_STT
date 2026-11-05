# Releasing Nuvi

Maintainer workflow for a versioned distribution—not for a local test build.
Publishing the repository does not publish a release or update Homebrew.

[Project overview](../README.md) · [Build and verification](development.md)

## Before publishing

- Confirm the version, build number, source revision, release destination and
  Homebrew scope. Keep a local test build separate from a public release.
- Record test outcomes honestly, including failures, skips and hardware checks
  not executed. User acceptance of one installed build is not full-suite proof.
- Validate first and repeated PTT, ducking/restoration, cancellation and text
  insertion on the intended Mac before making runtime-fix claims.
- Preserve a verified rollback when replacing an installed app for testing.

## Version & package

The bundle version comes from [Resources/Info.plist](../Resources/Info.plist).
Use three numeric components for `CFBundleShortVersionString` (for example,
`2.2.2`); the updater does not accept alphabetic hotfix suffixes. Track build
identity separately with `CFBundleVersion`.

Build with the intended existing signing identity, then inspect the artifact:

```bash
./scripts/build-app.sh release
codesign --verify --deep --strict --verbose=2 build/Nuvi.app
codesign -dv --verbose=4 build/Nuvi.app
codesign -d --entitlements :- build/Nuvi.app
```

Check the signer, TeamIdentifier, hardened runtime, expected entitlements,
version, architecture and resource bundle—not just the command's exit status.
Do not distribute an accidental ad-hoc fallback. See
[signing caveats](development.md#signing--local-installation).

Once the intended signed bundle is verified:

```bash
ditto -c -k --sequesterRsrc --keepParent build/Nuvi.app build/Nuvi.zip
shasum -a 256 build/Nuvi.zip
```

Hash the final archive **after** signing and packaging. Signing changes the
executable bytes; a pre-sign executable hash is not the installed binary's hash.
Extract and verify the archive before publication.

## Publish explicitly

| Artifact | Destination |
| --- | --- |
| Version notes | `docs/releases/vX.Y.Z.md`, then the matching GitHub release description |
| Signed app archive | `Nuvi.zip` attached to the matching `vX.Y.Z` GitHub release |
| Homebrew metadata | `version` and final ZIP `sha256` in `Casks/nuvi.rb` in `ForLess01/homebrew-tap` |
| Release screenshots/GIFs | `docs/assets/releases/vX.Y.Z/` |

Keep publication and Homebrew changes explicitly authorized. Nuvi's update
checker reads stable GitHub release metadata; pushing a commit alone does not
announce an app update, and the checker does not install one.

## Signing is not notarization

The currently documented distribution uses a development signature and is **not
notarized**. Keep that limitation visible to users. A valid signature does not
mean Gatekeeper will approve the download, and distributing a free app does not
remove the distinction.

Do not describe a development-signed local candidate as a notarized release or
change users' global security policy to make it launch. If the distribution
policy changes, update the installation notice and release notes together.
