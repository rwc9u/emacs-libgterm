# CLAUDE.md

## Project Overview

emacs-libgterm is a terminal emulator for Emacs using libghostty-vt (from the Ghostty terminal emulator) as the backend. It follows the same three-layer architecture as emacs-libvterm: terminal library (Zig) → dynamic module (Zig/C ABI) → Elisp interface.

## Build & Test

```bash
# Build the dynamic module
zig build

# Run Zig unit tests
zig build test

# Run integration test in batch Emacs
/Applications/Emacs.app/Contents/MacOS/Emacs --batch --eval '
(progn
  (module-load "zig-out/lib/libgterm-module.dylib")
  (let ((term (gterm-new 80 24)))
    (gterm-feed term "Hello\r\n")
    (message "%s" (gterm-content term))
    (gterm-free term)))'
```

After rebuilding the `.dylib`, Emacs must be restarted — dynamic modules cannot be reloaded at runtime.

## Auto-Compilation

gterm.el auto-detects if the module is missing and offers to compile via `zig build`. Set `gterm-always-compile-module` to `t` to skip the prompt. The compile function `gterm-module-compile` checks for zig and vendor/ghostty before building. It auto-detects the `emacs-module.h` include path via `data-directory` and passes `-Demacs-include=` to zig build.

## Releasing / Version Bumps

The `;; Version:` header in `gterm.el` must be bumped when pushing changes that users need to pick up. `package-vc` (Emacs 30+ `:vc` keyword) uses this header to decide whether to re-fetch — if the version hasn't changed, it won't update even when the code has. Bump the version in `gterm.el` (and `build.zig.zon` if appropriate) whenever merging user-facing changes to main.

## Project Structure

```
├── build.zig          # Zig build system, ghostty dependency config
├── build.zig.zon      # Package manifest
├── src/
│   ├── gterm.zig      # Main module: ghostty-vt ↔ Emacs bridge
│   │                  #   GtermInstance wrapper, styled cell renderer,
│   │                  #   Emacs module functions, cursor tracking
│   └── emacs_env.zig  # Emacs module API via @cImport of emacs-module.h
├── gterm.el           # Elisp: major mode, PTY, keybindings, display,
│                      #   copy/paste, scrollback, drag-drop, auto-compile
└── vendor/ghostty/    # Ghostty source (git-ignored, cloned separately)
```

## Key Technical Details

### Ghostty Build Integration
Our `build.zig` passes `emit-lib-vt=true` via `lazyDependency`. This flag tells ghostty's build system to only build `libghostty-vt`, skipping the macOS app, xcframework, and full libghostty — no Xcode required. Ghostty's `build.zig` already guards xcframework/macOS-app initialization behind `config.emit_xcframework or config.emit_macos_app`, so no patching is needed.

### Emacs Module API
Bindings use `@cImport` of the real `emacs-module.h` header (from `/Applications/Emacs.app/Contents/Resources/include/`) for guaranteed ABI correctness. The include path is configurable via `-Demacs-include=`.

### Styled Cell-by-Cell Rendering
Two render paths:
- `gterm-render` (primary): Zig function that inserts styled text directly into the Emacs buffer with face properties. Accumulates runs of identically-styled characters and flushes with `insert` + `put-text-property`. Returns the buffer position of the cursor.
- `gterm-content` (debug): Returns plain text string without styling.

Both iterate ghostty-vt's page grid cell-by-cell:
- Empty cells mid-line → spaces
- Trailing empty cells → trimmed (EOL detection)
- Wide characters → skip spacer_tail cells
- Grapheme clusters → append combining codepoints

### Global Symbol References
Commonly used Emacs symbols (`:foreground`, `:background`, `bold`, etc.) are pre-interned at module load via `make_global_ref` for performance.

### Persistent VT Stream
The `TerminalStream` is stored on `GtermInstance` (not recreated per feed call) so escape sequences split across PTY output chunks are handled correctly.

### Linefeed Mode
ANSI mode 20 is enabled by default because Emacs strips `\r` from PTY output. Without this, `\n` alone doesn't return the cursor to column 0.

### Terminal Access Pattern
```zig
const screen = self.terminal.screens.active;  // *Screen pointer
const page_list = &screen.pages;
const pin = page_list.pin(.{ .viewport = .{ .x = 0, .y = row } });
const page = &pin.node.data;
const page_row = page.getRow(pin.y);
const page_cells = page.getCells(page_row);
// cell.codepoint(), cell.wide, cell.content_tag, page.lookupGrapheme(cell)
// page.styles.get(page.memory, cell.style_id) -> *Style
```

### Batched Refresh
Process filter schedules refresh via 8ms timer to coalesce rapid output. Direct user actions (scrollback, resize) refresh immediately.

### Shell Configuration
Default shell is `/bin/zsh` (hardcoded). The user's Emacs `SHELL` env var resolves to bare `bash` which launches Node.js.

## Conventions

- Zig 0.15.2 API: use `std.array_list.Managed(T)` not `std.ArrayList(T).init()`
- Emacs env function pointers are optional in @cImport: unwrap with `.?` (e.g., `env.intern.?(env, "nil")`)
- Export `plugin_is_GPL_compatible` as a mutable `var` for Emacs GPL check
- Export `emacs_module_init` with `callconv(.c)` for the module entry point
- Style IDs: `0` is the default style (no lookup needed), non-zero requires `page.styles.get()`
- Colors: resolve `Style.Color` via palette for indexed colors, direct for RGB, format as `#RRGGBB`
