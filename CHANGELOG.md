# Changelog

All notable changes to **Lumi** will be documented in this file.

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
