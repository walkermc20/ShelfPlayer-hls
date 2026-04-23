# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ShelfPlayer is a native iOS app (Swift 6, iOS 26+) for listening to audiobooks and podcasts from self-hosted [Audiobookshelf](https://www.audiobookshelf.org/) servers. It uses SwiftUI, SwiftData, and AVFoundation.

This fork is being used to prototype HLS playback against a modified Audiobookshelf server. The goal is a locally-deployed proof of concept to present upstream to `rasmuslos` — expect the architecture below to evolve as that work progresses.

### Upstream contribution policy

The upstream project's README explicitly asks contributors **not** to submit AI-generated pull requests. Instead, open an issue describing the idea and, if helpful, include the prompt used. Keep this in mind before proposing any upstream PR from this fork.

## Build & Run

The project uses **XcodeGen** to generate the Xcode project from `project.yml`.

```bash
# Generate the Xcode project (required after changing project.yml or pulling changes)
xcodegen generate

# Build from command line
xcodebuild -scheme ShelfPlayer -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

### First-time setup

1. Copy `Configuration/Debug.xcconfig.template` to `Configuration/Debug.xcconfig`
2. Edit with your development team ID, bundle prefix, and feature flags
3. Run `xcodegen generate`

### Configuration flags

- `ENABLE_CENTRALIZED` — enables features requiring a paid developer account (app groups, iCloud, Siri, CarPlay). Without it, the app uses `FREE_DEVELOPER_ACCOUNT.entitlements`.
- Build number is auto-set from git commit count via a post-compile script.
- `SWIFT_STRICT_CONCURRENCY: targeted` is set only for Debug in `project.yml`. Release/archive builds get Swift 6's default (full) strict concurrency, so concurrency warnings may appear only in archive builds.

## Architecture

### Module dependency graph

```
ShelfPlayer (app)
├── ShelfPlayerKit (framework) — data models, networking, persistence
│   ├── RFKit (SPM, internal utility lib)
│   ├── SwiftSoup (HTML parsing)
│   └── SocketIO (real-time updates)
├── ShelfPlayback (framework) — AVFoundation audio engine
│   └── ShelfPlayerKit
├── ShelfPlayerMigration (framework) — version migration
│   └── ShelfPlayerKit
└── ShelfPlayerWidgets (app extension) — WidgetKit widgets
    └── ShelfPlayerKit
```

### Key layers

- **ShelfPlayerKit** (`/ShelfPlayerKit/`): Core framework. Contains REST API client (actor-based), SwiftData persistence with subsystem pattern (AuthorizationSubsystem, ProgressSubsystem, DownloadSubsystem, etc.), and data models. No SwiftUI dependency. Re-exports `RFVisuals` via `@_exported import`.
- **ShelfPlayback** (`/ShelfPlayback/`): Audio playback engine (AudioPlayer), session management, progress reporting to server, Now Playing integration. Re-exports `ShelfPlayerKit` via `@_exported import` — so app files typically only need `import ShelfPlayback` to get both.
- **ShelfPlayerMigration** (`/ShelfPlayerMigration/`): Version migration. `MigrationManager` orchestrates three dedicated migrators — `DefaultsMigrator` (UserDefaults keys), `KeychainMigrator` (credentials/tokens), and `SwiftDataMigrator` (store schema). New upgrade paths belong here, not inline in app/framework code.
- **App** (`/App/`): SwiftUI UI layer. Uses `@Observable` ViewModels. Key singletons: `Satellite` (navigation/UI coordinator, in `App/Lifecycle/`), `PlaybackViewModel` (in `App/Playback/`), `ConnectionStore` (in `App/Connection/`, alongside `ConnectionManager`, `ConnectionAuthorizer`, and sign-in sheets).
- **WidgetExtension** (`/WidgetExtension/`): Home screen and lock screen widgets sharing data via app group.

### Embassy — Apple platform integration

Both `App/Embassy/` and `ShelfPlayerKit/Embassy/` host the code that bridges ShelfPlayer with Apple platform features: App Intents, AppShortcuts, Siri, Spotlight indexing (`SpotlightIndexer`), CarPlay entities, `IntentAudioPlayer`, Live Activity attributes (`SleepTimerLiveActivityAttributes`), and `PlayMediaIntentHandler`. When adding Intents, Shortcuts, Spotlight behavior, or Live Activities, look here first — it's a distinct architectural slice that spans both the app target and the kit framework.

### Patterns

- **@Observable + @MainActor** for ViewModels (Swift 6 concurrency)
- **Subsystem pattern** in persistence: each domain (progress, downloads, bookmarks, etc.) is a separate subsystem class under `ShelfPlayerKit/Persistence/Subsystems/`
- **Actor-based API client** for thread-safe networking
- **Combine** for event publishing from playback layer to UI
- Shared state between app and widgets via **UserDefaults suite** (app group)

### Data model hierarchy

```
Item (base)
├── PlayableItem (adds duration, size)
│   ├── Audiobook
│   └── Episode
└── Podcast
```

## Design & Code Style

- **4-unit spacing system** for all UI layout
- UI should look and feel like a native Apple-made iOS app — minimal, clean, familiar
- Write minimal, lean, expressive Swift 6 code using modern language features: async/await, actors, Combine, @Observable, Sendable
- All "backend" code (networking, persistence, data models) belongs in the relevant frameworks (ShelfPlayerKit, ShelfPlayback), not in the app target
- The app target contains only SwiftUI views, ViewModels, and navigation

## Tests

```bash
# Run unit tests (ShelfPlayerKit integration tests against https://audiobooks.dev demo:demo)
xcodebuild test -scheme ShelfPlayer -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:ShelfPlayerKitTests ENABLE_USER_SCRIPT_SANDBOXING=NO

# Run UI tests
xcodebuild test -scheme ShelfPlayer -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:ShelfPlayerUITests ENABLE_USER_SCRIPT_SANDBOXING=NO

# Run all tests
xcodebuild test -scheme ShelfPlayer -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  ENABLE_USER_SCRIPT_SANDBOXING=NO
```

- **ShelfPlayerKitTests**: Swift Testing-based unit tests that hit the live demo server at `https://audiobooks.dev` (credentials: `demo`/`demo`). Tests cover API client auth, library fetching, search, and ItemIdentifier logic.
- **ShelfPlayerUITests**: XCTest-based UI tests for connection flow, navigation, and content browsing.
- Fixture data for previews lives in `ShelfPlayerKit/Fixtures/`.

## Localization

The app supports multiple languages. Localized strings are in `.xcstrings` files. Existing per-language `.lproj` folders under `App/` cover: `en`, `de`, `fr`, `nl`, `ru`, `sv`, `uk`, `zh-Hans`. See `Localization.md` for contributing translations.
