//! emacs-libgterm: Terminal emulator for Emacs using libghostty-vt.
//!
//! This module implements an Emacs dynamic module that wraps ghostty-vt
//! (the terminal emulation library extracted from the Ghostty terminal
//! emulator). It provides:
//!
//!   - gterm-new: Create a new terminal instance
//!   - gterm-feed: Feed raw bytes (shell output) into the terminal
//!   - gterm-content: Read the terminal screen as a string
//!   - gterm-cursor-pos: Get the cursor position (row, col)
//!   - gterm-resize: Resize the terminal
//!   - gterm-free: Destroy a terminal instance
//!
//! The Elisp layer (gterm.el) handles PTY management, buffer display,
//! and keybinding, calling these primitives as needed.

const std = @import("std");
const emacs = @import("emacs_env.zig");
const ghostty_vt = @import("ghostty-vt");

/// Required by Emacs to verify GPL compatibility of dynamic modules.
export var plugin_is_GPL_compatible: c_int = 0;

const Terminal = ghostty_vt.Terminal;
const Style = ghostty_vt.Style;
const color = ghostty_vt.color;
const Allocator = std.mem.Allocator;
const page_mod = ghostty_vt.page;

// We use the general purpose allocator since terminal instances are
// long-lived and few in number.
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator: Allocator = gpa.allocator();

// ── Global Emacs symbol refs (initialized at module load) ───────────
// These persist across env lifetimes via make_global_ref.
var sym_face: emacs.emacs_value = undefined;
var sym_foreground: emacs.emacs_value = undefined;
var sym_background: emacs.emacs_value = undefined;
var sym_weight: emacs.emacs_value = undefined;
var sym_bold: emacs.emacs_value = undefined;
var sym_light: emacs.emacs_value = undefined;
var sym_slant: emacs.emacs_value = undefined;
var sym_italic: emacs.emacs_value = undefined;
var sym_underline: emacs.emacs_value = undefined;
var sym_strike_through: emacs.emacs_value = undefined;
var sym_t: emacs.emacs_value = undefined;
// Buffer navigation symbols for incremental rendering
var sym_goto_char: emacs.emacs_value = undefined;
var sym_forward_line: emacs.emacs_value = undefined;
var sym_line_beginning_position: emacs.emacs_value = undefined;
var sym_line_end_position: emacs.emacs_value = undefined;
var sym_delete_region: emacs.emacs_value = undefined;
var sym_point_min: emacs.emacs_value = undefined;
var sym_help_echo: emacs.emacs_value = undefined;
var sym_mouse_face: emacs.emacs_value = undefined;
var sym_highlight: emacs.emacs_value = undefined;
var sym_keymap: emacs.emacs_value = undefined;
var sym_gterm_link_map: emacs.emacs_value = undefined;

fn initGlobalSymbols(env: *emacs.emacs_env) void {
    sym_face = emacs.make_global_ref(env, env.intern.?(env, "face"));
    sym_foreground = emacs.make_global_ref(env, env.intern.?(env, ":foreground"));
    sym_background = emacs.make_global_ref(env, env.intern.?(env, ":background"));
    sym_weight = emacs.make_global_ref(env, env.intern.?(env, ":weight"));
    sym_bold = emacs.make_global_ref(env, env.intern.?(env, "bold"));
    sym_light = emacs.make_global_ref(env, env.intern.?(env, "light"));
    sym_slant = emacs.make_global_ref(env, env.intern.?(env, ":slant"));
    sym_italic = emacs.make_global_ref(env, env.intern.?(env, "italic"));
    sym_underline = emacs.make_global_ref(env, env.intern.?(env, ":underline"));
    sym_strike_through = emacs.make_global_ref(env, env.intern.?(env, ":strike-through"));
    sym_t = emacs.make_global_ref(env, env.intern.?(env, "t"));
    sym_goto_char = emacs.make_global_ref(env, env.intern.?(env, "goto-char"));
    sym_forward_line = emacs.make_global_ref(env, env.intern.?(env, "forward-line"));
    sym_line_beginning_position = emacs.make_global_ref(env, env.intern.?(env, "line-beginning-position"));
    sym_line_end_position = emacs.make_global_ref(env, env.intern.?(env, "line-end-position"));
    sym_delete_region = emacs.make_global_ref(env, env.intern.?(env, "delete-region"));
    sym_point_min = emacs.make_global_ref(env, env.intern.?(env, "point-min"));
    sym_help_echo = emacs.make_global_ref(env, env.intern.?(env, "help-echo"));
    sym_mouse_face = emacs.make_global_ref(env, env.intern.?(env, "mouse-face"));
    sym_highlight = emacs.make_global_ref(env, env.intern.?(env, "highlight"));
    sym_keymap = emacs.make_global_ref(env, env.intern.?(env, "keymap"));
    sym_gterm_link_map = emacs.make_global_ref(env, env.intern.?(env, "gterm-link-map"));
}

// ── Terminal wrapper ────────────────────────────────────────────────────

