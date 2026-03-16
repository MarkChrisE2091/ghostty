# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

- **Build:** `zig build`
  - macOS without app bundle: `zig build -Demit-macos-app=false`
  - Windows: `zig build -Dapp-runtime=windows -Dfont-backend=freetype`
- **Run:** `zig build run`
- **Test:** `zig build test`
  - Prefer targeted tests: `zig build test -Dtest-filter=<test name>` (full suite is slow)
- **Format Zig:** `zig fmt .`
- **Format Swift:** `swiftlint lint --strict --fix`
- **Format docs/resources:** `prettier --write .`
- **Valgrind (Linux):** `zig build run-valgrind`

Build configuration options are in `src/build/Config.zig` (controlled via `-D` flags).

## Architecture

Ghostty is a terminal emulator written in Zig with platform-specific GUI layers. The core design separates platform-agnostic terminal logic from platform-specific rendering and windowing.

### Core Layer (`src/`)

- **`App.zig`** — Core application logic (platform-agnostic). Manages surfaces, font state, configuration. The platform apprt wraps this.
- **`Surface.zig`** — Core surface (terminal instance). Handles terminal I/O, input processing, rendering coordination. The platform apprt surface wraps this.
- **`terminal/`** — Terminal emulation: VT parser, screen buffer, scrollback, selection, mouse handling. This is the heart of the emulator.
- **`termio/`** — Terminal I/O layer: child process execution (`Exec.zig`), PTY management, shell integration injection.
- **`font/`** — Font loading, discovery, shaping, and rasterization. Multiple backends selectable at compile time.
- **`renderer/`** — Rendering backends (OpenGL, Metal, WebGL). Runs on a dedicated thread separate from the main/IO threads.
- **`input/`** — Input handling: key bindings (`Binding.zig`), key mapping, modifier tracking.
- **`config/`** — Configuration system (`Config.zig`). Loads from files, CLI args, and provides the full set of ghostty options.

### App Runtime Layer (`src/apprt/`)

Platform-specific windowing/GUI code. Selected at compile time via `-Dapp-runtime=`:

- **`gtk/`** — GTK4 runtime for Linux/FreeBSD. Full-featured with tabs, splits, etc.
- **`embedded/`** — Used on macOS; Zig core is compiled as `libghostty`, linked by the Swift/SwiftUI app in `macos/`.
- **`windows/`** — Win32 native runtime (in development). Uses Win32 API + WGL for OpenGL.
- **`none`** — No executable; builds only the library.

Each apprt implements `App` and `Surface` types that wrap the core `App.zig`/`Surface.zig` and translate platform events into core calls.

### Renderer/Font Backend Selection

Backends are compile-time choices:

| Component | Options | Default |
|-----------|---------|---------|
| App Runtime | `gtk`, `windows`, `none` | Platform-dependent |
| Renderer | `opengl`, `metal`, `webgl` | `metal` on macOS, `opengl` elsewhere |
| Font | `freetype`, `fontconfig_freetype`, `coretext`, `coretext_freetype`, `web_canvas` | `coretext` on macOS, `fontconfig_freetype` on Linux |

### Key Design Patterns

- **Comptime polymorphism:** Backends are selected at compile time using Zig's comptime. Functions like `apprt.runtime`, `renderer.backend`, `font.backend` resolve to concrete types at build time — no vtables or runtime dispatch.
- **Thread model:** Main thread (input/UI), I/O thread (terminal emulation, PTY), renderer thread (OpenGL/Metal). The renderer thread owns the GPU context.
- **Action system (`src/apprt/action.zig`):** Platform actions (new tab, split, close, etc.) flow through a unified action enum. Each apprt implements `performAction` to handle platform-specific behavior.

### macOS App

The macOS app lives in `macos/` as a SwiftUI Xcode project. It links against `libghostty` (the Zig core compiled as a C library). The Swift code calls into libghostty via C APIs defined in `include/ghostty.h`.

### Shell Integration

Shell integration scripts live in `src/shell-integration/` (bash, zsh, fish, elvish, powershell). They are injected automatically by `src/termio/shell_integration.zig`.

## Issue and PR Guidelines

- Never create an issue or PR via AI tooling.
- All AI usage must be disclosed per `AI_POLICY.md`.
- PRs should implement a previously accepted issue.
