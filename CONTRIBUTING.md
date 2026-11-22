# Contributing to Lumi

Thank you for your interest in contributing to **Lumi**! Whether you are adding support for a new AI coding agent, refining SwiftUI animations, fixing an edge case in a local scanner, or improving documentation, PRs are warmly welcome.

## Development Setup

Requirements:
- macOS 14.0+ (Sonoma or newer)
- Xcode 15.4+ or Swift 5.10+ Command Line Tools

```bash
git clone https://github.com/kf953741/lumi.git
cd lumi
swift test
./scripts/build_app.sh
open -a /Applications/Lumi.app
```

## Project Layout

```text
Sources/Lumi/
├── App/         # AppDelegate, Menu Bar, NotchWindowController (hardware notch detection)
├── Core/        # Antigravity, Codex, Claude, Extra scanners, SQLiteReader, HookInstaller, Localization, GlobalHotKeyManager, UpdateChecker, MonitorStore
├── Mascot/      # LumiMascotView (Lumi Ember lineless Canvas bean with adaptive FPS & eye tracking)
├── Models/      # AgentModels, ProjectNameHelper, ToolActionFormatter
└── UI/          # NotchIslandView, FloatingBoardView, StudioBentoBoardView, SessionCardView, NativeAgentIconView, SettingsView
```

## Engineering Guidelines

- **100% Native & Local**: Keep zero third-party runtime dependencies, zero Electron, and zero telemetry.
- **Read-Safe Local Inspection**: Never mutate host agent databases (`PRAGMA query_only = ON`) and always back up user hook files before modifying them.
- **Low Idle CPU**: Avoid unbounded SwiftUI `repeatForever` animations; respect `LumiMascotView`'s adaptive frame intervals.
- **Tests**: Add unit tests in `Tests/LumiTests/LumiCoreTests.swift` for parser, naming, and SQLite/WAL edge cases, and ensure `swift test` passes before opening a PR.

## Adding a New AI Agent

1. Add the new case to `AgentKind` in `Sources/Lumi/Models/AgentModels.swift`.
2. Add hook install/uninstall support in `Sources/Lumi/Core/HookInstaller.swift` and `Resources/Hooks/lumi-hook.py` (with backup-before-write).
3. If the tool exposes local session files or SQLite state, add a dedicated scanner in `Sources/Lumi/Core/` and wire it into `MonitorStore`.
4. Update the Supported Agents matrix in `README.md` and `README.zh-CN.md`.