const GtermInstance = struct {
    terminal: Terminal,
    stream: ghostty_vt.TerminalStream,
    rows: u16,
    cols: u16,
    freed: bool = false,

    pub fn init(cols: u16, rows: u16) !*GtermInstance {
        const self = try allocator.create(GtermInstance);
        self.terminal = try .init(allocator, .{
            .cols = cols,
            .rows = rows,
            // Enable linefeed mode: LF (\n) implies CR (\r).
            // Emacs strips \r from PTY output, so the terminal
            // only sees \n. Without this, the cursor stays at the
            // current column on LF instead of returning to col 0.
            .default_modes = .{ .linefeed = true },
        });
        // Persistent stream preserves parser state across feed calls,
        // so escape sequences split across PTY output chunks are
        // handled correctly.
        self.stream = self.terminal.vtStream();
        self.rows = rows;
        self.cols = cols;
        return self;
    }

    pub fn deinit(self: *GtermInstance) void {
        if (self.freed) return;
        self.freed = true;
        self.stream.deinit();
        self.terminal.deinit(allocator);
        // Note: we do NOT call allocator.destroy(self) here.
        // The GtermInstance memory must remain valid until the GC
        // finalizer has run, because the finalizer reads self.freed
        // to guard against double-cleanup. If we free the struct
        // here (e.g. via an explicit gterm-free call), the later
        // GC finalizer would dereference freed memory (use-after-free),
        // which can crash during sweep_vectors.
        // Instead, the finalizer is the sole owner of the struct memory.
    }

    /// Feed raw bytes through the terminal's VT parser.
    pub fn feed(self: *GtermInstance, bytes: []const u8) void {
        self.stream.nextSlice(bytes);
    }

    /// Render the visible screen cell-by-cell into a buffer.
    /// Each terminal row becomes one line. Empty cells mid-line become
    /// spaces. Trailing empty cells per row are trimmed.
    ///
    /// Column-aware: tracks expected display column vs terminal column.
    /// When a character's Unicode East Asian Width disagrees with the
    /// terminal's cell width, padding spaces are inserted (or columns
    /// skipped) to keep alignment. This prevents Powerline/NerdFont
    /// glyphs from misaligning subsequent text.
    pub fn renderContent(self: *GtermInstance) ![]const u8 {
        const screen = self.terminal.screens.active;
        const page_list = &screen.pages;
        const cols = self.cols;
        const rows = self.rows;

        // Pre-allocate: worst case ~4 bytes per cell (UTF-8) + newlines
        var buf: std.array_list.Managed(u8) = .init(allocator);
        errdefer buf.deinit();
        try buf.ensureTotalCapacity(@as(usize, cols) * rows * 4);

        var row: u16 = 0;
        while (row < rows) : (row += 1) {
            // Get a pin to the start of this row in the viewport
            const pin = page_list.pin(.{ .viewport = .{
                .x = 0,
                .y = row,
            } }) orelse continue;

            // Get the row's cells
            const page = &pin.node.data;
            const page_row = page.getRow(pin.y);
            const page_cells = page.getCells(page_row);

            // Find the last non-empty column (trim trailing empties)
            var last_non_empty: usize = 0;
            for (0..@min(cols, page_cells.len)) |c| {
                const cell = &page_cells[c];
                if (cell.wide == .spacer_tail) continue;
                const cp = cell.codepoint();
                if (cp != 0) last_non_empty = c + 1;
            }

            // Track display column for width compensation
            var display_col: usize = 0;

            // Render each cell up to last_non_empty
            var col: usize = 0;
            while (col < last_non_empty) : (col += 1) {
                if (col >= page_cells.len) {
                    try buf.append(' ');
                    display_col += 1;
                    continue;
                }
                const cell = &page_cells[col];

                // Skip spacer tails (second cell of wide chars)
                if (cell.wide == .spacer_tail or cell.wide == .spacer_head) {
                    continue;
                }

                // If display column has drifted behind terminal column,
                // insert padding spaces to realign
                while (display_col < col) : (display_col += 1) {
                    try buf.append(' ');
                }
                // If display column is ahead of terminal column, we can't
                // easily remove chars, so we just let it be (rare case)

                const cp = cell.codepoint();
                if (cp == 0) {
                    try buf.append(' ');
                    display_col += 1;
                } else {
                    // Encode the codepoint as UTF-8
                    var utf8_buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(cp, &utf8_buf) catch 1;
                    try buf.appendSlice(utf8_buf[0..len]);

                    // If this cell has grapheme clusters, append them too
                    if (cell.content_tag == .codepoint_grapheme) {
                        if (page.lookupGrapheme(cell)) |graphemes| {
                            for (graphemes) |gcp| {
                                const glen = std.unicode.utf8Encode(gcp, &utf8_buf) catch continue;
                                try buf.appendSlice(utf8_buf[0..glen]);
                            }
                        }
                    }

                    // Advance display column by the character's estimated
                    // Emacs display width (using Unicode East Asian Width)
                    const emacs_width = emacsCharWidth(cp);
                    display_col += emacs_width;
                }
            }

            // Add newline after each row
            try buf.append('\n');
        }

        return try buf.toOwnedSlice();
    }

    /// Estimate how many columns Emacs will use to display a codepoint.
    /// This approximates Emacs's `char-width` using Unicode properties.
    fn emacsCharWidth(cp: u21) usize {
        // Control characters
        if (cp < 0x20 or (cp >= 0x7F and cp < 0xA0)) return 0;

        // Common wide ranges (CJK, Hangul, fullwidth forms)
        if (isWideInEmacs(cp)) return 2;

        // Default: single width
        return 1;
    }

    /// Check if a codepoint is typically rendered as double-width in Emacs.
    /// Based on Unicode East Asian Width property (W and F categories).
    fn isWideInEmacs(cp: u21) bool {
        // Hangul Jamo
        if (cp >= 0x1100 and cp <= 0x115F) return true;
        // Fullwidth/wide CJK ranges
        if (cp >= 0x2E80 and cp <= 0x303E) return true;
        if (cp >= 0x3041 and cp <= 0x33BF) return true;
        if (cp >= 0x3400 and cp <= 0x4DBF) return true;
        if (cp >= 0x4E00 and cp <= 0xA4CF) return true;
        if (cp >= 0xA960 and cp <= 0xA97C) return true;
        if (cp >= 0xAC00 and cp <= 0xD7A3) return true;
        if (cp >= 0xF900 and cp <= 0xFAFF) return true;
        if (cp >= 0xFE30 and cp <= 0xFE6F) return true;
        if (cp >= 0xFF01 and cp <= 0xFF60) return true;
        if (cp >= 0xFFE0 and cp <= 0xFFE6) return true;
        // CJK Unified Ideographs Extension B+
        if (cp >= 0x1F300 and cp <= 0x1F9FF) return true; // Emoji
        if (cp >= 0x20000 and cp <= 0x2FFFF) return true;
        if (cp >= 0x30000 and cp <= 0x3FFFF) return true;
        return false;
    }

    /// Get cursor position (0-based row, col).
    pub fn cursorPos(self: *GtermInstance) struct { row: u16, col: u16 } {
        return .{
            .row = @intCast(self.terminal.screens.active.cursor.y),
            .col = @intCast(self.terminal.screens.active.cursor.x),
        };
    }

    /// Resize the terminal.
    pub fn resize(self: *GtermInstance, cols: u16, rows: u16) !void {
        try self.terminal.resize(allocator, cols, rows);
        self.cols = cols;
        self.rows = rows;
    }
};

