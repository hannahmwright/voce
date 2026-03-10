# Steno

Fast macOS voice-to-text with smart app-aware insertion and optional text cleanup.

Steno is built for a premium dictation workflow without subscription lock-in: high-accuracy local transcription with [Moonshine](https://github.com/moonshine-ai/moonshine), fast hotkeys, and reliable text output across apps.

[![Swift Tests](https://github.com/Ankit-Cherian/steno/actions/workflows/swift-tests.yml/badge.svg)](https://github.com/Ankit-Cherian/steno/actions/workflows/swift-tests.yml)

## Choose Your Path

- **I want to use Steno**: follow [QUICKSTART.md](QUICKSTART.md) or the quick setup below.
- **I want to contribute**: start with [CONTRIBUTING.md](CONTRIBUTING.md) and the architecture notes below.

## What Steno Does

- High-accuracy local transcription with Moonshine (audio never leaves your Mac)
- Automatic model download on first launch (~160 MB for the recommended model)
- Smart app-aware paste (target-aware insertion): terminals prefer paste, editors use direct typing or accessibility insertion
- Local transcript cleanup (no cloud dependency)
- Global hotkeys: Option hold-to-talk and configurable hands-free toggle
- Menu bar app with status overlay
- 30-day transcript history with search
- Personal lexicon, style profiles, and snippets
- VoiceOver accessibility support

## Screenshots

<table>
  <tr>
    <td><img src="assets/record.png" alt="Record tab — hands-free recording with live transcript" width="400"></td>
    <td><img src="assets/history.png" alt="History tab — searchable transcript history" width="400"></td>
  </tr>
  <tr>
    <td><img src="assets/settings-top.png" alt="Settings — permissions, recording, and engine setup" width="400"></td>
    <td><img src="assets/settings-bottom.png" alt="Settings — cleanup style and text shortcuts" width="400"></td>
  </tr>
</table>

## Requirements

- macOS 13.0+
- Xcode 26+ (Swift 6.2+)
- XcodeGen (`brew install xcodegen`)

## Quick Setup

1. Clone the repository:
   ```bash
   git clone https://github.com/Ankit-Cherian/steno.git
   cd steno
   ```

2. Generate the local Xcode project (generated from `project.yml`, not tracked in git):
   ```bash
   xcodegen generate
   ```

3. Open your local `Steno.xcodeproj` in Xcode and set your Apple Developer Team in Signing & Capabilities.

4. Build and run (Cmd+R).

5. The onboarding wizard will guide you through:
   - Granting permissions (Microphone, Accessibility, Input Monitoring)
   - Downloading the Moonshine transcription model (~160 MB)

## Usage

- **Option Hold-to-Talk**: hold Option to record, release to transcribe and insert
- **Hands-Free Toggle**: press the configured function key (default `F18`) to start/stop recording
- **Menu Bar**: Click icon to show app window, right-click for quick actions
- **Recording Modes**: Press-to-talk (immediate recording) or hands-free (toggle on/off)
- **Text Output**: app-aware routing picks the safest insertion method for your current app

## Verify Setup

- Hold `Option` to record and release to transcribe.
- Use the hands-free toggle key (default `F18`).
- Confirm insertion works in both a text editor and a terminal.

## Architecture (Contributor View)

Steno uses a two-layer design:

- **`MurmurKit/`**: pure Swift package with business logic, protocols, models, and services (no UI)
- **`Steno/`**: SwiftUI app target with views, `DictationController` orchestration, and settings persistence

Key patterns: protocol-first dependency injection, actor isolation, no singletons, `Sendable` value types.

## Testing (Contributor View)

Run the core package tests from the repository root:

```bash
cd MurmurKit
CLANG_MODULE_CACHE_PATH=/tmp/murmur-clang-cache \
SWIFT_MODULECACHE_PATH=/tmp/murmur-swift-cache \
swift test
```

Run a single test by function name:

```bash
cd MurmurKit
CLANG_MODULE_CACHE_PATH=/tmp/murmur-clang-cache \
SWIFT_MODULECACHE_PATH=/tmp/murmur-swift-cache \
swift test --filter sessionCoordinatorLocalFallbackOnPrimaryFailure
```

## Known Limitations

- macOS only (no Windows/Linux desktop target yet)
- Full end-to-end behavior depends on user-granted macOS permissions
- Cleanup runs locally only

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, code style guidelines, and PR process.

## Security

See [SECURITY.md](SECURITY.md) for vulnerability reporting and response expectations.

## Support

See [SUPPORT.md](SUPPORT.md) for usage help and bug report paths.

## License

MIT — see [LICENSE](LICENSE) file for details.
