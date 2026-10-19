//! Symbol sets. Every module asks the active set for its default symbol;
//! a module's `symbol` option in config.zon overrides it.
//! Glyphs carry their own trailing spacing so the ASCII set can be tighter.

pub const Set = enum { unicode, nerd, ascii };

pub const Glyphs = struct {
    git_branch: []const u8,
    git_detached: []const u8,
    git_staged: []const u8,
    git_modified: []const u8,
    git_deleted: []const u8,
    git_conflicted: []const u8,
    git_untracked: []const u8,
    git_ahead: []const u8,
    git_behind: []const u8,
    status: []const u8,
    duration: []const u8,
    jobs: []const u8,
    character_success: []const u8,
    character_failure: []const u8,
    python: []const u8,
    node: []const u8,
    rust: []const u8,
    go: []const u8,
    zig: []const u8,
    docker: []const u8,
    kubernetes: []const u8,
    aws: []const u8,
};

/// The default: standard Unicode only, no Private Use Area. A terminal
/// whose font lacks a symbol draws it from a fallback font, so this works
/// with any font.
pub const unicode: Glyphs = .{
    .git_branch = "\u{2387} ", // ⎇
    .git_detached = "\u{27a6} ", // ➦
    .git_staged = "+",
    .git_modified = "!",
    .git_deleted = "\u{2718}", // ✘
    .git_conflicted = "=",
    .git_untracked = "?",
    .git_ahead = "\u{21e1}", // ⇡
    .git_behind = "\u{21e3}", // ⇣
    .status = "\u{2718} ", // ✘
    .duration = "\u{25f7} ", // ◷
    .jobs = "\u{2726} ", // ✦
    .character_success = "\u{276f}", // ❯
    .character_failure = "\u{276f}",
    .python = "py ",
    .node = "\u{2b22} ", // ⬢
    .rust = "rs ",
    .go = "go ",
    .zig = "zig ",
    .docker = "docker ",
    .kubernetes = "\u{2388} ", // ⎈ (helm)
    .aws = "aws ",
};

/// Icons from the Private Use Area: needs a Nerd Font
/// (https://www.nerdfonts.com). Opt in with `.glyphs = .nerd`.
pub const nerd: Glyphs = .{
    .git_branch = "\u{e0a0} ", // nf-pl-branch
    .git_detached = "\u{f417} ", // nf-oct-git_commit
    .git_staged = "+",
    .git_modified = "!",
    .git_deleted = "\u{2718}", // ✘
    .git_conflicted = "=",
    .git_untracked = "?",
    .git_ahead = "\u{21e1}", // ⇡
    .git_behind = "\u{21e3}", // ⇣
    .status = "\u{f00d} ", // nf-fa-xmark
    .duration = "\u{f252} ", // nf-fa-hourglass_half
    .jobs = "\u{f013} ", // nf-fa-gear
    .character_success = "\u{276f}", // ❯ (plain Unicode, present in most fonts)
    .character_failure = "\u{276f}",
    .python = "\u{e73c} ", // nf-dev-python
    .node = "\u{e718} ", // nf-dev-nodejs_small
    .rust = "\u{e7a8} ", // nf-dev-rust
    .go = "\u{e627} ", // nf-seti-go
    .zig = "\u{e6a9} ", // nf-seti-zig
    .docker = "\u{f308} ", // nf-linux-docker
    .kubernetes = "\u{2388} ", // ⎈ (helm)
    .aws = "\u{e33d} ", // nf-dev-aws
};

/// Pure 7-bit ASCII for terminals or fonts without extra glyphs.
pub const ascii: Glyphs = .{
    .git_branch = "git:",
    .git_detached = "git:@",
    .git_staged = "+",
    .git_modified = "!",
    .git_deleted = "-",
    .git_conflicted = "=",
    .git_untracked = "?",
    .git_ahead = "^",
    .git_behind = "v",
    .status = "x ",
    .duration = "took ",
    .jobs = "&",
    .character_success = ">",
    .character_failure = ">",
    .python = "py ",
    .node = "node ",
    .rust = "rs ",
    .go = "go ",
    .zig = "zig ",
    .docker = "docker ",
    .kubernetes = "k8s ",
    .aws = "aws ",
};

pub fn get(set: Set) *const Glyphs {
    return switch (set) {
        .unicode => &unicode,
        .nerd => &nerd,
        .ascii => &ascii,
    };
}

test "ascii set is 7-bit clean" {
    inline for (@typeInfo(Glyphs).@"struct".fields) |f| {
        for (@field(ascii, f.name)) |c| try @import("std").testing.expect(c < 0x80);
    }
}

/// U+E000-U+F8FF and the supplementary private use planes: code points no
/// font has, except fonts patched for them (Nerd Fonts).
pub fn hasPrivateUse(s: []const u8) bool {
    const std = @import("std");
    var it = (std.unicode.Utf8View.init(s) catch return false).iterator();
    while (it.nextCodepoint()) |c| {
        if ((c >= 0xe000 and c <= 0xf8ff) or c >= 0xf0000) return true;
    }
    return false;
}

test "unicode set needs no special font" {
    inline for (@typeInfo(Glyphs).@"struct".fields) |f| {
        try @import("std").testing.expect(!hasPrivateUse(@field(unicode, f.name)));
    }
    try @import("std").testing.expect(hasPrivateUse(nerd.git_branch));
}