// ── Color and style helpers ─────────────────────────────────────────

const hex_chars = "0123456789abcdef";

/// Convert RGB to a "#RRGGBB" Emacs string.
fn rgbToEmacsStr(env: *emacs.emacs_env, rgb: color.RGB) emacs.emacs_value {
    var buf: [7]u8 = undefined;
    buf[0] = '#';
    buf[1] = hex_chars[rgb.r >> 4];
    buf[2] = hex_chars[rgb.r & 0xf];
    buf[3] = hex_chars[rgb.g >> 4];
    buf[4] = hex_chars[rgb.g & 0xf];
    buf[5] = hex_chars[rgb.b >> 4];
    buf[6] = hex_chars[rgb.b & 0xf];
    return env.make_string.?(env, &buf, 7);
}

/// Resolve a Style.Color to an Emacs color string value (or nil).
fn resolveColor(env: *emacs.emacs_env, col: Style.Color, palette: *const color.Palette) emacs.emacs_value {
    return switch (col) {
        .none => emacs.nil(env),
        .palette => |idx| rgbToEmacsStr(env, palette[idx]),
        .rgb => |rgb| rgbToEmacsStr(env, rgb),
    };
}

/// Build a face property list from a Style. Returns nil for default style.
fn buildFacePlist(env: *emacs.emacs_env, style: *const Style, palette: *const color.Palette) emacs.emacs_value {
    var plist_items: [16]emacs.emacs_value = undefined;
    var n: usize = 0;

    // Handle inverse: swap fg/bg
    var fg = style.fg_color;
    var bg = style.bg_color;
    if (style.flags.inverse) {
        const tmp = fg;
        fg = bg;
        bg = tmp;
    }

    // Foreground color
    if (fg != .none) {
        plist_items[n] = sym_foreground;
        n += 1;
        plist_items[n] = resolveColor(env, fg, palette);
        n += 1;
    }

    // Background color
    if (bg != .none) {
        plist_items[n] = sym_background;
        n += 1;
        plist_items[n] = resolveColor(env, bg, palette);
        n += 1;
    }

    // Bold
    if (style.flags.bold) {
        plist_items[n] = sym_weight;
        n += 1;
        plist_items[n] = sym_bold;
        n += 1;
    } else if (style.flags.faint) {
        plist_items[n] = sym_weight;
        n += 1;
        plist_items[n] = sym_light;
        n += 1;
    }

    // Italic
    if (style.flags.italic) {
        plist_items[n] = sym_slant;
        n += 1;
        plist_items[n] = sym_italic;
        n += 1;
    }

    // Underline
    if (style.flags.underline != .none) {
        plist_items[n] = sym_underline;
        n += 1;
        plist_items[n] = sym_t;
        n += 1;
    }

    // Strikethrough
    if (style.flags.strikethrough) {
        plist_items[n] = sym_strike_through;
        n += 1;
        plist_items[n] = sym_t;
        n += 1;
    }

    if (n == 0) return emacs.nil(env);
    return emacs.list(env, plist_items[0..n]);
}

