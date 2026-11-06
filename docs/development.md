# Developing Nuvi

Build the menu-bar app locally without replacing your installed copy. For usage
and installation, start with the [README](../README.md).

## Build & run

Use Apple Silicon, macOS 26 or later, and an Xcode toolchain with the macOS 26 SDK.
The package uses SwiftPM; see [Package.swift](../Package.swift) and the pinned
resolution in [Package.resolved](../Package.resolved).

```bash
git clone git@github.com:ForLess01/Nuvi_STT.git
cd Nuvi_STT
./scripts/build-app.sh release
open build/Nuvi.app
```

The build script compiles the executable, assembles resources and signs
`build/Nuvi.app`. It does not replace `/Applications/Nuvi.app`. Close an already
running Nuvi before opening another build: normal app launches enforce a single
instance. Launch the **app bundle**, not its inner executable, so macOS can
associate permission requests with Nuvi's identity and usage descriptions.

## Signing & local installation

The build script prefers an existing Apple Development or Developer ID identity.
To select a specific existing identity:

```bash
export NUVI_SIGN_IDENTITY="Apple Development: your existing identity"
./scripts/build-app.sh release
codesign --verify --deep --strict --verbose=2 build/Nuvi.app
```

Use the exact identity available in your keychain (prefer its SHA-1 fingerprint).
The build requires one unambiguous Apple Development or Developer ID Application
identity. Missing/ambiguous identities and signing failures stop the build: there
is **no ad-hoc fallback and no retry without entitlements**. The previous local
build is not removed until the new staged bundle has passed verification.

### Verified local replacement

Quit Nuvi normally, then run:

```bash
./scripts/install-app.sh release
# Or install an already-built candidate without rebuilding:
./scripts/install-verified-app.sh build/Nuvi.app
```

| Step | Protection |
| --- | --- |
| Candidate verification | Strict signature, exact certificate fingerprint, signed bundle identifier, team, hardened runtime, audio-input-only entitlements, version/build, arm64 and resources. |
| Existing installation | Requires the same signer; refuses replacement while Nuvi is running. No force-quit. |
| Fresh rollback | `ditto` preserves metadata; a fresh backup is verified against the original before any rename. |
| Staging and replacement | Candidate stages on the destination volume. The original is renamed aside, not deleted first. |
| Post-installation | Compares payload, ownership/modes, symlink targets, ACLs and extended attributes; failures restore the original when filesystem operations permit. |

Backups remain under `~/Library/Application Support/Nuvi/Install Backups/rollback.*/Nuvi.app`.
Keep them until manual acceptance. The installer reports the exact rollback path.
If recovery itself fails, it reports the retained original and backup locations;
do not delete these directories. A power loss or uncatchable kill can interrupt
renames: preserve the reported/remaining `.Nuvi-install.*` directory and restore
its `previous-Nuvi.app` or the verified rollback before retrying. A stale
`.Nuvi-install.lock` requires confirming no installer is running before removal.

`install-verified-app.sh` accepts `--destination /path/Nuvi.app` and
`--backup-root /path` for isolated local installations. The destination parent
must already exist. `verify-app.sh APP` accepts `--identity SHA1`,
`--version X.Y.Z`, `--build N`, and `--compare OTHER_APP` for explicit checks.
The installer does not launch the app, change trust/quarantine/privacy settings,
or notarize it. A valid development signature is not Gatekeeper approval.

Run the offline distribution regression suite (Python standard library only):

```bash
python3 Tests/ScriptTests/test_distribution.py
```

The suite uses disposable app fixtures and mocked signing/build/process tools;
it does not access private signing keys or replace the real installed app.

## Architecture

The transcription boundary is a domain port; macOS integrations remain in
infrastructure. The application layer coordinates recording, transcription and
text delivery.

| Layer | Responsibility | Entry point |
| --- | --- | --- |
| App | Launch routing, single-instance handling and composition | [AppEnvironment](../Sources/Nuvi/App/AppEnvironment.swift) |
| Application | Dictation state, cancellation, hotkeys and delivery orchestration | [DictationController](../Sources/Nuvi/Application/DictationController.swift) |
| Domain | Transcription contract, states and models | [TranscriptionEngine](../Sources/Nuvi/Domain/Dictation/TranscriptionEngine.swift) |
| Infrastructure | Audio, speech adapters, insertion, settings, translation and updates | [Infrastructure](../Sources/Nuvi/Infrastructure/) |
| Presentation | Menu bar, floating pill, Metal visualizer and settings | [Presentation](../Sources/Nuvi/Presentation/) |

Speech adapters are `SpeechAnalyzerEngine`, `WhisperKitEngine`,
`ParakeetEngine` and `HybridTranscriptionEngine`. The default preference is
SpeechAnalyzer; Auto selects the hybrid adapter. `AudioCaptureService` is a
concrete infrastructure service, not a domain transcription port.

### Audio ownership

Native capture control is serialized off the main actor. Each PTT session owns
its stream; release closes callback admission and tears down the native graph
before completing delivery. Preserve callback lifetime and quarantine safety
when teardown fails. Native VPIO ducking remains optional; do not replace it with
system-volume writes or infer audible restoration from frame delivery alone.

### Reliability boundaries

