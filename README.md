# emacs-libgterm

Terminal emulator for Emacs built on [libghostty-vt](https://github.com/ghostty-org/ghostty), the terminal emulation library from the [Ghostty](https://ghostty.org/) terminal emulator.

This project follows the same architecture as [emacs-libvterm](https://github.com/akermu/emacs-libvterm) but uses Ghostty's terminal engine, which offers:

- SIMD-optimized VT escape sequence parsing
- Better Unicode and grapheme cluster support
- Text reflow on resize
- Kitty graphics protocol support
- Active development and maintenance

> **Status:** Early prototype. Fully vibe coded. Only tested on macOS (Apple Silicon). Terminal works with ANSI colors, full key handling, scrollback, cursor sync, and drag-and-drop. Some character width mismatches with Powerline/NerdFont glyphs remain. Here be dragons.

## Requirements

- **Emacs 25.1+** compiled with `--with-modules` (dynamic module support)
- **Zig 0.15.2+** (install via `asdf install zig 0.15.2` or [ziglang.org](https://ziglang.org/download/))
- **Git** (to clone the Ghostty source)

## Installation

### use-package + straight.el (recommended)

```elisp
(use-package gterm
  :straight (:host github :repo "rwc9u/emacs-libgterm")
  :init
  (setq gterm-always-compile-module t))
```

### use-package + quelpa

```elisp
(use-package gterm
  :quelpa (gterm :fetcher github :repo "rwc9u/emacs-libgterm")
  :init
  (setq gterm-always-compile-module t))
```

### use-package + local clone

```elisp
(use-package gterm
  :load-path "/path/to/emacs-libgterm"
  :init
  (setq gterm-always-compile-module t))
```

### Manual

```elisp
(add-to-list 'load-path "/path/to/emacs-libgterm")
(require 'gterm)
```

Then `M-x gterm` to open a terminal.

### What happens on first load

1. gterm detects the missing compiled module
2. Automatically clones [Ghostty](https://github.com/ghostty-org/ghostty) into `vendor/ghostty` (if not present)
3. Applies a build patch for macOS compatibility (if needed)
4. Compiles the Zig dynamic module via `zig build`
5. Loads the module

The only prerequisite is having **Zig** and **Git** installed. Set `gterm-always-compile-module` to `t` to skip the confirmation prompt, or leave it `nil` to be asked first.

### Manual build (optional)

If you prefer to build manually:

```bash
git clone https://github.com/rwc9u/emacs-libgterm.git
cd emacs-libgterm
zig build
zig build test  # run tests
```

Ghostty will be cloned automatically by `zig build` if not present, or you can clone it yourself:

```bash
git clone --depth 1 https://github.com/ghostty-org/ghostty.git vendor/ghostty
```

## Usage

| Key | Action |
|-----|--------|
| `M-x gterm` | Open a new terminal |
| Arrow keys | Navigate / command history |
| `C-y` / `Cmd-V` | Paste from kill ring |
| `C-c C-k` | Enter copy mode (select text, `y` to copy, `q` to exit) |
| `Shift-PageUp/Down` | Scroll through history |
| `C-c C-v` | Snap back to live terminal |
| `C-c C-c` | Send Ctrl-C to shell |
| `C-c C-d` | Send Ctrl-D (EOF) to shell |
| `C-c C-z` | Send Ctrl-Z (suspend) to shell |
| Drag file from Finder | Send file path to terminal |

## Build Options

```bash
# Specify custom Emacs include path (for emacs-module.h)
zig build -Demacs-include=/path/to/emacs/include

# Build with optimizations
zig build -Doptimize=ReleaseFast
```

## Architecture

```
+----------------+     +---------------------+     +---------------+
|  gterm.el      |---->|  gterm-module.so    |---->|  ghostty-vt   |
|  (Elisp)       |     |  (Zig -> C ABI)     |     |  (Zig lib)    |
|                |     |                     |     |               |
| - PTY mgmt     |     | - Terminal create   |     | - VT parse    |
| - Keybinds     |     | - Feed bytes        |     | - Screen      |
| - Display      |     | - Styled render     |     | - Cursor      |
| - Copy/Paste   |     | - Cursor track      |     | - Scrollback  |
| - Scrollback   |     | - Mode query        |     | - Reflow      |
+----------------+     +---------------------+     +---------------+
```

## Customization

```elisp
;; Change shell (default: /bin/zsh)
(setq gterm-shell "/bin/bash")

;; Change TERM variable (default: xterm-256color)
(setq gterm-term-environment-variable "xterm-256color")

;; Auto-compile without prompting
(setq gterm-always-compile-module t)
```

## Known Issues

- **Character width mismatches** — some Unicode characters (Powerline glyphs, NerdFont icons) may render at different widths in Emacs vs the terminal, causing minor alignment issues with fancy prompts
- **No mouse support** — programs like htop that use mouse events are not yet supported

## License

GPL-3.0 (required for Emacs dynamic modules)
