//! Rendering: modules append styled spans to a `Line`; `write` turns the line
//! into bytes for one specific shell. This file is the only place that knows
//! about ANSI escape sequences and shell prompt quoting.

const std = @import("std");
const Writer = std.Io.Writer;

pub const Shell = enum {
    bash,
    zsh,
    fish,
    /// Raw ANSI output with no prompt quoting (debugging, other consumers).
    plain,
};

pub const Color = union(enum) {
    /// The 16 terminal palette colors (0-7 normal, 8-15 bright).
    basic: u4,
    /// xterm 256-color palette.
    index: u8,
    rgb: [3]u8,

    const names = [_][]const u8{ "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white" };

    /// Accepts "red", "bright_red", "208" or "#ff8800". Returns null for anything else.
    pub fn parse(s: []const u8) ?Color {
        if (s.len == 7 and s[0] == '#') {
            var rgb: [3]u8 = undefined;
            for (&rgb, 0..) |*c, i| {
                c.* = std.fmt.parseInt(u8, s[1 + 2 * i ..][0..2], 16) catch return null;
            }
            return .{ .rgb = rgb };
        }
        if (std.fmt.parseInt(u8, s, 10)) |n| return .{ .index = n } else |_| {}
        const bright_prefix = "bright_";
        const bright = std.mem.startsWith(u8, s, bright_prefix);
        const name = if (bright) s[bright_prefix.len..] else s;
        for (names, 0..) |candidate, i| {
            if (std.mem.eql(u8, name, candidate)) {
                return .{ .basic = @intCast(if (bright) i + 8 else i) };
            }
        }
        return null;
    }

    fn writeSgr(c: Color, w: *Writer, background: bool) Writer.Error!void {
        switch (c) {
            .basic => |n| {
                const base: u8 = if (background) 40 else 30;
                const code = if (n < 8) base + n else base + 60 + (n - 8);
                try w.print("{d}", .{code});
            },
            .index => |n| try w.print("{d};5;{d}", .{ @as(u8, if (background) 48 else 38), n }),
            .rgb => |v| try w.print("{d};2;{d};{d};{d}", .{ @as(u8, if (background) 48 else 38), v[0], v[1], v[2] }),
        }
    }
};

/// Style as written in config.zon. Colors stay strings until render time;
/// an unrecognized color is simply not applied.
pub const Style = struct {
    fg: ?[]const u8 = null,
    bg: ?[]const u8 = null,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,

    /// Writes the SGR sequence (e.g. "\x1b[1;36m") into `w`. Writes nothing
    /// and returns false if the style has no visible effect.
    fn writeSgr(s: Style, w: *Writer) Writer.Error!bool {
        const fg = if (s.fg) |f| Color.parse(f) else null;
        const bg = if (s.bg) |b| Color.parse(b) else null;
        var any = false;
        const flags = [_]struct { bool, u8 }{ .{ s.bold, 1 }, .{ s.dim, 2 }, .{ s.italic, 3 }, .{ s.underline, 4 } };
        for (flags) |flag| {
            if (!flag[0]) continue;
            try w.writeAll(if (any) ";" else "\x1b[");
            try w.print("{d}", .{flag[1]});
            any = true;
        }
        inline for (.{ .{ fg, false }, .{ bg, true } }) |pair| {
            if (pair[0]) |c| {
                try w.writeAll(if (any) ";" else "\x1b[");
                try c.writeSgr(w, pair[1]);
                any = true;
            }
        }
        if (any) try w.writeByte('m');
        return any;
    }
};