| Area | Current ownership rule |
| --- | --- |
| LIVE audio | Intake continues while Whisper computes a partial. Audio and refresh queues remain bounded; capture reports ring, stream, oversized-slice and allocation losses. |
| Text insertion | AX stays on MainActor, but waits suspend. A shared FIFO orders output and cancellation rollback; focused target and clipboard ownership are rechecked. Without AX trust, direct typing can check the application PID, not distinguish fields within that application. |
| History | A private migration/clear marker prevents legacy history from reappearing. Physical deletion failures remain visible in Settings and can be retried with Clear all. |
| Translation | Known-source preparation has a 60-second budget, then inference gets 5 seconds. Automatic source detection retains a combined 60-second budget because the framework cannot prepare that pair separately. |
| Model cache | SDK attempts write to unique roots; only validated private copies become canonical models. Engines read separate owned snapshots so deletion cannot invalidate an active reader. Complete Whisper models and cached tokenizers support offline preparation. |

Model isolation trades additional disk space and copy work for safe ownership.
Read snapshots are reused while owned and removed after their final owner is
released. SDK attempt roots under
`~/Library/Application Support/<bundle-id>/ModelDownloads/SDKAttempts/` are
intentionally retained: the SDK cancellation API does not prove its internal
file writers have stopped. They are not installed-model inventory and must not
be reused or deleted while Nuvi may still be writing. Do not confuse them with
canonical model data or installation rollback backups.

Local model-loader adapters deliberately avoid SDK fallbacks that delete or
download on a load error. A corrupt model instead produces an actionable error;
use Settings to delete and download that model again. Keep the adapters aligned
with the pinned SDK configuration when updating dependencies.

## Tests

Run deterministic tests with SwiftPM:

```bash
swift test
```

Distribution scripts also have offline failure-injection tests. They use only
temporary apps and mocked signing tools, never `/Applications` or the keychain:

```bash
python3 -m unittest discover -s Tests/ScriptTests -v
```

Bundle copy verification compares payload, ownership, modes, symlinks, ACLs and
extended attributes, including quarantine. It excludes only the exact
`com.apple.provenance` attribute from equality: on the verified local copy,
macOS assigned a different value despite `ditto --rsrc --extattr --acl`.
The verifier never deletes or rewrites that attribute, and signature validation
remains independent. This exception does not assert Gatekeeper acceptance.

For the audio-control regression group:

```bash
swift test --filter 'AudioCaptureBackendTests|AudioCaptureServiceTests|AudioChunkRingTests|DictationControllerTests'
```

Opt-in hardware probes are not ordinary unit tests. Read their prerequisites
before enabling them: they can activate native audio and require a suitable local
machine. A skipped probe is not a passing hardware check.

### Verification boundaries

| Evidence | What it establishes—and what it does not |
| --- | --- |
| Injected/unit tests | State and ownership behavior under tested inputs; not acoustic ducking or permission behavior. |
| Build and strict signature | Compilation and signature integrity; not Gatekeeper notarization or physical acceptance. |
| File-based engine probe | Engine preparation/transcription on that Mac; not live microphone, hotkey, UI or insertion behavior. |
| Manual app test | Observed behavior in the tested devices/apps/scenarios; not a complete compatibility matrix. |

The L10 audio correction recorded **95 focused tests passing** and user-reported
acceptance of that installed build. Its full-suite run stopped at an
`AnalyzerInput` fixture with signal 5; the current correction separates the
buffer-order policy from the framework bridge without skipping those assertions.

On 2026-11-05, the integrated correction candidate completed **341 tests:
338 passed, 3 opt-in probes skipped**, with no failures. The exact same suite
first encountered pasteboard failures inside the tool sandbox and passed after
an approved unsandboxed rerun. This is unit-test evidence, not model, audio or
installed-app acceptance. See the
[current correction log](../odd/tasks/correctness-optimization.md) and the
[historical PTT log](../odd/tasks/ptt-audio-liveness.md#l10--release-vpio-completely-after-every-ptt-2026-11-04).

## File-based engine probe

Nuvi supports `--probe <audio-file> [locale]`. The runner attempts **SpeechAnalyzer,
WhisperKit and Parakeet**, rather than only the selected UI engine. It may load or
download models and request speech authorization. Results depend on the machine,
locale and available assets; use non-sensitive sample audio.

With Nuvi closed, launch the signed bundle with an absolute audio path:

```bash
open build/Nuvi.app --args --probe /absolute/path/sample.wav es-ES
```

The probe writes diagnostics to standard output; `open` does not display them in
the invoking terminal. Use a development launch configuration that captures
process output when inspecting results. A successful process exit is not a
per-engine PASS: inspect each engine's output and timeout/error result.

## Repository layout

| Path | Contents |
| --- | --- |
| `Sources/`, `Tests/` | Production Swift code and regression tests |
| `Resources/` | Bundle metadata, signing entitlements, icon and icon-generation source |
| `scripts/` | Build/install helpers and brand/icon generation |
| `docs/` | Developer and release guides, versioned notes and documentation media |
| `odd/tasks/` | Historical task decisions and verification evidence |
| `.build/`, `build/`, `graphify-out/` | Ignored local output; not shipped repository content |

Do not treat ignored directories as disposable by name alone. `build/` may also
contain signed candidates, installation receipts, Git preservation bundles and
rollback evidence. Confirm ownership and recovery needs before deleting them.
