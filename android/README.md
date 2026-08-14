# Nuvi Voice for Android

Nuvi Voice is a private Android input method (IME) for local speech-to-text. It
targets the Samsung Galaxy S24 Ultra first, uses NVIDIA Parakeet TDT 0.6B v3
INT8 through official `sherpa-onnx`, and keeps `whisper.cpp` as an explicit
alternative. It writes with `InputConnection.commitText`; it never uses the
clipboard or an `AccessibilityService`.

## Privacy and technology boundary

- The runtime manifest deliberately has **no `INTERNET` permission**.
- Audio, models, diagnostics, and transcripts remain on the phone.
- Diagnostics contain only engine family, request ID, sample count/duration,
  phase, elapsed time, error code, and memory. Audio and transcript text are
  never logged.
- Dictation is blocked in password and PIN fields.
- Models are selected with Android's Storage Access Framework and copied into
  app-private storage. They are not bundled in the APK or repository.
- The visual system is an Android-native optical-glass interpretation. It uses
  Apple's public design principles (separate content from a floating controls
  layer, avoid nested glass, adapt contrast, honor reduced motion and reduced
  transparency), but it is **not** Apple's proprietary Liquid Glass material.

## Direct-phone Parakeet setup

The default engine expects the official multilingual bundle:

`sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2`

1. On the S24 Ultra, use Chrome to download the archive from the official
   sherpa-onnx `asr-models` release:
   `https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2`
2. Do **not** extract it. Open Nuvi, select **Parakeet**, then choose
   **Import model from Downloads**.
3. Select the `.tar.bz2` archive. Nuvi stream-extracts only these audited files:
   `encoder.int8.onnx`, `decoder.int8.onnx`, `joiner.int8.onnx`, `tokens.txt`.
4. Nuvi blocks path traversal, duplicate names, oversized entries, excessive
   entry counts, required-file caps (encoder 800 MB, decoder 32 MB, joiner
   16 MB, tokens 2 MB), auxiliary files above 64 MB, and total decompressed
   work above 900 MB. The complete compressed and decompressed streams are both
   hard-bounded, so TAR/PAX/GNU parser metadata cannot bypass the budget.
   Unknown regular files, nonzero-size directories, links, and special entries
   are rejected. It fsyncs staged files, validates the
   exact bundle, load-tests a CPU `nemo_transducer` recognizer through the
   sherpa-onnx filesystem constructor (imported absolute paths never use the
   APK `AssetManager`), and atomically
   activates it. A failed import preserves the previous active model.
   Import runs in the private `:model_import` foreground-service process, not
   in the setup/IME process. Keep at least 1.5 GB free while importing. If the
   native load-test is killed, the setup screen remains responsive, reports an
   interrupted import, removes staging files, and keeps the prior pointer.
   Archive streaming has a 20-minute absolute / 2-minute no-progress deadline.
   Native engine initialization has its own five-minute absolute deadline,
   separate from dictation inference timing. sherpa-onnx exposes no load-progress
   callback, so Nuvi uses process/import-lock liveness rather than a fake
   heartbeat. The setup UI shows validation stage and elapsed time throughout a
   slow load.
5. Grant microphone permission, enable **Nuvi Voice**, and select it from the
   keyboard picker.

Parakeet runs 16 kHz mono, greedy search, CPU provider, and starts at two
threads. Thread-count changes must be exposed through a real benchmark surface
before comparing 2/4/6 on an S24 Ultra; more threads are not assumed to be
faster.

## Whisper alternative

Select **Whisper** in Nuvi and import a multilingual legacy GGML `.bin` model.
`ggml-small-q5_1.bin` favors quality; `ggml-base-q5_1.bin` favors latency.
Native decodes never run in parallel because the private `:asr` service uses a
single worker. There is no silent fallback. Whisper uses an abort callback,
while cancellation or a deadline can also terminate the disposable service
process.

## Runtime recovery and error codes

The IME shows explicit **Finishing capture**, **Loading model**, and
**Transcribing locally** phases with elapsed time and a Cancel action.

- Capture settle deadline: 3 seconds.
- Inference deadline: `max(20 seconds, audio duration × 3)`, capped at 90 seconds.
- Empty output: `NO_SPEECH`, shown as “No speech detected”.
- Native model loading and decode run only in the private `:asr` service. PCM is
  transferred by read-only file descriptor rather than a Binder-sized array.
  The service owns one recognizer cache keyed by the coherent
  family + bundle path + bundle version snapshot.