/// Render the terminal into the current Emacs buffer with styled text.
/// Called as (gterm-render TERM) -> nil. Mutates the current buffer directly.
fn gtermRender(
    env_opt: ?*emacs.emacs_env,
    _: emacs.ptrdiff_t,
    args: [*c]emacs.emacs_value,
    _: ?*anyopaque,
) callconv(.c) emacs.emacs_value {
    const env = env_opt.?;
    const instance = getInstanceFromArg(env, args[0]) orelse return emacs.nil(env);

    const screen = instance.terminal.screens.active;
    const page_list = &screen.pages;
    const palette = &instance.terminal.colors.palette.current;
    const cols = instance.cols;
    const rows = instance.rows;
    const default_style_id = 0;

    // Get cursor position to track during rendering
    const cursor_row: u16 = @intCast(screen.cursor.y);
    const cursor_col: u16 = @intCast(screen.cursor.x);
    var cursor_point: emacs.emacs_value = emacs.nil(env);

    // Reusable buffer for accumulating text runs
    var run_buf: std.array_list.Managed(u8) = .init(allocator);
    defer run_buf.deinit();
    run_buf.ensureTotalCapacity(256) catch return emacs.nil(env);

    var row: u16 = 0;
    while (row < rows) : (row += 1) {
        // Record cursor position at start of cursor row (col 0)
        if (row == cursor_row and cursor_col == 0) {
            cursor_point = emacs.point(env);
        }

        const pin = page_list.pin(.{ .viewport = .{
            .x = 0,
            .y = row,
        } }) orelse continue;

        const page = &pin.node.data;
        const page_row = page.getRow(pin.y);
        const page_cells = page.getCells(page_row);

        // Find last non-empty column
        var last_non_empty: usize = 0;
        for (0..@min(cols, page_cells.len)) |c| {
            const cell = &page_cells[c];
            if (cell.wide == .spacer_tail) continue;
            if (cell.codepoint() != 0) last_non_empty = c + 1;
        }

        var current_style_id: u16 = default_style_id;
        var current_link_id: u16 = 0; // 0 = no hyperlink
        var link_start: emacs.emacs_value = emacs.nil(env);
        run_buf.clearRetainingCapacity();
        var cells_emitted: u16 = 0;

        var col: usize = 0;
        while (col < last_non_empty) : (col += 1) {
            if (col >= page_cells.len) {
                run_buf.append(' ') catch {};
                cells_emitted += 1;
                continue;
            }
            const cell = &page_cells[col];

            if (cell.wide == .spacer_tail or cell.wide == .spacer_head) {
                continue;
            }

            // Check hyperlink state change
            const cell_link_id: u16 = if (cell.hyperlink)
                page.lookupHyperlink(cell) orelse 0
            else
                0;

            // Style or hyperlink change: flush the current run
            if (cell.style_id != current_style_id or cell_link_id != current_link_id) {
                flushRun(env, &run_buf, current_style_id, page, palette);
                // Apply hyperlink properties to the flushed run if it was a link
                if (current_link_id != 0) {
                    const link_end = emacs.point(env);
                    applyHyperlink(env, link_start, link_end, page, current_link_id);
                }
                current_style_id = cell.style_id;
                current_link_id = cell_link_id;
                if (cell_link_id != 0) {
                    link_start = emacs.point(env);
                }
            }

            // Capture cursor position when we reach the cursor column
            if (row == cursor_row and col == cursor_col and cursor_col > 0) {
                flushRun(env, &run_buf, current_style_id, page, palette);
                if (current_link_id != 0) {
                    const link_end = emacs.point(env);
                    applyHyperlink(env, link_start, link_end, page, current_link_id);
                    link_start = emacs.point(env);
                }
                cursor_point = emacs.point(env);
            }

            const cp = cell.codepoint();
            if (cp == 0) {
                run_buf.append(' ') catch {};
            } else {
                var utf8_buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cp, &utf8_buf) catch 1;
                run_buf.appendSlice(utf8_buf[0..len]) catch {};

                if (cell.content_tag == .codepoint_grapheme) {
                    if (page.lookupGrapheme(cell)) |graphemes| {
                        for (graphemes) |gcp| {
                            const glen = std.unicode.utf8Encode(gcp, &utf8_buf) catch continue;
                            run_buf.appendSlice(utf8_buf[0..glen]) catch {};
                        }
                    }
                }
            }
            cells_emitted += 1;
        }

        // Apply hyperlink to final run of the row if needed
        if (current_link_id != 0) {
            flushRun(env, &run_buf, current_style_id, page, palette);
            const link_end = emacs.point(env);
            applyHyperlink(env, link_start, link_end, page, current_link_id);
            current_link_id = 0;
        }

        // If cursor is past the last non-empty cell on this row,
        // flush and record position
        if (row == cursor_row and cursor_col >= last_non_empty and env.is_not_nil.?(env, cursor_point) == false) {
            flushRun(env, &run_buf, current_style_id, page, palette);
            // Insert spaces up to cursor column
            const spaces_needed = cursor_col - @as(u16, @intCast(last_non_empty));
            if (spaces_needed > 0) {
                var space_buf: [256]u8 = undefined;
                const n = @min(spaces_needed, 256);
                @memset(space_buf[0..n], ' ');
                const space_str = env.make_string.?(env, &space_buf, @intCast(n));
                emacs.insert(env, space_str);
            }
            cursor_point = emacs.point(env);
        }

        // Flush remaining run for this row
        flushRun(env, &run_buf, current_style_id, page, palette);

        // Newline after each row
        const nl = env.make_string.?(env, "\n", 1);
        emacs.insert(env, nl);
    }

    // Clear all dirty flags after full render
    page_list.clearDirty();

    // Return cursor buffer position (or nil if not found)
    return cursor_point;
}

/// Flush a styled text run: insert the text and apply face properties.
fn flushRun(
    env: *emacs.emacs_env,
    run_buf: *std.array_list.Managed(u8),
    style_id: u16,
    page: *const page_mod.Page,
    palette: *const color.Palette,
) void {
    if (run_buf.items.len == 0) return;

    const str = env.make_string.?(env, run_buf.items.ptr, @intCast(run_buf.items.len));
    const start = emacs.point(env);
    emacs.insert(env, str);
    const end = emacs.point(env);

    // Apply face if non-default style
    if (style_id != 0) {
        const style = page.styles.get(page.memory, style_id);
        const face = buildFacePlist(env, style, palette);
        if (!emacs.check_exit(env) and env.is_not_nil.?(env, face)) {
            emacs.put_text_property(env, start, end, sym_face, face);
        }
    }

    run_buf.clearRetainingCapacity();
}

