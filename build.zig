const std = @import("std");

/// Try to find the emacs-module.h include directory by running `emacs`.
/// Checks several locations relative to invocation-directory to handle
/// both macOS .app bundles and Homebrew prefix installs.
/// Returns null if emacs is not found or the header is absent.
fn detectEmacsInclude(b: *std.Build) ?[]const u8 {
    const expr =
        \\(let* ((d invocation-directory)
        \\       (candidates (list
        \\         (expand-file-name "../include" d)
        \\         (expand-file-name "../Resources/include" d)
        \\         (expand-file-name "../../../include" d))))
        \\  (let ((found (seq-find (lambda (p)
        \\                  (file-exists-p (expand-file-name "emacs-module.h" p)))
        \\                candidates)))
        \\    (when found (message "%s" found))))
    ;
    const result = std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = &.{ "emacs", "--batch", "--eval", expr },
    }) catch return null;
    if (result.term != .Exited or result.term.Exited != 0) return null;
    const path = std.mem.trim(u8, result.stderr, &std.ascii.whitespace);
    if (path.len == 0) return null;
    return b.dupe(path);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_step = b.step("test", "Run unit tests");

    // Create root module for the shared library
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/gterm.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add Emacs module header include path.
    // Pass -Demacs-include=<path> to override.  Auto-detected via `emacs`
    // in PATH if not specified; falls back to the macOS .app bundle path.
    const emacs_include = b.option(
        []const u8,
        "emacs-include",
        "Path to directory containing emacs-module.h",
    ) orelse detectEmacsInclude(b) orelse
        "/Applications/Emacs.app/Contents/Resources/include";

    lib_mod.addSystemIncludePath(.{ .cwd_relative = emacs_include });

    // Add ghostty-vt dependency.
    // emit-lib-vt=true builds only libghostty-vt, skipping the macOS app,
    // xcframework, and the full libghostty — avoids requiring Xcode.
    if (b.lazyDependency("ghostty", .{
        .@"emit-lib-vt" = true,
    })) |dep| {
        lib_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }

    // Build the Emacs dynamic module as a shared library (.dylib / .so)
    const lib = b.addLibrary(.{
        .name = "gterm-module",
        .linkage = .dynamic,
        .root_module = lib_mod,
    });

    b.installArtifact(lib);

    // Tests
    const tests = b.addTest(.{
        .root_module = lib_mod,
    });
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
}
