# Contributing to Steno

Thank you for your interest in contributing to Steno. This guide will help you get started with development.

If you only want to run the app as a user, use [QUICKSTART.md](QUICKSTART.md) first. This document is contributor-focused.

## Prerequisites

Before you begin, ensure you have:

- macOS 13.0 or later
- Xcode 26 or later (Swift 6.2+)
- XcodeGen installed (`brew install xcodegen`)

## First-Time Setup

1. Clone the repository:
   ```bash
   git clone https://github.com/Ankit-Cherian/steno.git
   cd steno
   ```

2. Generate the local Xcode project:
   ```bash
   xcodegen generate
   ```

3. Open your local `Steno.xcodeproj` in Xcode.

4. In Xcode, set your own Apple Developer Team in Signing & Capabilities.

5. Build and run (Cmd+R). The onboarding wizard will download the Moonshine transcription model automatically.

## Code Style

Steno follows strict conventions to maintain code quality and consistency.

### Swift 6 Strict Concurrency

- All types must be `Sendable`
- Use actors for mutable shared state
- Mark UI code with `@MainActor`
- Avoid `@unchecked Sendable` unless absolutely necessary (e.g., bridging to C callbacks)
- All domain models must be `Sendable + Codable + Equatable` value types

### Design System

- **Never hardcode fonts, shadows, spacing, or colors**
- Use `VoceDesign` tokens for all UI elements:
  - Typography: `VoceDesign.heading1()`, `VoceDesign.body()`, etc.
  - Shadows: `.shadowStyle(.sm)`, `.shadowStyle(.md)`, `.shadowStyle(.lg)`
  - Spacing: `VoceDesign.spacingXs`, `VoceDesign.spacingSm`, etc.
  - Colors: `VoceDesign.adaptive(light:dark:)` for light/dark mode support
- Use component helpers from `DesignSystem.swift` (e.g., `CopyButtonView`, `PressableButtonStyle`)

### Accessibility

- Add `.accessibilityLabel()` to all interactive elements
- Use `.accessibilityAddTraits(.isHeader)` on section headers
- Use `.accessibilityHint()` for complex interactions
- Check `@Environment(\.accessibilityReduceMotion)` for all animations
- In AppKit code, use `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`

### Animation Conventions

Every animation must respect Reduce Motion:

```swift
@Environment(\.accessibilityReduceMotion) private var reduceMotion

// Conditional animation
.animation(reduceMotion ? nil : .easeInOut(duration: VoceDesign.animationNormal), value: state)

// Conditional transition
.transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))

// Conditional withAnimation
withAnimation(reduceMotion ? nil : .easeInOut(duration: VoceDesign.animationNormal)) {
    // state changes
}
```

### General Guidelines

- No force unwraps (`as!`, `try!`) — handle errors explicitly
- No singletons (`static let shared`) — use dependency injection
- No `print()` statements — use structured logging if needed
- Protocol-first design: define protocols in `VoceKit/Sources/VoceKit/Protocols/`, implementations in `Services/`
- Test doubles go in `Sources/` (not `Tests/`) for reusability

## Testing

Steno uses Swift Testing (not XCTest) with tests in `VoceKit/Tests/`.

Run all tests:

```bash
cd VoceKit
CLANG_MODULE_CACHE_PATH=/tmp/voce-clang-cache \
SWIFT_MODULECACHE_PATH=/tmp/voce-swift-cache \
swift test
```

Run a single test by function name:

```bash
cd VoceKit
CLANG_MODULE_CACHE_PATH=/tmp/voce-clang-cache \
SWIFT_MODULECACHE_PATH=/tmp/voce-swift-cache \
swift test --filter sessionCoordinatorLocalFallbackOnPrimaryFailure
```

When adding new features:

- Write tests for business logic in `VoceKit/Tests/`
- Use protocol-based test doubles (see `Sources/VoceKitTestSupport/Adapters.swift` and `InsertionTransports.swift`)
- No UI tests — SwiftUI views are tested manually

## XcodeGen Workflow

The Xcode project is generated from `project.yml`. `Steno.xcodeproj` is intentionally untracked in git and should be generated locally when needed.

After modifying `project.yml` or adding/removing Swift files in `Steno/`:

```bash
xcodegen generate
```

## Code Signing & TCC Permissions

Code signing must remain stable across builds. Changing the `DEVELOPMENT_TEAM` or code signing identity invalidates macOS TCC (Transparency, Consent, and Control) permissions, requiring users to re-grant Microphone, Accessibility, and Input Monitoring access.

Tracked source uses contributor-first signing defaults (in `project.yml`):
- No fixed `DEVELOPMENT_TEAM` value is committed
- `CODE_SIGN_STYLE: Automatic`
- `CODE_SIGN_IDENTITY: Apple Development`

Maintainers should keep their personal Team ID in local Xcode settings (or local xcconfig), not in committed source.

Maintainer release-signing flow:
1. Open `Steno.xcodeproj` -> target `Steno` -> Signing & Capabilities.
2. Set `Team` to your Apple Developer account team.
3. Keep `Bundle Identifier` unique to your account if required by your signing setup.
4. Build/archive from your local machine; do not commit team-specific signing changes.

Do not change signing settings without understanding TCC implications.

## Pull Request Checklist

Before submitting a PR:

- [ ] All code builds without warnings
- [ ] Tests pass (`swift test` in `VoceKit/`)
- [ ] UI uses `VoceDesign` tokens (no hardcoded fonts/shadows/spacing)
- [ ] Accessibility labels added to all interactive elements
- [ ] Animations respect `accessibilityReduceMotion`
- [ ] No force unwraps, no singletons, no `print()` statements
- [ ] `xcodegen generate` run locally after `project.yml` or app source layout changes
- [ ] No generated `Steno.xcodeproj` files staged in the PR
- [ ] Code follows Swift 6 strict concurrency rules
- [ ] Commit messages are clear and concise


## Architecture Deep-Dive

Key architectural concepts:

- Two-layer structure (`VoceKit/` pure Swift package + `Steno/` app target)
- Session lifecycle and recording state machine
- Hotkey mechanism (CGEventTap for function keys, NSEvent for Option key)
- Insertion chain (target-aware routing)
- Local cleanup pipeline with fallback behavior
- Media interruption (token-based pause/resume)
  - Playback-state trust rule: only trust playback-state evidence when now-playing metadata corroborates it (`playbackRate` present or `nowPlaying == true`), and confirm weak-positive signals before pausing media.
- Concurrency model (actors vs @MainActor)

## Getting Help

If you encounter issues or have questions:

- Review existing code for patterns
- Open a GitHub Issue for bugs or feature requests
- For security reports, follow `SECURITY.md`

We appreciate your contributions to Steno.