/// Apply hyperlink properties (help-echo tooltip, mouse-face, keymap)
/// to a region of text in the Emacs buffer.
fn applyHyperlink(
    env: *emacs.emacs_env,
    start: emacs.emacs_value,
    end: emacs.emacs_value,
    page: *const page_mod.Page,
    link_id: u16,
) void {
    // Get the hyperlink entry from the set
    const entry = page.hyperlink_set.get(page.memory, link_id);
    const uri = entry.uri.slice(page.memory);
    if (uri.len == 0) return;

    // Set help-echo (tooltip showing URL)
    const uri_str = env.make_string.?(env, uri.ptr, @intCast(uri.len));
    emacs.put_text_property(env, start, end, sym_help_echo, uri_str);

    // Set mouse-face for hover highlight
    emacs.put_text_property(env, start, end, sym_mouse_face, sym_highlight);

    // Set keymap for click handling
    emacs.put_text_property(env, start, end, sym_keymap, sym_gterm_link_map);
}

/// Render only dirty rows into an existing buffer.
/// The buffer must already contain the full terminal content (from a
/// previous gterm-render call). Navigates to each dirty row, deletes
/// the old content, and inserts the new styled content in-place.
/// Returns the cursor buffer position, or nil.
fn gtermRenderDirty(
    env_opt: ?*emacs.emacs_env,
    _: emacs.ptrdiff_t,
    args: [*c]emacs.emacs_value,
    _: ?*anyopaque,
) callconv(.c) emacs.emacs_value {
    const env = env_opt.?;
    const instance = getInstanceFromArg(env, args[0]) orelse return emacs.nil(env);

    const screen = instance.terminal.screens.active;
    const page_list = &screen.pages;
    const palette = &instance.terminal.colors.palette.current;
    const cols = instance.cols;
    const rows = instance.rows;

    // Get cursor position to track
    const cursor_row: u16 = @intCast(screen.cursor.y);
    const cursor_col: u16 = @intCast(screen.cursor.x);
    var cursor_point: emacs.emacs_value = emacs.nil(env);

    // Reusable buffer for accumulating text runs
    var run_buf: std.array_list.Managed(u8) = .init(allocator);
    defer run_buf.deinit();
    run_buf.ensureTotalCapacity(256) catch return emacs.nil(env);

    var any_dirty = false;

    var row: u16 = 0;
    while (row < rows) : (row += 1) {
        const pin = page_list.pin(.{ .viewport = .{
            .x = 0,
            .y = row,
        } }) orelse continue;

        // Check if this row is dirty
        if (!pin.isDirty()) {
            // Not dirty — still need to track cursor if it's on this row
            if (row == cursor_row) {
                // Navigate to the row to get cursor position
                var goto_args = [_]emacs.emacs_value{env.funcall.?(env, sym_point_min, 0, null)};
                _ = env.funcall.?(env, sym_goto_char, 1, &goto_args);
                var fwd_args = [_]emacs.emacs_value{env.make_integer.?(env, @intCast(row))};
                _ = env.funcall.?(env, sym_forward_line, 1, &fwd_args);
                if (cursor_col > 0) {
                    // Move forward by cursor_col characters on this line
                    var fwd_char_args = [_]emacs.emacs_value{env.make_integer.?(env, @intCast(cursor_col))};
                    _ = env.funcall.?(env, env.intern.?(env, "forward-char"), 1, &fwd_char_args);
                }
                cursor_point = emacs.point(env);
            }
            continue;
        }

        any_dirty = true;

        // Navigate to this row in the buffer
        var goto_args = [_]emacs.emacs_value{env.funcall.?(env, sym_point_min, 0, null)};
        _ = env.funcall.?(env, sym_goto_char, 1, &goto_args);
        var fwd_args = [_]emacs.emacs_value{env.make_integer.?(env, @intCast(row))};
        _ = env.funcall.?(env, sym_forward_line, 1, &fwd_args);

        // Delete old line content (not the newline)
        const line_start = emacs.point(env);
        const line_end = env.funcall.?(env, sym_line_end_position, 0, null);
        var del_args = [_]emacs.emacs_value{ line_start, line_end };
        _ = env.funcall.?(env, sym_delete_region, 2, &del_args);

        // Record cursor position at start of cursor row (col 0)
        if (row == cursor_row and cursor_col == 0) {
            cursor_point = emacs.point(env);
        }

        // Render the row content
        const page = &pin.node.data;
        const page_row = page.getRow(pin.y);
        const page_cells = page.getCells(page_row);

        // Find last non-empty column
        var last_non_empty: usize = 0;
        for (0..@min(cols, page_cells.len)) |c| {
            const cell = &page_cells[c];
            if (cell.wide == .spacer_tail) continue;
            if (cell.codepoint() != 0) last_non_empty = c + 1;
        }

        var current_style_id: u16 = 0;
        run_buf.clearRetainingCapacity();

        var col: usize = 0;
        while (col < last_non_empty) : (col += 1) {
            if (col >= page_cells.len) {
                run_buf.append(' ') catch {};
                continue;
            }
            const cell = &page_cells[col];

            if (cell.wide == .spacer_tail or cell.wide == .spacer_head) {
                continue;
            }

            if (cell.style_id != current_style_id) {
                flushRun(env, &run_buf, current_style_id, page, palette);
                current_style_id = cell.style_id;
            }

            // Capture cursor position
            if (row == cursor_row and col == cursor_col and cursor_col > 0) {
                flushRun(env, &run_buf, current_style_id, page, palette);
                cursor_point = emacs.point(env);
            }

            const cp = cell.codepoint();
            if (cp == 0) {
                run_buf.append(' ') catch {};
            } else {
                var utf8_buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cp, &utf8_buf) catch 1;
                run_buf.appendSlice(utf8_buf[0..len]) catch {};

                if (cell.content_tag == .codepoint_grapheme) {
                    if (page.lookupGrapheme(cell)) |graphemes| {
                        for (graphemes) |gcp| {
                            const glen = std.unicode.utf8Encode(gcp, &utf8_buf) catch continue;
                            run_buf.appendSlice(utf8_buf[0..glen]) catch {};
                        }
                    }
                }
            }
        }

        // Cursor past end of content
        if (row == cursor_row and cursor_col >= last_non_empty and env.is_not_nil.?(env, cursor_point) == false) {
            flushRun(env, &run_buf, current_style_id, page, palette);
            const spaces_needed = cursor_col - @as(u16, @intCast(last_non_empty));
            if (spaces_needed > 0) {
                var space_buf: [256]u8 = undefined;
                const n = @min(spaces_needed, 256);
                @memset(space_buf[0..n], ' ');
                const space_str = env.make_string.?(env, &space_buf, @intCast(n));
                emacs.insert(env, space_str);
            }
            cursor_point = emacs.point(env);
        }

        flushRun(env, &run_buf, current_style_id, page, palette);

        // Mark row as clean
        pin.rowAndCell().row.dirty = false;
    }

    // Clear page-level dirty flags
    if (any_dirty) {
        var page_node = page_list.pages.first;
        while (page_node) |p| : (page_node = p.next) {
            p.data.dirty = false;
        }
    }

    return cursor_point;
}

