# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.4.36] - 2026-04-21

### Fixed
- Fixed media interruption resume for Spotify by recognizing Spotify's paused MediaRemote signature, so Voce can resume what it paused without loosening playback-state handling for Apple Music, Safari, or Chrome.

## [0.4.34] - 2026-04-21

### Fixed
- Fixed tap-to-talk media interruption so Voce no longer sends stray play/pause toggles that can wake Apple Music when no audio was previously playing.

## [0.4.33] - 2026-04-21

### Added
- Added a timed typing speed test that captures best WPM, live accuracy, and per-character feedback during onboarding and from Settings.
- Added a Help tab in Settings with a replayable practice walkthrough and common usage answers.

### Changed
- Reworked the onboarding flow so email verification, shortcut setup, typing speed, and hands-on shortcut practice happen in a clearer order.
- Rebuilt the learn-the-basics practice flow into a more guided scratch-pad lesson that teaches tap-to-talk, hold-to-talk, and dictionary fixes step by step.
- Updated the menu bar popover and Home history rows so copy actions and quick actions are clearer and provide immediate visual feedback.

### Fixed
- Fixed settings access verification so users can complete the email code flow from Settings without needing to return to Home.
- Fixed unsigned and first-run states so onboarding captures email verification earlier and blocked actions behave more predictably before access is verified.
- Fixed production shortcut actions, history heat map hover details, and several onboarding/settings layout issues on smaller windows.

## [0.4.32] - 2026-04-14

### Added
- Added direct dictionary and snippet capture shortcuts from selected text, including configurable shortcut mappings in Settings.
- Added a six-week activity calendar to Home so recent usage is easier to scan at a glance.

### Changed
- Reworked Dictionary and Snippets into editable table views with modal create and edit flows, inline grouping support, and cleaner delete affordances.
- Refined the in-flight dictation bubble menu so stop and AI finish actions are available directly from the overlay and better match the rest of the app.
- Updated AI re-run behavior so refreshing an AI workflow updates the existing history item instead of creating a duplicate entry.

### Fixed
- Fixed overlay dismissal timing so the dictation bubble drops away as soon as insertion finishes instead of lingering after paste.
- Fixed the home metrics rail by removing the stale latest-transcript panel and keeping activity counts stable when AI output is refreshed.

## [0.4.27] - 2026-04-11

### Changed
- The app now respects `System`, `Light Mode`, and `Dark Mode` consistently across the main window, onboarding, the menu bar popover, and the processing bubble so the visual theme stays in sync everywhere.
- The Home view now uses a scrollable scenic banner, refined right-rail metrics, and updated light/dark background crops that better show the sky and foreground scene.
- Settings now live in the main window with top tabs and more stable small-window behavior, which keeps the interface usable without clipping important controls.

### Fixed
- Hold-to-talk can now trigger AI finish actions from the keyboard the same way tap-to-talk can, so rewrite and related workflows work reliably in both recording modes.
- AI rewrite and summarize workflows now better enforce output-only responses by tightening the built-in prompts and stripping common assistant preambles from local-model output.
- Spoken AI trigger routing is more forgiving about punctuation and line breaks after phrases like `rewrite this`, and now gives a clearer error when the trigger phrase has no content after it.

## [0.4.26] - 2026-04-10

### Added
- Added a guided onboarding practice step so new users can test the hotkeys they enabled before they start using Voce.
- Added conservative automatic bullet and numbered-list formatting for explicit list dictation cues like `bullet list`, `numbered list`, and strong `first / second / third` sequences.

### Changed
- Rebuilt the main app shell, Home, Settings, onboarding, Dictionary, Snippets, and Style surfaces around a more consistent frosted-glass layout with clearer controls and tighter copy.
- Moved custom spoken shortcuts and learned shortcut suggestions into Snippets, leaving Dictionary focused on corrections.
- Simplified onboarding and settings to match the new Apple Speech-only flow, including cleaner permission guidance and clearer hotkey setup.
- Removed live transcript preview from the overlay so the recording bubble stays visually stable during dictation.