/// Fixed-capacity list of styled spans. No heap: span text either points at
/// memory that outlives rendering (config, glyphs, module data) or is
/// formatted into the line's own scratch buffer via `print`.
pub const Line = struct {
    spans: [max_spans]Span = undefined,
    len: usize = 0,
    scratch: [scratch_size]u8 = undefined,
    scratch_used: usize = 0,

    pub const max_spans = 64;
    pub const scratch_size = 4096;
    pub const Error = error{NoSpaceLeft};

    pub const Span = struct {
        style: Style,
        kind: enum { text, newline },
        text: []const u8,
    };

    /// Snapshot used to roll back a module's partial output.
    pub const Mark = struct { len: usize, scratch_used: usize };

    pub fn text(line: *Line, style: Style, s: []const u8) Error!void {
        if (s.len == 0) return;
        try line.push(.{ .style = style, .kind = .text, .text = s });
    }

    pub fn print(line: *Line, style: Style, comptime fmt: []const u8, args: anytype) Error!void {
        const out = std.fmt.bufPrint(line.scratch[line.scratch_used..], fmt, args) catch return error.NoSpaceLeft;
        // Reserve span capacity before committing scratch so a failure leaves the line unchanged.
        if (line.len == max_spans) return error.NoSpaceLeft;
        line.scratch_used += out.len;
        try line.text(style, out);
    }

    /// Returns a slice of scratch space the caller may fill and then pass to
    /// `commitScratch`. Used for output that is built piecewise (e.g. paths).
    pub fn scratchBuffer(line: *Line) []u8 {
        return line.scratch[line.scratch_used..];
    }

    pub fn commitScratch(line: *Line, style: Style, len: usize) Error!void {
        if (line.len == max_spans) return error.NoSpaceLeft;
        const s = line.scratch[line.scratch_used..][0..len];
        line.scratch_used += len;
        try line.text(style, s);
    }

    pub fn newline(line: *Line) Error!void {
        try line.push(.{ .style = .{}, .kind = .newline, .text = "\n" });
    }

    pub fn mark(line: *const Line) Mark {
        return .{ .len = line.len, .scratch_used = line.scratch_used };
    }

    pub fn restore(line: *Line, m: Mark) void {
        line.len = m.len;
        line.scratch_used = m.scratch_used;
    }

    pub fn items(line: *const Line) []const Span {
        return line.spans[0..line.len];
    }

    fn push(line: *Line, span: Span) Error!void {
        if (line.len == max_spans) return error.NoSpaceLeft;
        line.spans[line.len] = span;
        line.len += 1;
    }
};

/// Serializes `line` for `shell`. Escape sequences are wrapped so the line
/// editor treats them as zero-width; user-controlled text (paths, branch
/// names) is quoted so the shell cannot interpret it.
pub fn write(line: *const Line, shell: Shell, w: *Writer) Writer.Error!void {
    for (line.items()) |span| {
        switch (span.kind) {
            .newline => try w.writeByte('\n'),
            .text => {
                var sgr_buf: [64]u8 = undefined;
                var sgr: Writer = .fixed(&sgr_buf);
                const styled = span.style.writeSgr(&sgr) catch false;
                if (styled) try writeNonPrinting(shell, w, sgr.buffered());
                try writeEscaped(shell, w, span.text);
                if (styled) try writeNonPrinting(shell, w, "\x1b[0m");
            },
        }
    }
}

fn writeNonPrinting(shell: Shell, w: *Writer, seq: []const u8) Writer.Error!void {
    const open, const close = switch (shell) {
        .bash => .{ "\\[", "\\]" },
        .zsh => .{ "%{", "%}" },
        .fish, .plain => .{ "", "" },
    };
    try w.writeAll(open);
    try w.writeAll(seq);
    try w.writeAll(close);
}

/// bash: PS1 is decoded twice: first prompt backslash escapes (`\\` -> `\`,
/// `\$` -> `$` or `#`!), then (with promptvars) expansion as if inside double
/// quotes. Each special character therefore has to survive both passes:
///   `\` -> `\\\\`,  `$` -> `\\$`,  backtick -> `\\` + backtick.
/// zsh: the init script sets PROMPT='${__buta_prompt}', so the value is never
/// re-expanded; only prompt `%` sequences are interpreted.
/// Control characters (ESC, newline, \x01/\x02 readline markers) are replaced
/// so a hostile directory name cannot inject escape sequences.
fn writeEscaped(shell: Shell, w: *Writer, s: []const u8) Writer.Error!void {
    var start: usize = 0;
    for (s, 0..) |c, i| {
        const replacement: ?[]const u8 = if (c < 0x20 or c == 0x7f)
            "?"
        else switch (shell) {
            .bash => switch (c) {
                '\\' => "\\\\\\\\",
                '$' => "\\\\$",
                '`' => "\\\\`",
                else => null,
            },
            .zsh => if (c == '%') "%%" else null,
            .fish, .plain => null,
        };
        if (replacement) |r| {
            try w.writeAll(s[start..i]);
            try w.writeAll(r);
            start = i + 1;
        }
    }
    try w.writeAll(s[start..]);
}