// ── Helpers ─────────────────────────────────────────────────────────────

fn getInstanceFromArg(env: *emacs.emacs_env, arg: emacs.emacs_value) ?*GtermInstance {
    const ptr = env.get_user_ptr.?(env, arg);
    if (emacs.check_exit(env)) return null;
    return @ptrCast(@alignCast(ptr));
}

// ── Emacs module functions ──────────────────────────────────────────────

/// (gterm-new COLS ROWS) -> user-ptr
fn gtermNew(
    env: ?*emacs.emacs_env,
    _: emacs.ptrdiff_t,
    args: [*c]emacs.emacs_value,
    _: ?*anyopaque,
) callconv(.c) emacs.emacs_value {
    const e = env.?;
    const cols_i = e.extract_integer.?(e, args[0]);
    const rows_i = e.extract_integer.?(e, args[1]);

    if (cols_i <= 0 or rows_i <= 0 or cols_i > 500 or rows_i > 500) {
        emacs.signal_error(e, "args-out-of-range", "cols and rows must be between 1 and 500");
        return emacs.nil(e);
    }

    const cols: u16 = @intCast(cols_i);
    const rows: u16 = @intCast(rows_i);

    const instance = GtermInstance.init(cols, rows) catch {
        emacs.signal_error(e, "error", "failed to allocate terminal instance");
        return emacs.nil(e);
    };

    return e.make_user_ptr.?(e, &gtermFinalizer, @ptrCast(instance));
}

/// Invoked by Emacs GC when the user-ptr is collected.
/// This is the sole owner of the GtermInstance struct memory.
/// deinit() releases the terminal/stream resources but leaves the
/// struct itself alive so this finalizer can safely read the freed flag.
fn gtermFinalizer(ptr: ?*anyopaque) callconv(.c) void {
    if (ptr) |p| {
        const instance: *GtermInstance = @ptrCast(@alignCast(p));
        instance.deinit();
        allocator.destroy(instance);
    }
}

/// (gterm-feed TERM BYTES-STRING) -> nil
fn gtermFeed(
    env: ?*emacs.emacs_env,
    _: emacs.ptrdiff_t,
    args: [*c]emacs.emacs_value,
    _: ?*anyopaque,
) callconv(.c) emacs.emacs_value {
    const e = env.?;
    const instance = getInstanceFromArg(e, args[0]) orelse return emacs.nil(e);

    // Get string length first
    var len: emacs.ptrdiff_t = 0;
    _ = e.copy_string_contents.?(e, args[1], null, &len);
    if (emacs.check_exit(e)) return emacs.nil(e);
    if (len <= 1) return emacs.nil(e); // len includes null terminator

    // Allocate buffer and copy
    const buf = allocator.alloc(u8, @intCast(len)) catch {
        emacs.signal_error(e, "error", "allocation failed");
        return emacs.nil(e);
    };
    defer allocator.free(buf);

    _ = e.copy_string_contents.?(e, args[1], buf.ptr, &len);
    if (emacs.check_exit(e)) return emacs.nil(e);

    // Feed bytes (exclude null terminator)
    const data_len: usize = @intCast(len - 1);
    instance.feed(buf[0..data_len]);

    return emacs.nil(e);
}

/// (gterm-content TERM) -> string
fn gtermContent(
    env: ?*emacs.emacs_env,
    _: emacs.ptrdiff_t,
    args: [*c]emacs.emacs_value,
    _: ?*anyopaque,
) callconv(.c) emacs.emacs_value {
    const e = env.?;
    const instance = getInstanceFromArg(e, args[0]) orelse return emacs.nil(e);

    const content = instance.renderContent() catch {
        emacs.signal_error(e, "error", "failed to read terminal content");
        return emacs.nil(e);
    };
    defer allocator.free(content);

    return e.make_string.?(e, content.ptr, @intCast(content.len));
}