### Fixed
- Fixed the processing bubble and related overlay transitions so they no longer jump between states at the start or end of dictation.
- Fixed release-upgrade behavior so older installs preserve the historical hold-to-talk default when the preference key was previously absent.
- Fixed Home permission alerts and statistics so missing permissions surface in the right rail and metrics no longer blank or inflate unexpectedly around the daily rollover.

## [0.4.24] - 2026-03-25

### Fixed
- The main app window no longer swallows the first click in some hidden-titlebar/full-size-content configurations, because background dragging is now disabled for that window style.
- Media interruption behavior is less brittle again: likely-playing state can pause media, and resume is allowed when playback looks stopped or unknown, which restores the smoother real-world pause/resume flow.

## [0.4.23] - 2026-03-25

### Added
- Added a built-in `AI Prompt` workflow that turns rough dictation into a clearer prompt for an AI assistant, with a default period-key hands-free finish shortcut.

### Changed
- AI workflow prompt generation now uses each workflow's effective prompt template consistently, so built-in workflows can ship sensible defaults while still allowing explicit overrides.
- The AI workflows settings table now uses inline toggles for every workflow and a more consistent edit/delete control layout.
- Media interruption now only pauses on confirmed `playing` state and only resumes on confirmed `notPlaying` state, avoiding extra play/pause key presses when playback state is merely likely or unknown.

## [0.4.22] - 2026-03-25

### Added
- Added Apple Intelligence-powered AI workflows with built-in Ask, Rewrite, and Summarize actions, plus support for custom prompt workflows and optional hands-free finish keys.
- Added an AI settings section so workflows, trigger phrases, availability, and hands-free routing can be configured from the app.

### Changed
- Dictation finalization now routes through a completion pipeline that can insert normally, insert-and-submit, or send cleaned text through an AI workflow before insertion.
- History and session flow now keep richer completion metadata so AI-assisted output and alternate finish actions can be tracked more clearly.

### Fixed
- Media interruption now confirms that playback actually paused before keeping a resume token, which avoids accidental resumes when the pause key press doesn't stick.
- Settings diagnostics now surface speech recognition and related permission state more clearly alongside the new AI workflow controls.

## [0.4.21] - 2026-03-25

### Changed
- The processing state now plays a looping background video instead of the previous layered pulse treatment, giving the bubble a fuller sense of motion while transcription finishes.
- The processing background video is now bundled as an app resource so release builds show the same effect as local development previews.

## [0.4.20] - 2026-03-24

### Changed
- The dictation overlay now stays visually continuous from the opening `Transcribing…` shell through live partials, processing, and insertion states instead of blinking between separate bubbles.
- Processing now reveals the field painting more clearly with a softer motion treatment, so the bubble feels like the same object finishing the thought instead of an empty placeholder.

### Fixed
- Clipboard-backed auto-paste now reports a real insertion success, so the bubble shows the same success pop when paste actually lands.
- Fixed background image clipping on the right edge of the overlay by keeping the layered painting surfaces in sync with live bubble resizing.
- Prevented a hotkey-registration failure callback from hiding the startup transcript bubble mid-session, which removes the distracting disappear-and-reopen effect when the first live transcript arrives.

## [0.4.15] - 2026-03-20

### Added
- Hands-free dictation can now end and submit with `Return` as an optional setting, so click-to-start capture works better in chat boxes and command bars.

## [0.4.14] - 2026-03-20

### Added
- Hold-to-talk hotkeys can now use real modifier chords such as `Control+Option`, which reduces accidental recordings when one modifier is part of another shortcut.

### Fixed
- The record screen now suppresses stale microphone/accessibility/input-monitoring warnings once the relevant permission has already been granted.
- Media interruption pause/resume behavior is smoother and less jittery during quick dictation starts and stops.

