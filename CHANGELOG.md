# Changelog

All notable changes to **Lumi** will be documented in this file.

## [1.2.0] - 2026-11-22

### Changed
- **Warm Charcoal Hearth UI Overhaul**: Replaced cold blue-slate obsidian glass, outer-space purple mascot stage, and neon-green accents with a cohesive warm-charcoal palette (`LumiPalette`), mood-reactive Warm Hearth lighting with soft floor reflections, champagne glass rims, and Ember-gold primary accents.
- **Native macOS App Icons & Apple Knockout Corner Badges**: Eliminated colored text pill badges and rainbow status dots in `SessionCardView` and `SettingsView`. Added `NativeAgentIconView` (`AgentIconCache`) to load real local `.app` icons at runtime via `NSWorkspace` / `NSRunningApplication` (flattened cleanly to 8-bit sRGB) with 6 hand-crafted SwiftUI `Canvas` macOS squircle fallbacks for CLI-only workflows, paired with low-CPU animated knockout corner spinners and Ember unread checkmarks.
- **Refreshed Visual Showcase**: Re-rendered all README screenshots, GitHub Social Preview, and the 10-second interactive demo GIF/MP4 to match the v1.2.0 Warm Charcoal Hearth & Native App Icon UI.

## [1.1.0] - 2026-11-22

### Changed
- **Brand-New Original Mascot (`Lumi Ember`)**: Replaced the earlier space-ghost silhouette with an unmistakable, lineless Californian editorial warm-tangerine luminous bean featuring goofy asymmetric eyes, hyper-focused `{ }` coding squint, ecstatic open-grin confetti jumps, slumped droopy-eyelid `Zzz` sleep, and 6 warm cohesive themes (`Ember`, `Butter`, `Aurora`, `Nebula`, `Berry`, `Cloud`).
- **Redesigned App Icon & GitHub Showcase**: Updated the 1024×1024 vector `AppIcon.icns`, Open Graph social preview, static Bento visuals, and 10-second animated demo GIF featuring authentic Antigravity 2.0 and OpenAI Codex Desktop jump transitions.
- **Swift 6.0 / macOS 15 CI Compatibility**: Disambiguated `Foundation.sin`/`Foundation.cos` calls for clean green builds across Xcode 16+ and macOS 15+ runners.

### Added
- **Homebrew Cask Formula**: Added `Casks/lumi.rb` for one-command installation via `brew tap kf953741/lumi https://github.com/kf953741/lumi && brew install --cask kf953741/lumi/lumi`.

## [1.0.0] - 2026-11-22

### Added
- **Dual Form Factor UI**: Seamless MacBook Pro/Air Dynamic Notch Island with concave bezel shoulders (`NotchIslandShape`) + 1-click detachable Floating Desktop Board (`FloatingBoardView`), automatically adapting to external non-notch displays.
- **Studio Bento Frosted Dark Glass**: High-contrast smoked obsidian frosted glass layout with per-dialog rows, live elapsed timers, `+N` subagent roll-up badges, and a persistent Unread Completed Inbox (`待查看`).
- **Original Vector Mascot (Lumi)**: SwiftUI `Canvas` space-ghost with cursor eye-tracking, coding headphones, confetti completion jump, idle `Zzz` sleep, error alerts, 4-tap dizzy easter egg, 6 color themes, and adaptive FPS.
- **Zero-Config Local Scanners + 1-Click Hook Installer**:
  - Out-of-the-box local tracking for **Google Antigravity**, **OpenAI Codex** (Desktop & CLI, including 700 MB+ long-turn tail parsing), and **Claude Code**.
  - Backup-first 1-click Hook installer in Settings for **Antigravity**, **Codex**, **Claude Code**, **Cursor**, **Gemini CLI**, and **OpenCode**.
- **Exact Conversation Jump**: Native `codex://threads/<id>` deep links for Codex and official `Cmd+K` search palette automation for Antigravity (clipboard-preserving, Accessibility-gated).
- **WAL-Safe SQLite Reader**: Opens WAL-mode databases cleanly with `PRAGMA query_only = ON` even when `-wal`/`-shm` sidecars are absent, plus transient-error fallback and 4.5s completion settle debouncing.
- **Build & Packaging Scripts**: Automated SwiftPM release build, 1024×1024 vector `AppIcon.icns` generator, Developer ID auto-signing, and `.dmg` release packaging.