/// (gterm-cursor-pos TERM) -> (ROW . COL)
fn gtermCursorPos(
    env: ?*emacs.emacs_env,
    _: emacs.ptrdiff_t,
    args: [*c]emacs.emacs_value,
    _: ?*anyopaque,
) callconv(.c) emacs.emacs_value {
    const e = env.?;
    const instance = getInstanceFromArg(e, args[0]) orelse return emacs.nil(e);
    const pos = instance.cursorPos();

    const row_val = e.make_integer.?(e, @intCast(pos.row));
    const col_val = e.make_integer.?(e, @intCast(pos.col));

    var cons_args = [_]emacs.emacs_value{ row_val, col_val };
    return e.funcall.?(e, e.intern.?(e, "cons"), 2, &cons_args);
}

/// (gterm-resize TERM COLS ROWS) -> nil
fn gtermResize(
    env: ?*emacs.emacs_env,
    _: emacs.ptrdiff_t,
    args: [*c]emacs.emacs_value,
    _: ?*anyopaque,
) callconv(.c) emacs.emacs_value {
    const e = env.?;
    const instance = getInstanceFromArg(e, args[0]) orelse return emacs.nil(e);

    const cols_i = e.extract_integer.?(e, args[1]);
    const rows_i = e.extract_integer.?(e, args[2]);

    if (cols_i <= 0 or rows_i <= 0 or cols_i > 500 or rows_i > 500) {
        emacs.signal_error(e, "args-out-of-range", "cols and rows must be between 1 and 500");
        return emacs.nil(e);
    }

    instance.resize(@intCast(cols_i), @intCast(rows_i)) catch {
        emacs.signal_error(e, "error", "resize failed");
        return emacs.nil(e);
    };

    return emacs.nil(e);
}

/// (gterm-free TERM) -> nil
fn gtermFree(
    env: ?*emacs.emacs_env,
    _: emacs.ptrdiff_t,
    args: [*c]emacs.emacs_value,
    _: ?*anyopaque,
) callconv(.c) emacs.emacs_value {
    const e = env.?;
    const instance = getInstanceFromArg(e, args[0]) orelse return emacs.nil(e);
    instance.deinit();
    return emacs.nil(e);
}

/// (gterm-cursor-keys-mode TERM) -> t or nil
/// Return t if terminal is in application cursor keys mode (DECCKM).
fn gtermCursorKeysMode(
    env_opt: ?*emacs.emacs_env,
    _: emacs.ptrdiff_t,
    args: [*c]emacs.emacs_value,
    _: ?*anyopaque,
) callconv(.c) emacs.emacs_value {
    const env = env_opt.?;
    const instance = getInstanceFromArg(env, args[0]) orelse return emacs.nil(env);
    if (instance.terminal.modes.get(.cursor_keys)) {
        return emacs.t_val(env);
    }
    return emacs.nil(env);
}

/// (gterm-cursor-info TERM) -> (VISIBLE . STYLE)
/// VISIBLE is t or nil. STYLE is 'box, 'bar, 'underline, or 'hollow.
fn gtermCursorInfo(
    env_opt: ?*emacs.emacs_env,
    _: emacs.ptrdiff_t,
    args: [*c]emacs.emacs_value,
    _: ?*anyopaque,
) callconv(.c) emacs.emacs_value {
    const env = env_opt.?;
    const instance = getInstanceFromArg(env, args[0]) orelse return emacs.nil(env);

    const visible = instance.terminal.modes.get(.cursor_visible);
    const vis_val = if (visible) emacs.t_val(env) else emacs.nil(env);

    const style_name: [*:0]const u8 = switch (instance.terminal.screens.active.cursor.cursor_style) {
        .block => "box",
        .bar => "bar",
        .underline => "hbar",
        .block_hollow => "hollow",
    };
    const style_val = env.intern.?(env, style_name);

    var cons_args = [_]emacs.emacs_value{ vis_val, style_val };
    return env.funcall.?(env, env.intern.?(env, "cons"), 2, &cons_args);
}

/// (gterm-mode-enabled TERM MODE-NUM) -> t or nil
/// Query whether a specific terminal mode is enabled.
fn gtermModeEnabled(
    env_opt: ?*emacs.emacs_env,
    _: emacs.ptrdiff_t,
    args: [*c]emacs.emacs_value,
    _: ?*anyopaque,
) callconv(.c) emacs.emacs_value {
    const env = env_opt.?;
    const instance = getInstanceFromArg(env, args[0]) orelse return emacs.nil(env);
    const mode_num = env.extract_integer.?(env, args[1]);
    if (emacs.check_exit(env)) return emacs.nil(env);

    // Try as DEC private mode first, then ANSI mode
    const mode_val: u16 = @intCast(mode_num);
    const mode = ghostty_vt.modes.modeFromInt(mode_val, false) orelse
        ghostty_vt.modes.modeFromInt(mode_val, true) orelse
        return emacs.nil(env);
    if (instance.terminal.modes.get(mode)) {
        return emacs.t_val(env);
    }
    return emacs.nil(env);
}

/// (gterm-scroll-viewport TERM DELTA) -> nil
/// Scroll viewport. Negative = up (into history), positive = down.
/// 0 = scroll to bottom (active area).
fn gtermScrollViewport(
    env_opt: ?*emacs.emacs_env,
    _: emacs.ptrdiff_t,
    args: [*c]emacs.emacs_value,
    _: ?*anyopaque,
) callconv(.c) emacs.emacs_value {
    const env = env_opt.?;
    const instance = getInstanceFromArg(env, args[0]) orelse return emacs.nil(env);
    const delta = env.extract_integer.?(env, args[1]);
    if (emacs.check_exit(env)) return emacs.nil(env);

    if (delta == 0) {
        instance.terminal.scrollViewport(.bottom);
    } else {
        instance.terminal.scrollViewport(.{ .delta = @intCast(delta) });
    }

    return emacs.nil(env);
}

