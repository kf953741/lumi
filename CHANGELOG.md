# Changelog

All notable changes to **Lumi** will be documented in this file.

## [1.3.0] - 2026-11-22

### Added
- **Live Bilingual UI (`English` / `简体中文` / `Follow System`)**: Added instant zero-restart language switching across the Dynamic Notch, Floating Board, Settings, Menu Bar, macOS notifications, and dynamic tool action labels (`Localization.swift`).
- **Needs-Input / Approval Alerts (`needsInput`)**: Detects permission prompts, approval requests, and interactive user questions across Claude Code, Codex, Antigravity, and hook-connected agents — immediately surfaces a top-priority section with an Apple Knockout `?` badge, dedicated curious `?` Lumi Ember mascot pose, and instant `Reply ↗` jump without waiting for the 4.5s completion debounce.
- **Global Toggle Hotkey & `Esc` Dismiss**: Zero-permission Carbon `RegisterEventHotKey` global hotkey (`⌥L` default, configurable to `⌃⌥L`, `⌘⇧L`, or Off) plus `Esc` quick collapse (`GlobalHotKeyManager.swift`).
- **Smart Fullscreen Auto-Peek Guard**: Automatically suppresses completion notch auto-peeks during fullscreen video playback, games, or presentations (configurable in Settings).
- **Morning Oat Light Theme for Floating Board**: Added an optional Headspace-inspired warm parchment light appearance (`FloatingAppearance.oatLight`) with 1-click `☀ / ☾` toggle on the Floating Board while keeping Dynamic Notch seamlessly matte-black at the hardware bezel.
- **Do Not Disturb Quick Mute & Manual Update Checker**: Added 30-minute / 1-hour DND mute controls in both the Menu Bar and Settings, plus a strictly user-initiated GitHub Releases update checker (`UpdateChecker.swift`) that preserves zero background network activity.
- **Expressive Collapsed Dynamic Notch Ears**: Upgraded the collapsed MacBook notch into a 6-state ambient status strip — Lumi Ember now displays high-contrast 24px micro-expressions (`sleeping` puddle + `zZ`, `working` hooded squint + V-brows, `needsInput` `?` pill, `celebrating` `^ ^` + grin + confetti, `waitingUnread` `✦` spark, `error` `!` alert), paired with 1–2 stacked 15.5px native macOS app icons on the left ear, a live solo `MM:SS` timer / `? Reply` badge / multi-task counts on the right ear, and camera-anchored dynamic ear narrowing when idle.
- **Custom Menu Bar Lumi Ember Icon & Completed Run Duration**: Replaced menu bar counters with a clean 18×18 full-color warm-orange Lumi Ember bean icon and added total run duration (`17:05 · 2m18s`) on finished session rows.

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