## [0.4.13] - 2026-03-17

### Changed
- Settings now save automatically as soon as changes are made, so there is no separate `Save & Apply` step to miss.
- Removed the manual save button from the settings screen and clarified that changes persist immediately.

## [0.4.12] - 2026-03-17

### Fixed
- Removed the broken `Base Streaming` Moonshine preset from Voce's supported model picker, because its upstream CDN files now return `404`.
- Migrated saved `Base` and `Base Streaming` selections to `Small Streaming` so existing installs recover automatically instead of continuing to fail model downloads.

## [0.4.11] - 2026-03-17

### Added
- Added a scenic frosted-glass app shell, refreshed record-screen background treatment, and updated macOS app icon artwork.
- Added click-to-capture global hands-free hotkey selection, including support for modifier-style keys such as Globe/Fn.

### Changed
- Reorganized settings into a sidebar-based layout with clearer grouping and switch-style toggles.
- Simplified the transcription model picker to show only supported streaming models with more helpful guidance.
- Improved permission guidance with smaller, more actionable messaging and direct deep links to the relevant macOS privacy panes.

### Fixed
- Bounded live Moonshine microphone backlog growth so long dictation sessions cannot queue unbounded audio in memory when the stream falls behind real time.
- Coalesced queued live-audio chunks before feeding Moonshine, which reduces `addAudio(...)` call pressure during sustained speech.
- Live dictation now stops immediately and shows a clear failure message when the system falls too far behind to keep up with microphone streaming.
- Made hold-to-talk configuration more flexible so `Option` is no longer effectively reserved, reducing collisions with common system shortcuts.

## [0.4.10] - 2026-03-12

### Fixed
- Made push-to-talk finalization more resilient by using a shared tail policy, better transcript settling, and improved stop diagnostics so live dictation is less likely to clip the end of an utterance.
- Prevented cleanup from stripping meaning-bearing endings such as "what I mean" and collapsed exact adjacent repeated phrase runs that sometimes appeared in live Moonshine output.

### Changed
- Simplified the dictation overlay into a single transcript-focused preview that stays visible while finalizing, keeps a rolling three-line partial transcript, and stops flashing separate success states.
- Added a `Keep model warmed in memory` setting so fast startup remains the default while allowing lower idle memory usage when desired.

## [0.4.9] - 2026-03-11

### Fixed
- Reduced clipped endings in live Moonshine dictation by using CoreAudio buffer timestamps instead of tap-callback timing when deciding what audio belongs before key release.
- Push-to-talk release now keeps a short speech-aware capture tail so the final word can finish naturally before the stream is finalized, with a hard cap to keep stop responsive.

## [0.4.8] - 2026-03-11

### Fixed
- Restored the Sparkle updater configuration in the shipped app bundle by moving update keys into a real Info.plist, which fixes the disabled "Check for Updates" state.
- The updater now starts eagerly and publishes its availability state correctly to the settings UI.

### Changed
- Voce now enables automatic background update checks by default while still leaving automatic download/install disabled.

## [0.4.7] - 2026-03-11

### Fixed
- Final live Moonshine transcripts now wait for captured audio to drain and for the transcript to stabilize before insertion, reducing clipped endings when you release the push-to-talk key.
- Buffers that overlap key release are trimmed to the release point instead of being treated as all-or-nothing, so the final phrase is less likely to be cut off.

## [0.4.6] - 2026-03-11

### Fixed
- Preserved unsaved settings drafts when switching between tabs.
- Preserved in-progress settings edits when collapsing and reopening settings groups.
- Updated "Last transcript" actions to operate on the current transcript text immediately after dictation finishes.
- Scoped transparent window styling to the main Voce window instead of affecting every app window.
- Improved UI readability with denser adaptive backgrounds and overlay surfaces so content stays legible over dark desktops.

## [0.4.5] - 2026-03-11

