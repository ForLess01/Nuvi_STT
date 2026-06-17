# Nuvi

<p align="center">
  <img src="Resources/cover.png" alt="Nuvi Cover Art" width="100%">
</p>

Nuvi is a native macOS menu-bar dictation app featuring a floating pill, a Metal-based ferrofluid visualizer, global hotkeys, and on-device speech-to-text transcription that automatically inserts text into the focused application.

Built purely in Swift, AppKit, SwiftUI, AVFoundation, and Metal. No Electron. No Python runtime dependencies.

## Demo

<p align="center">
  <img src="Resources/NUVI_STT.gif" alt="Nuvi Demo" width="100%">
</p>

## Verified status

Verified in this repository on **2026-06-16**:

- `swift build` ✅
- `./scripts/build-app.sh release` ✅
- `swift test` ✅ 5 regression tests

Important: the repo currently documents some historical engine claims, but it
does **not** include benchmark artifacts that prove relative WER/speed numbers.
This README keeps only what is verifiable from the codebase.

## Runtime target

- **Minimum OS**: macOS **26.0** (`Package.swift` and `Resources/Info.plist`)
- **Architecture**: Apple Silicon
- **App style**: menu-bar agent (`LSUIElement` / `.accessory`)

## Current engine behavior

Nuvi exposes three engine preferences:

- **`speechAnalyzer`** — current default in `SettingsStore`
- **`auto`** — `HybridTranscriptionEngine` (SpeechAnalyzer primary, WhisperKit fallback)
- **`whisperKit`** — direct WhisperKit selection

This matters because older docs in the repo incorrectly said that `auto` was
the default. It is **not** the default right now; `speechAnalyzer` is.

## Models and offline dictation

Transcription models are **not** bundled directly inside the Git repository to keep the download size lightweight. Instead, Nuvi manages and downloads models dynamically:

- **`speechAnalyzer` (Apple Speech)**: 
  Uses the native macOS on-device speech recognizer.
  - **Models used**: Apple's native Siri/Dictation on-device models.
  - **Setup**: To ensure high-quality offline dictation without internet connectivity, make sure your target language is downloaded locally on your Mac:
    1. Open **System Settings (Ajustes del Sistema) → Keyboard (Teclado) → Dictation (Dictado)**.
    2. Turn on Dictation and select/download your preferred languages.
  
- **`whisperKit` / `auto`**:
  Uses CoreML-optimized Whisper models running natively on Apple Silicon.
  - **Models used**:
    - **Default**: `openai_whisper-tiny` (Fast, low resource footprint).
    - **Supported variants**: You can download and run other sizes (such as `base`, `small`, `medium`, or `large`) directly through the application's built-in models manager.
  - **Setup**: The model is downloaded automatically from Hugging Face the first time you record or when you open the **Models library** in the Settings UI. 
  - **Cache location**: Models are saved and cached locally in:
    `~/Library/Application Support/Nuvi/WhisperKit/`
  - *No manual downloads or terminal installations are required* for the models.

## Architecture

```text
Sources/Nuvi/
├── App/
│   ├── NuviApp.swift
│   ├── AppEnvironment.swift
│   └── Probe.swift
├── Application/
│   ├── DictationController.swift
│   └── HotkeyManager.swift
├── Domain/Dictation/
│   ├── DictationState.swift
│   ├── TranscriptionEngine.swift
│   └── TranscriptionModels.swift
├── Infrastructure/
│   ├── Audio/
│   ├── Hotkey/
│   ├── Modes/
│   ├── Output/
│   ├── Settings/
│   └── Speech/
└── Presentation/
    ├── Ferrofluid/
    ├── MenuBar/
    ├── Pill/
    └── Settings/
```

Design intent is hexagonal around the transcription port:

- `TranscriptionEngine` is the main domain port.
- `SpeechAnalyzerEngine`, `WhisperKitEngine`, and `HybridTranscriptionEngine`
  are adapters.
- `DictationController` orchestrates microphone → engine → post-processing →
  insertion.

One correction versus older docs: `AudioCaptureService` is currently a
**concrete infrastructure service**, not a domain port.

## Installation and Setup

### 1. Build and Install

Nuvi is compiled directly from the source code. Follow these simple steps to install it:

1. Clone this repository to your local machine:
   ```bash
   git clone git@github.com:ForLess01/Nuvi_STT.git
   cd Nuvi_STT
   ```
2. Build the production app bundle using the release script:
   ```bash
   ./scripts/build-app.sh release
   ```
3. Open the compiled application:
   ```bash
   open build/Nuvi.app
   ```
   *Tip: You can drag and drop `Nuvi.app` from the `build` folder into your `/Applications` directory to install it permanently.*

---

### 2. macOS System Permissions

Since Nuvi runs as a menu-bar agent that captures audio and automatically types the transcribed text for you, macOS requires the following permissions to be granted on its first launch:

- **Microphone (Micrófono)**:
  - **Why**: Required to capture your voice input for transcription.
  - **How to grant**: Go to **System Settings (Ajustes del Sistema) → Privacy & Security (Privacidad y Seguridad) → Microphone (Micrófono)** and toggle the switch on for **Nuvi**.
  
- **Accessibility (Accesibilidad)**:
  - **Why**: Required to automatically inject and paste the transcribed text directly at the cursor location of whichever app you are currently using.
  - **How to grant**: Go to **System Settings (Ajustes del Sistema) → Privacy & Security (Privacidad y Seguridad) → Accessibility (Accesibilidad)** and add/enable **Nuvi** in the allowed applications list.
  
> [!NOTE]
> If you do not grant **Accessibility** permissions, Nuvi will fallback to copying the transcribed text to your **Clipboard** so you can paste it manually.

## Usage

- **⌥ Space** — toggle dictation (default, user-rebindable)
- **Push to Talk** — optional hold-to-record shortcut
- **⌥⇧K** — cycle mode (default, user-rebindable)
- **Esc** — cancel active recording

Shortcuts are configured in **Settings → Configuration → Keyboard Shortcuts**.

## Implemented features

- Floating pill (`NSPanel`) that stays out of the way of the focused app
- Live ferrofluid visualizer rendered with Metal
- Menu-bar control surface
- SpeechAnalyzer adapter
- WhisperKit adapter
- Hybrid engine adapter
- Vocabulary replacement rules
- History persistence
- Modes with formatting / affixes / optional auto-activation by frontmost app
- Launch-at-login toggle
- Shortcut recording, including modifier-only push-to-talk
- Headless probe mode (`Nuvi --probe <audio-file> [locale]`)

## Known gaps

- Test coverage is still small; the initial regression suite covers vocabulary,
  mode resolution, retry after engine errors, and cancel-without-delivery
- WhisperKit currently transcribes in batch after recording stops; it does not
  stream partials
- SpeechAnalyzer probe results are machine/asset dependent

## Engine verification workflow

The repo includes a headless probe mode so you can verify engine behavior on a
real machine without using the UI:

```bash
say -o /tmp/t.aiff "hola, esto es una prueba de dictado"
"$(swift build -c release --show-bin-path)/Nuvi" --probe /tmp/t.aiff es-ES
```

That command is the correct verification path, but its output is machine- and
asset-dependent, so this README does not hardcode a claimed result anymore.
