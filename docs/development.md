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

Use the exact identity available in your keychain. A stable identity helps retain
macOS privacy grants across builds. The script can fall back to **ad-hoc signing**
when no stable identity is available; read its output. A strict signature check
alone does not prove the intended identity, entitlements or notarization.

> [!WARNING]
> `scripts/install-app.sh` currently removes `/Applications/Nuvi.app` before
> copying the new bundle. It is **not rollback-safe** and is not the recommended
> path for replacing a working installation.

For a local replacement, first verify the candidate's identity, entitlements,
version and resources. Preserve a fresh backup of the installed app, including
permissions and extended attributes; verify it before replacement. Quit Nuvi
normally, use a recoverable replacement, then compare the installed payload and
signature with the candidate. Keep the rollback until manual acceptance. Do not
change keychain trust, quarantine or global security policy as a build workaround.

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

## Tests

Run deterministic tests with SwiftPM:

```bash
swift test
```

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
acceptance of the installed build. The previously recorded full-suite run remains
**partial**: `SpeechAnalyzerEngineTests/testAnalyzerInputQueueCountsDropsAndPreservesOldestSlices`
terminated with signal 5. These are historical results, not a guarantee about a
new checkout or a green full suite. Detailed evidence lives in
[the PTT task log](../odd/tasks/ptt-audio-liveness.md#l10--release-vpio-completely-after-every-ptt-2026-11-04).

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