/// (gterm-viewport-is-bottom TERM) -> t or nil
/// Return t if viewport is at the bottom (showing live terminal output).
fn gtermViewportIsBottom(
    env_opt: ?*emacs.emacs_env,
    _: emacs.ptrdiff_t,
    args: [*c]emacs.emacs_value,
    _: ?*anyopaque,
) callconv(.c) emacs.emacs_value {
    const env = env_opt.?;
    const instance = getInstanceFromArg(env, args[0]) orelse return emacs.nil(env);
    return switch (instance.terminal.screens.active.pages.viewport) {
        .active => emacs.t_val(env),
        else => emacs.nil(env),
    };
}

// ── Module entry point ──────────────────────────────────────────────────

/// Called by Emacs when the module is loaded via (require 'gterm-module).
export fn emacs_module_init(runtime: ?*emacs.emacs_runtime) callconv(.c) c_int {
    const rt = runtime.?;
    const env: *emacs.emacs_env = rt.get_environment.?(rt);

    // Initialize global symbol references for styling
    initGlobalSymbols(env);

    // Register functions
    emacs.defun(env, "gterm-new", 2, 2, &gtermNew,
        "Create a new gterm terminal instance.\nCOLS and ROWS specify the terminal dimensions.\nReturns an opaque terminal handle.",
    );

    emacs.defun(env, "gterm-feed", 2, 2, &gtermFeed,
        "Feed raw bytes into a gterm terminal.\nTERM is a terminal handle from `gterm-new'.\nBYTES is a unibyte string of terminal output.",
    );

    emacs.defun(env, "gterm-content", 1, 1, &gtermContent,
        "Return the visible screen content of a gterm terminal as a string.\nTERM is a terminal handle from `gterm-new'.",
    );

    emacs.defun(env, "gterm-cursor-pos", 1, 1, &gtermCursorPos,
        "Return the cursor position of a gterm terminal as (ROW . COL).\nBoth values are 0-based. TERM is a terminal handle from `gterm-new'.",
    );

    emacs.defun(env, "gterm-resize", 3, 3, &gtermResize,
        "Resize a gterm terminal to COLS columns and ROWS rows.\nTERM is a terminal handle from `gterm-new'.",
    );

    emacs.defun(env, "gterm-free", 1, 1, &gtermFree,
        "Free a gterm terminal instance.\nTERM is a terminal handle from `gterm-new'.\nThis is optional; the GC finalizer also handles cleanup.",
    );

    emacs.defun(env, "gterm-render", 1, 1, &gtermRender,
        "Render terminal content with ANSI styling into the current buffer.\nTERM is a terminal handle from `gterm-new'.\nInserts styled text directly using face properties.",
    );

    emacs.defun(env, "gterm-render-dirty", 1, 1, &gtermRenderDirty,
        "Incrementally render only dirty rows in the current buffer.\nThe buffer must already contain full terminal content from gterm-render.\nReturns cursor buffer position.",
    );

    emacs.defun(env, "gterm-cursor-keys-mode", 1, 1, &gtermCursorKeysMode,
        "Return t if terminal TERM is in application cursor keys mode (DECCKM).",
    );

    emacs.defun(env, "gterm-cursor-info", 1, 1, &gtermCursorInfo,
        "Return cursor state as (VISIBLE . STYLE) for terminal TERM.\nVISIBLE is t or nil. STYLE is box, bar, hbar, or hollow.",
    );

    emacs.defun(env, "gterm-mode-enabled", 2, 2, &gtermModeEnabled,
        "Return t if terminal mode MODE-NUM is enabled in TERM.\nMODE-NUM is the numeric mode value (e.g. 2004 for bracketed paste).",
    );

    emacs.defun(env, "gterm-scroll-viewport", 2, 2, &gtermScrollViewport,
        "Scroll viewport of terminal TERM by DELTA rows.\nNegative scrolls up (into history), positive scrolls down.\n0 scrolls to the active area (bottom).",
    );

    emacs.defun(env, "gterm-viewport-is-bottom", 1, 1, &gtermViewportIsBottom,
        "Return t if terminal TERM viewport is at the bottom (active area).",
    );

    emacs.provide(env, "gterm-module");
    return 0;
}

// ── Tests ───────────────────────────────────────────────────────────────

test "create and destroy terminal instance" {
    const instance = try GtermInstance.init(80, 24);
    defer instance.deinit();

    const pos = instance.cursorPos();
    try std.testing.expectEqual(@as(u16, 0), pos.row);
    try std.testing.expectEqual(@as(u16, 0), pos.col);
}

test "feed bytes and read content" {
    const instance = try GtermInstance.init(80, 24);
    defer instance.deinit();

    instance.feed("Hello, gterm!");

    const content = try instance.renderContent();
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "Hello, gterm!") != null);
}

test "cursor moves after printing" {
    const instance = try GtermInstance.init(80, 24);
    defer instance.deinit();

    instance.feed("ABCDE");
    const pos = instance.cursorPos();
    try std.testing.expectEqual(@as(u16, 0), pos.row);
    try std.testing.expectEqual(@as(u16, 5), pos.col);
}

test "resize terminal" {
    const instance = try GtermInstance.init(80, 24);
    defer instance.deinit();

    try instance.resize(120, 40);
    try std.testing.expectEqual(@as(u16, 120), instance.cols);
    try std.testing.expectEqual(@as(u16, 40), instance.rows);
}