- Startup uses a two-phase prepare/execute handshake. The service cannot enter
  native code until the client has acknowledged the request-bound remote PID,
  so cancellation before the initial reply never races native startup. Once
  native work begins, the dedicated service process terminates itself on
  cancellation; the client never kills a potentially recycled PID.
- Model loading has its own five-minute deadline. The audio-derived 20–90 second
  inference deadline starts only after `:asr` reports that the versioned engine
  is ready. Cancellation, Binder death, or either deadline can kill and rebind
  the private process; non-cancellable native decode never runs in the IME.

| Code | Meaning / action |
| --- | --- |
| `CAPTURE_TIMEOUT` | Microphone shutdown stalled; retry after closing other audio apps. |
| `ENGINE_TIMEOUT` | Local inference exceeded its deadline; use shorter audio or benchmark another thread/model option. |
| `ENGINE_BUSY` | Another ASR request is already active; cancel or wait for it to finish. |
| `CANCELLED` | The user, editor lifecycle, or stale generation cancelled the request. |
| `NO_SPEECH` | No audio or no usable transcript was produced. |
| `MODEL_MISSING` | Import a model for the selected engine. |
| `MODEL_INVALID` | The archive/file failed structure, bounds, checksum-header, or load validation. |
| `MODEL_COPY_TIMEOUT` | Archive copy/extraction stopped progressing or exceeded its import deadline. |
| `MODEL_PREFLIGHT_TIMEOUT` | Source inspection or storage/memory preflight exceeded 30 seconds. |
| `MODEL_LOAD_TIMEOUT` | Native engine initialization exceeded its five-minute absolute deadline. |
| `FGS_TIMEOUT` | Android ended the foreground import service; retry the import. |
| `MODEL_VALIDATION_FAILED` | Native engine initialization rejected the imported bundle. |
| `STORAGE_LOW` | Free at least 1.5 GB before importing Parakeet. |
| `MEMORY_PRESSURE` | Close other apps and retry; native validation was not started. |
| `IMPORT_INTERRUPTED` | The isolated importer stopped; staging was cleaned and the prior model remains active. |
| `IMPORT_CANCELLED` | Import was cancelled between streaming chunks; the prior model remains active. |
| `ENGINE_FAILED` | Native initialization or inference failed. |
| `IPC_FAILED` | The ASR process connection failed or the active editor rejected the transcript. |

Residual risk: sherpa-onnx does not expose a decode-abort callback for this
offline Parakeet path. Nuvi therefore treats `:asr` as a disposable native
boundary and kills it on timeout/cancellation. This protects the IME, but the
first dictation after a restart must reload the model. Physical S24 cold/warm
latency, memory, thermals, and transcript quality still require device evidence.

## Visual architecture

- Setup content uses opaque sections; optical glass is restricted to the sticky
  contextual action dock. There is no glass-on-glass nesting.
- The IME is a compact 232 dp surface with a state label, engine/offline badge,
  keyboard switch action, 80 dp ferrofluid voice control, elapsed status, and
  contextual Cancel action. It intentionally contains no fake keyboard keys.
- `FerrofluidView` uses an API 33+ AGSL `RuntimeShader` metaball field and a
  Canvas fallback for API 26–32. It consumes normalized RMS only.
- Idle is static; recording uses smoothed attack/release audio response;
  transcription renders at 30 fps; success settles at 220 ms; error is one-shot.
  Rendering stops when hidden/detached and respects animator-disabled, battery
  saver, high-contrast, and the reduced-transparency preference.
- Setup applies system-bar plus display-cutout safe insets to scrolling content,
  uses a 136 dp hero viewport, and renders a larger sharp-core ferrofluid with
  higher dark-theme contrast.
- The adaptive “Mercury aperture” icon is deterministic vector XML with
  foreground, monochrome, adaptive, round, and legacy resources. It contains no
  text, microphone cliché, Apple asset, or generated raster dependency.
- Model import is owned by a non-exported foreground `dataSync` service in the
  dedicated `:model_import` process. The setup Activity only reads an atomic
  journal and receives package-scoped coalesced broadcasts. Rotation detaches
  the old observer and restores stage/percent from disk without duplicate work.
- Import status never takes the heavyweight import lock. Progress writes and UI
  callbacks are deduplicated and limited to five updates per second; Cancel and
  the ferrofluid remain responsive during extraction and native validation.
