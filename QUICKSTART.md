# Steno Quickstart

Fastest path to run Steno locally on macOS.

## 1) Clone and generate the Xcode project

```bash
git clone https://github.com/Ankit-Cherian/steno.git
cd steno
xcodegen generate
```

Expected result: local `Steno.xcodeproj` is up to date (it is generated from `project.yml` and intentionally not tracked in git).

## 2) Run in Xcode

1. Open `Steno.xcodeproj`.
2. Set your Apple Developer Team in Signing & Capabilities.
3. Run scheme `Steno` (`Cmd+R`).
4. The onboarding wizard will guide you through:
   - Granting permissions (Microphone, Accessibility, Input Monitoring)
   - Downloading the Moonshine transcription model (~160 MB)

## Cleanup behavior

Steno runs transcription and cleanup fully locally with no cloud text cleanup step.

## Verify setup quickly

- Press and hold `Option` to record, release to transcribe.
- Toggle hands-free mode using the configured function key (default `F18`).
- Confirm text output works in both a text editor and a terminal.

## If something fails

- `xcodegen: command not found`: run `brew install xcodegen`.
- Hotkeys not responding: check Accessibility + Input Monitoring permissions in macOS Settings and relaunch Steno.
- Model download failing: check your internet connection and try again from Settings > Engine.
