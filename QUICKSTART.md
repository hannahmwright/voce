# Voce Quickstart

Fastest path to run Voce locally on macOS.

## 1) Clone and generate the Xcode project

```bash
git clone https://github.com/Ankit-Cherian/steno.git
cd steno
xcodegen generate
```

Expected result: local `Voce.xcodeproj` is up to date (it is generated from `project.yml` and intentionally not tracked in git).

## 2) Run in Xcode

1. Open `Voce.xcodeproj`.
2. Set your Apple Developer Team in Signing & Capabilities.
3. Run scheme `Voce` (`Cmd+R`).
4. The onboarding wizard will guide you through:
   - Granting permissions (Microphone, Accessibility, Input Monitoring)
   - Downloading the Moonshine transcription model (~160 MB)

## Cleanup behavior

Voce runs transcription and cleanup fully locally with no cloud text cleanup step.

## Verify setup quickly

- Press and hold your configured hold-to-talk keys to record, then release to transcribe.
- Toggle hands-free mode using the configured function key (default `F18`).
- Confirm text output works in both a text editor and a terminal.

## If something fails

- `xcodegen: command not found`: run `brew install xcodegen`.
- Hotkeys not responding: check Accessibility + Input Monitoring permissions in macOS Settings and relaunch Voce.
- Model download failing: check your internet connection and try again from Settings > Engine.