fn renderToString(line: *const Line, shell: Shell, buf: []u8) ![]const u8 {
    var w: Writer = .fixed(buf);
    try write(line, shell, &w);
    return w.buffered();
}

test "color parsing" {
    try std.testing.expectEqual(Color{ .basic = 1 }, Color.parse("red").?);
    try std.testing.expectEqual(Color{ .basic = 14 }, Color.parse("bright_cyan").?);
    try std.testing.expectEqual(Color{ .index = 208 }, Color.parse("208").?);
    try std.testing.expectEqual(Color{ .rgb = .{ 0xff, 0x88, 0x00 } }, Color.parse("#ff8800").?);
    try std.testing.expectEqual(@as(?Color, null), Color.parse("#ff88"));
    try std.testing.expectEqual(@as(?Color, null), Color.parse("purple"));
    try std.testing.expectEqual(@as(?Color, null), Color.parse("256"));
}

test "bash wraps escape sequences in \\[ \\]" {
    var line: Line = .{};
    try line.text(.{ .fg = "cyan", .bold = true }, "~/src");
    try line.text(.{}, " ");
    try line.text(.{ .fg = "#010203" }, "x");
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "\\[\x1b[1;36m\\]~/src\\[\x1b[0m\\] \\[\x1b[38;2;1;2;3m\\]x\\[\x1b[0m\\]",
        try renderToString(&line, .bash, &buf),
    );
}

test "zsh wraps escape sequences in %{ %}" {
    var line: Line = .{};
    try line.text(.{ .fg = "bright_red", .bg = "17" }, "err");
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "%{\x1b[91;48;5;17m%}err%{\x1b[0m%}",
        try renderToString(&line, .zsh, &buf),
    );
}

test "fish and plain output raw sequences" {
    var line: Line = .{};
    try line.text(.{ .fg = "green" }, "ok");
    try line.newline();
    try line.text(.{}, "> ");
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[32mok\x1b[0m\n> ", try renderToString(&line, .fish, &buf));
    try std.testing.expectEqualStrings("\x1b[32mok\x1b[0m\n> ", try renderToString(&line, .plain, &buf));
}

test "unknown colors produce no escape sequence" {
    var line: Line = .{};
    try line.text(.{ .fg = "nope" }, "a");
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("a", try renderToString(&line, .bash, &buf));
}

test "user text is quoted per shell" {
    var line: Line = .{};
    try line.text(.{}, "$(rm -rf ~)`id`\\w 100%");
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "\\\\$(rm -rf ~)\\\\`id\\\\`\\\\\\\\w 100%",
        try renderToString(&line, .bash, &buf),
    );
    try std.testing.expectEqualStrings("$(rm -rf ~)`id`\\w 100%%", try renderToString(&line, .zsh, &buf));
    try std.testing.expectEqualStrings("$(rm -rf ~)`id`\\w 100%", try renderToString(&line, .fish, &buf));
}

test "control characters are neutralized" {
    var line: Line = .{};
    try line.text(.{}, "a\x1b[2Jb\x01c\nd");
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("a?[2Jb?c?d", try renderToString(&line, .bash, &buf));
}

test "line capacity and rollback" {
    var line: Line = .{};
    try line.text(.{}, "keep");
    const m = line.mark();
    try line.print(.{}, "{d}", .{42});
    try std.testing.expectEqual(@as(usize, 2), line.len);
    line.restore(m);
    try std.testing.expectEqual(@as(usize, 1), line.len);
    try std.testing.expectEqual(@as(usize, 0), line.scratch_used);
    for (1..Line.max_spans) |_| try line.text(.{}, "x");
    try std.testing.expectError(error.NoSpaceLeft, line.text(.{}, "overflow"));
    try std.testing.expectError(error.NoSpaceLeft, line.print(.{}, "{d}", .{1}));
    try std.testing.expectEqual(@as(usize, 0), line.scratch_used);
}