### Fixed
- Removed the temporary file-transcription fallback from live dictation after validating the native-sample-rate Moonshine microphone path with Bluetooth AirPods input.
- Live Moonshine streaming now preserves the microphone's native sample rate instead of forcing app-side resampling, which restores healthy input amplitude for devices like AirPods that capture at 24 kHz.
- Preloaded and reused the active Moonshine transcriber so repeat recordings start faster once the model is warm.
- Refreshed the macOS app icon artwork.
- Improved the dictation overlay's anchoring heuristics by capturing the focused field before recording starts and using text-marker based caret bounds when apps expose them.

## [0.4.4] - 2026-03-11

### Fixed
- Dictation now keeps a file recording running alongside live Moonshine streaming and falls back to file-based transcription automatically when live capture returns no speech.

## [0.4.3] - 2026-03-11

### Fixed
- Reworked live Moonshine microphone streaming to feed audio to the stream immediately instead of batching it through the custom timer queue, matching Moonshine's upstream mic transcriber more closely.
- Empty live captures now fail with a visible microphone/transcription error instead of silently creating blank transcript history entries.

## [0.4.2] - 2026-03-11

### Fixed
- Sparkle update checks now provide the appcast URL via `SPUUpdaterDelegate` as a runtime fallback, so "Check for Updates" works even when the generated `Info.plist` omits `SUFeedURL`.

## [0.4.1] - 2026-03-11

### Fixed
- Recording startup now validates microphone access before switching into the listening UI, so permission failures are surfaced instead of looking like a ready-but-dead recorder.
- Moonshine streaming now flushes buffered audio correctly on stop, preserves finalization errors instead of silently returning an empty transcript, and uses a mic capture path closer to Moonshine's upstream implementation.
- Engine readiness checks now verify the configured model directory rather than only the preset default path, preventing false "model ready" states in settings.

## [0.1.7] - 2026-03-03

### Changed
- Hardened hotkey lifecycle and shutdown behavior to avoid late callback execution during stop/quit, including idempotent teardown and eager overlay window warm-up.
- Updated synthetic event routing so insertion and paste remain configurable through `STENO_SYNTH_EVENT_TAP`, while media keys use a dedicated tap resolver with HID as the default.
- Improved subprocess execution reliability by streaming pipe output during process lifetime, adding cancellation escalation safeguards, and caching whisper process environment setup at engine initialization.
- Optimized local cleanup and replacement paths by precompiling reusable regexes, caching lexicon/snippet regexes with cache invalidation on mutation, and preserving longest-first lexicon ordering as an explicit invariant.
- Reduced history persistence overhead by removing pretty-printed JSON output formatting.

### Fixed
- Restored reliable media pause/resume behavior during dictation by routing media key posting through a dedicated HID-default tap path.
- Prevented event-tap re-enable thrash with debounce handling after timeout/user-input tap disable events.
- Added defensive teardown behavior for overlay timers and hotkey monitor resources during object deinitialization.
- Prevented potential deadlocks and cancellation stalls in process execution paths when child processes ignore graceful termination.

### Tests
- Added media key tap routing regression coverage for default, override, and invalid environment values.
- Hardened cancellation regression coverage to verify bounded completion when subprocesses ignore `SIGTERM`.

## [0.1.6] - 2026-03-03

### Added
- Added `Voce/Voce.entitlements` and wired entitlements via `project.yml` for microphone access and DYLD environment behavior needed by local `whisper.cpp` builds.
- Added `StenoKitTestSupport` as a dedicated package target for test doubles used by `StenoKitTests`.

### Changed
- Updated insertion transport internals to use private event source state, async pacing (`Task.sleep`), and best-effort caret restoration after accessibility insertion.
- Updated permission and window behavior paths to be more predictable on macOS 13/14+, including safer main-window targeting and refreshed input-monitoring recheck flow.
- Moved persistent storage fallbacks for preferences/history to `~/Library/Application Support` (instead of temp storage) and reduced path visibility in logs.
- Updated app activation and SwiftUI `onChange` call sites to align with modern macOS APIs.

