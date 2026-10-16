//! Symbol sets. Every module asks the active set for its default symbol;
//! a module's `symbol` option in config.zon overrides it.
//! Glyphs carry their own trailing spacing so the ASCII set can be tighter.

pub const Set = enum { nerd, ascii };

pub const Glyphs = struct {
    git_branch: []const u8,
    git_detached: []const u8,
    status: []const u8,
    duration: []const u8,
    jobs: []const u8,
    character_success: []const u8,
    character_failure: []const u8,
};

/// Requires a Nerd Font (https://www.nerdfonts.com).
pub const nerd: Glyphs = .{
    .git_branch = "\u{e0a0} ", // nf-pl-branch
    .git_detached = "\u{f417} ", // nf-oct-git_commit
    .status = "\u{f00d} ", // nf-fa-xmark
    .duration = "\u{f252} ", // nf-fa-hourglass_half
    .jobs = "\u{f013} ", // nf-fa-gear
    .character_success = "\u{276f}", // ❯ (plain Unicode, present in most fonts)
    .character_failure = "\u{276f}",
};

/// Pure 7-bit ASCII for terminals or fonts without extra glyphs.
pub const ascii: Glyphs = .{
    .git_branch = "git:",
    .git_detached = "git:@",
    .status = "x ",
    .duration = "took ",
    .jobs = "&",
    .character_success = ">",
    .character_failure = ">",
};

pub fn get(set: Set) *const Glyphs {
    return switch (set) {
        .nerd => &nerd,
        .ascii => &ascii,
    };
}

test "ascii set is 7-bit clean" {
    inline for (@typeInfo(Glyphs).@"struct".fields) |f| {
        for (@field(ascii, f.name)) |c| try @import("std").testing.expect(c < 0x80);
    }
}