- Import journal updates use an inter-process file lock, unique atomic
  temporaries, and first-terminal-wins semantics. Activation has a recoverable
  transaction journal; publishing the final candidate and activating its pointer
  share the model-state lock. Candidate-scoped staging cleanup revalidates the
  terminal journal under the import-job lock and cannot delete a newer import.
- Retired/orphan cleanup preserves per-process runtime lease files while a
  recognizer is loading or cached. Sanitized bounded diagnostics persist only
  request/stage, bundle version, PID, cause class, and load/decode timing—never
  audio or transcript text.

## Build and pinned dependencies

Prerequisites: JDK 17+, Android SDK 35, NDK r28c `28.2.13676358`, and CMake `3.22.1`.

```bash
cd android
./gradlew :app:testDebugUnitTest :app:assembleDebug :app:assembleRelease :app:lintRelease
```

- Gradle 8.9, AGP 8.7.3, Kotlin 2.0.21.
- NDK r28c plus explicit `max-page-size`/`common-page-size` 16384 linker
  options produce 16 KB ELF LOAD alignment. CI runs
  `scripts/verify-16k-alignment.sh` against every packaged `.so` and checks APK
  ZIP alignment with `zipalign -P 16`; compatibility mode is not used.
- Official `sherpa-onnx` AAR v1.13.4 is retrieved at build time from its GitHub
  release and verified against SHA-256
  `03f9c4df965f21c71269365a7951a7f23b5696fddd093fa318c80d65550ab780`.
- Official `whisper.cpp` source is pinned to v1.8.6 through CMake FetchContent.
- Apache Commons Compress 1.27.1 performs bounded streaming `.tar.bz2`
  extraction. Commons IO 2.17.0 is pinned explicitly.
- All runtime native libraries are restricted to `arm64-v8a` for the current
  S24 Ultra target.

Network is required only while resolving build dependencies. The installed APK
cannot open network sockets because it does not request the Android permission.

### Verification status — 2026-07-13

- 90/90 JVM unit and contract tests pass, including filesystem-only sherpa
  loading, process isolation, coherent snapshots, killable deadlines, cache
  replacement, runtime leases, activation recovery, terminal import races,
  archive abuse, stale-result rejection, and privacy contracts.
- The JVM task recompiles Kotlin and processes the merged debug manifest and
  resources. No fresh APK assembly, lint run, or physical-device validation was
  performed for this change.
- The previous 2026-07-12 packaging baseline assembled debug/release APKs,
  passed release R8/lint and 16 KB checks, contained `arm64-v8a` only, and had
  no `INTERNET` permission. A fresh package must be inspected before release.
- Both private services are declared `exported=false`; native ASR runs in
  `:asr`, and model import runs in `:model_import`.
- Setup queries enabled/selected keyboard state only through public
  `InputMethodManager` APIs. Selection is tri-state on platforms without the
  API 34 current-IME query; an unavailable query opens settings/picker instead
  of reading restricted `Settings.Secure` keys or claiming readiness.

## S24 Ultra benchmark checklist

After adding a controlled thread-count benchmark surface, use the same 30–60
second Spanish recording for Parakeet at 2/4/6 threads and Whisper at its
configured thread count:

- [ ] Cold load and warm transcription time
- [ ] Real-time factor and transcript quality for Peruvian Spanish
- [ ] Names, punctuation, Spanish/English switching, and background noise
- [ ] Peak memory and thermal throttling after ten minutes
- [ ] Battery drain over 20 dictations
- [ ] Cancel during model load and inference
- [ ] Automatic recovery after capture and engine deadlines
- [ ] Editor/app switch rejects stale results
- [ ] Secure fields remain locked
- [ ] Animation stops when the keyboard is hidden and in battery saver

## Architecture

```text
domain/          ModelFamily, ModelBundle, timing/errors, secure policy
application/     OfflineTranscriptionEngine, session/deadline orchestration
infrastructure/  AudioRecord, transactional model store, :asr IPC/cache, sherpa-onnx, whisper.cpp JNI
presentation/    setup, IME, optical control dock, ferrofluid renderer
```

Model activation uses immutable versioned files/directories, per-family atomic
pointer files, and a recoverable activation journal. Snapshot lease publication,
activation/recovery, and cleanup share one cross-process state lock. Previous
bundles are deleted only after active pointers and live runtime leases no longer
reference them.
Every editor transition
advances a generation token, and results commit only to the exact current
`InputConnection`.