### Fixed
- Audio capture now surfaces recorder preparation/encoding failures and cleans temporary files on early failure paths.
- MediaRemote bridge teardown now drains callback queue before unloading framework handles.
- Overlay status-dot color transitions now animate through Core Animation transactions and respect live accessibility display option updates.
- Improved lock/continuation safety documentation in cancellation-sensitive concurrency paths.

### Removed
- Removed dead `TokenEstimator` utility.
- Removed production-exposed test adapter definitions from `StenoKit` main target and relocated them to `StenoKitTestSupport`.

## [0.1.5] - 2026-02-28

### Added
- Refreshed macOS app icon artwork in `Voce/Assets.xcassets/AppIcon.appiconset`.

### Changed
- Pivoted cleanup to local-only. Voce now runs transcription and cleanup fully on-device with no cloud cleanup mode.
- Removed API key onboarding/settings flow and cloud-mode status messaging to simplify setup and avoid mixed local/cloud behavior.
- Settings now use a draft-and-apply flow to avoid mutating preferences during view updates.
- Press-to-talk now attempts media interruption before starting audio capture.

### Fixed
- Media interruption detection now requires corroborating now-playing data before trusting playback-state-only signals. This prevents false `notPlaying` decisions when MediaRemote returns fallback state values with missing playback rate (including browser `Operation not permitted` probe paths).
- Weak-positive playback signals now require a short confirmation pass before sending play/pause, reducing phantom media launches when no audio is active.
- Preserved unknown-state safety behavior so playback control is skipped when media state is not trustworthy.

### Removed
- OpenAI cleanup integration (`OpenAICleanupEngine`) and remote cleanup wiring (`RemoteCleanupEngine`).
- Cloud budget and model-tier plumbing (`BudgetGuard`, cloud cleanup decision types, and cloud-only tests).

### Breaking for StenoKit Consumers
- `CleanupEngine.cleanup` removed the `tier` parameter.
- `CleanTranscript` removed `modelTier`.
- Cloud cleanup engines and budget types were removed from the package surface.

### Notes
- This release consolidates the media interruption hotfix work and local-only cleanup pivot into one tagged release (`v0.1.5`).

## [0.1.2] - 2026-02-23

### Added
- First-pass macOS app icon set in `Voce/Assets.xcassets/AppIcon.appiconset` with a stenography-inspired glyph

### Removed
- Tracked generated Xcode project files (`Voce.xcodeproj/*`) from source control

## [0.1.1] - 2026-02-21

### Added
- Benchmark tooling in `StenoKit` via `StenoBenchmarkCLI` and `StenoBenchmarkCore` (manifest parsing, run orchestration, scoring, report generation, and pipeline validation gates)
- Local cleanup candidate generation and ranking (`RuleBasedCleanupCandidateGenerator`, `LocalCleanupRanker`, and `CleanupRanking`)
- Polished README screenshots (`assets/record.png`, `assets/history.png`, `assets/settings-top.png`, and `assets/settings-bottom.png`)

### Changed
- Rule-based cleanup flow now integrates ranking-focused post-processing refinements for better transcript quality
- Onboarding and settings screens use clearer plain-language copy for first-run setup and configuration
- `README.md`, `QUICKSTART.md`, and `CONTRIBUTING.md` were reworked for clearer user and contributor onboarding

### Fixed
- Balanced filler cleanup preserves meaning-bearing uses of "like"
- Media interruption handling avoids phantom playback launches from stale/weak-positive playback signals

### Removed
- Security audit workflow and related badge from repository CI/docs

### Tests
- Expanded benchmark validation tests for scorer/report/pipeline gates
- Added cleanup accuracy and ranking behavior coverage
- Added media interruption regression coverage for stale signal handling
