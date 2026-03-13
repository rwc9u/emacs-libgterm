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
const Allocator = std.mem.Allocator;

// We use the general purpose allocator since terminal instances are
// long-lived and few in number.
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator: Allocator = gpa.allocator();

// ── Terminal wrapper ────────────────────────────────────────────────────

const GtermInstance = struct {
    terminal: Terminal,
    rows: u16,
    cols: u16,

    pub fn init(cols: u16, rows: u16) !*GtermInstance {
        const self = try allocator.create(GtermInstance);
        self.* = .{
            .terminal = try .init(allocator, .{
                .cols = cols,
                .rows = rows,
                // Enable linefeed mode: LF (\n) implies CR (\r).
                // Emacs strips \r from PTY output, so the terminal
                // only sees \n. Without this, the cursor stays at the
                // current column on LF instead of returning to col 0.
                .default_modes = .{ .linefeed = true },
            }),
            .rows = rows,
            .cols = cols,
        };
        return self;
    }

    pub fn deinit(self: *GtermInstance) void {
        self.terminal.deinit(allocator);
        allocator.destroy(self);
    }

    /// Feed raw bytes through the terminal's VT parser.
    pub fn feed(self: *GtermInstance, bytes: []const u8) void {
        var stream = self.terminal.vtStream();
        defer stream.deinit();
        stream.nextSlice(bytes);
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
fn gtermFinalizer(ptr: ?*anyopaque) callconv(.c) void {
    if (ptr) |p| {
        const instance: *GtermInstance = @ptrCast(@alignCast(p));
        instance.deinit();
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

// ── Module entry point ──────────────────────────────────────────────────

/// Called by Emacs when the module is loaded via (require 'gterm-module).
export fn emacs_module_init(runtime: ?*emacs.emacs_runtime) callconv(.c) c_int {
    const rt = runtime.?;
    const env: *emacs.emacs_env = rt.get_environment.?(rt);

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
