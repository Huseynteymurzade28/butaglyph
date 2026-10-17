//! Rendering: modules append styled spans to a `Line`; `write` turns the line
//! into bytes for one specific shell. This file is the only place that knows
//! about ANSI escape sequences and shell prompt quoting.

const std = @import("std");
const Writer = std.Io.Writer;

pub const Shell = enum {
    bash,
    zsh,
    fish,
    /// The string `prompt` returns is printed as is, never re-evaluated.
    powershell,
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

    /// The 16 basic colors as xterm draws them, for blending.
    const basic_rgb = [16][3]u8{
        .{ 0, 0, 0 },       .{ 205, 0, 0 },   .{ 0, 205, 0 },   .{ 205, 205, 0 },
        .{ 0, 0, 238 },     .{ 205, 0, 205 }, .{ 0, 205, 205 }, .{ 229, 229, 229 },
        .{ 127, 127, 127 }, .{ 255, 0, 0 },   .{ 0, 255, 0 },   .{ 255, 255, 0 },
        .{ 92, 92, 255 },   .{ 255, 0, 255 }, .{ 0, 255, 255 }, .{ 255, 255, 255 },
    };

    fn toRgb(c: Color) [3]u8 {
        return switch (c) {
            .rgb => |v| v,
            .basic => |n| basic_rgb[n],
            .index => |n| if (n < 16) basic_rgb[n] else if (n < 232) blk: {
                const steps = [6]u8{ 0, 95, 135, 175, 215, 255 };
                const k = n - 16;
                break :blk .{ steps[k / 36], steps[(k / 6) % 6], steps[k % 6] };
            } else blk: {
                const v: u8 = 8 + (n - 232) * 10;
                break :blk .{ v, v, v };
            },
        };
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

/// What a color string paints: one color, a gradient through several
/// ("#ff0080>#7928ca>#00e5ff", blended in OKLab so the middle stays
/// vivid), or a "rainbow". Gradients and rainbows run across the
/// characters of a span, and across neighboring spans in the same style.
pub const Paint = union(enum) {
    none,
    solid: Color,
    gradient: struct { stops: [max_stops][3]u8, len: u8 },
    rainbow,

    pub const max_stops = 8;

    pub fn parse(spec: ?[]const u8) Paint {
        const s = std.mem.trim(u8, spec orelse return .none, " ");
        if (std.mem.eql(u8, s, "rainbow")) return .rainbow;
        if (std.mem.indexOfScalar(u8, s, '>') == null) return if (Color.parse(s)) |c| .{ .solid = c } else .none;
        var g: @FieldType(Paint, "gradient") = .{ .stops = undefined, .len = 0 };
        var it = std.mem.splitScalar(u8, s, '>');
        while (it.next()) |part| {
            const c = Color.parse(std.mem.trim(u8, part, " ")) orelse continue;
            if (g.len == max_stops) break;
            g.stops[g.len] = c.toRgb();
            g.len += 1;
        }
        return switch (g.len) {
            0 => .none,
            1 => .{ .solid = .{ .rgb = g.stops[0] } },
            else => .{ .gradient = g },
        };
    }

    fn varies(p: Paint) bool {
        return p == .gradient or p == .rainbow;
    }

    /// The color of character `i` of `n`.
    fn at(p: Paint, i: usize, n: usize) ?Color {
        const t: f32 = if (n <= 1) 0 else @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n - 1));
        return switch (p) {
            .none => null,
            .solid => |c| c,
            .rainbow => .{ .rgb = hsv(t * 300, 0.78, 1) }, // red to magenta
            .gradient => |g| blk: {
                const pos = t * @as(f32, @floatFromInt(g.len - 1));
                const k: usize = @min(@as(usize, @intFromFloat(pos)), g.len - 2);
                break :blk .{ .rgb = mixOklab(g.stops[k], g.stops[k + 1], pos - @as(f32, @floatFromInt(k))) };
            },
        };
    }

    /// The color a gradient starts or ends with, as a color string slice of
    /// `spec` (segment joints are drawn in it).
    pub fn edge(spec: []const u8, last: bool) []const u8 {
        const s = std.mem.trim(u8, spec, " ");
        if (std.mem.eql(u8, s, "rainbow")) return if (last) "#ff38d1" else "#ff3838";
        const i = if (last) std.mem.lastIndexOfScalar(u8, s, '>') else std.mem.indexOfScalar(u8, s, '>');
        const part = if (i) |k| (if (last) s[k + 1 ..] else s[0..k]) else s;
        return std.mem.trim(u8, part, " ");
    }
};

fn hsv(h: f32, s: f32, v: f32) [3]u8 {
    const c = v * s;
    const hp = @mod(h, 360) / 60;
    const x = c * (1 - @abs(@mod(hp, 2) - 1));
    const rgb: [3]f32 = switch (@as(u3, @intFromFloat(hp))) {
        0 => .{ c, x, 0 },
        1 => .{ x, c, 0 },
        2 => .{ 0, c, x },
        3 => .{ 0, x, c },
        4 => .{ x, 0, c },
        else => .{ c, 0, x },
    };
    const m = v - c;
    var out: [3]u8 = undefined;
    for (&out, rgb) |*o, ch| o.* = @intFromFloat(@round(std.math.clamp(ch + m, 0, 1) * 255));
    return out;
}

fn toLinear(c: u8) f32 {
    const x = @as(f32, @floatFromInt(c)) / 255;
    return if (x <= 0.04045) x / 12.92 else std.math.pow(f32, (x + 0.055) / 1.055, 2.4);
}

fn fromLinear(x: f32) u8 {
    const v = std.math.clamp(x, 0, 1);
    const s = if (v <= 0.0031308) v * 12.92 else 1.055 * std.math.pow(f32, v, 1.0 / 2.4) - 0.055;
    return @intFromFloat(@round(std.math.clamp(s, 0, 1) * 255));
}

fn toOklab(c: [3]u8) [3]f32 {
    const r = toLinear(c[0]);
    const g = toLinear(c[1]);
    const b = toLinear(c[2]);
    const l = std.math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
    const m = std.math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
    const s = std.math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
    return .{
        0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
        1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
        0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
    };
}

fn fromOklab(lab: [3]f32) [3]u8 {
    const l = std.math.pow(f32, lab[0] + 0.3963377774 * lab[1] + 0.2158037573 * lab[2], 3);
    const m = std.math.pow(f32, lab[0] - 0.1055613458 * lab[1] - 0.0638541728 * lab[2], 3);
    const s = std.math.pow(f32, lab[0] - 0.0894841775 * lab[1] - 1.2914855480 * lab[2], 3);
    return .{
        fromLinear(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
        fromLinear(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
        fromLinear(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s),
    };
}

fn mixOklab(a: [3]u8, b: [3]u8, t: f32) [3]u8 {
    const x = toOklab(a);
    const y = toOklab(b);
    var out: [3]f32 = undefined;
    for (&out, x, y) |*o, p, q| o.* = p + (q - p) * t;
    return fromOklab(out);
}

/// Style as written in config.zon. Colors stay strings until render time;
/// an unrecognized color is simply not applied. See `Paint` for gradients.
pub const Style = struct {
    fg: ?[]const u8 = null,
    bg: ?[]const u8 = null,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    /// Swaps foreground and background.
    inverse: bool = false,
    strikethrough: bool = false,

    pub fn eql(a: Style, b: Style) bool {
        inline for (@typeInfo(Style).@"struct".fields) |f| {
            const x = @field(a, f.name);
            const y = @field(b, f.name);
            if (f.type == bool) {
                if (x != y) return false;
            } else if (x == null or y == null) {
                if (x != null or y != null) return false;
            } else if (!std.mem.eql(u8, x.?, y.?)) return false;
        }
        return true;
    }

    /// Writes the SGR sequence (e.g. "\x1b[1;36m") for this style with the
    /// given colors into `w`. Writes nothing and returns false if it has no
    /// visible effect.
    fn writeSgr(s: Style, fg: ?Color, bg: ?Color, w: *Writer) Writer.Error!bool {
        var any = false;
        const flags = [_]struct { bool, u8 }{
            .{ s.bold, 1 },  .{ s.dim, 2 },     .{ s.italic, 3 },        .{ s.underline, 4 },
            .{ s.blink, 5 }, .{ s.inverse, 7 }, .{ s.strikethrough, 9 },
        };
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

    pub const max_spans = 128;
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

    /// Inserts `spans` before position `at`.
    pub fn insert(line: *Line, at: usize, spans: []const Span) Error!void {
        if (line.len + spans.len > max_spans) return error.NoSpaceLeft;
        std.mem.copyBackwards(Span, line.spans[at + spans.len .. line.len + spans.len], line.spans[at..line.len]);
        @memcpy(line.spans[at..][0..spans.len], spans);
        line.len += spans.len;
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
    const spans = line.items();
    var i: usize = 0;
    while (i < spans.len) {
        const span = spans[i];
        if (span.kind == .newline) {
            try w.writeByte('\n');
            i += 1;
            continue;
        }
        const fg = Paint.parse(span.style.fg);
        const bg = Paint.parse(span.style.bg);
        if (!fg.varies() and !bg.varies()) {
            try writeStyled(shell, w, span.style, fg.at(0, 1), bg.at(0, 1), span.text);
            i += 1;
            continue;
        }
        // A gradient runs across this span and the following ones in the
        // same style, one color per character.
        var end = i + 1;
        while (end < spans.len and spans[end].kind == .text and spans[end].style.eql(span.style)) end += 1;
        var n: usize = 0;
        for (spans[i..end]) |s| n += codepoints(s.text);
        var k: usize = 0;
        for (spans[i..end]) |s| {
            var pos: usize = 0;
            while (pos < s.text.len) : (k += 1) {
                const len = @min(s.text.len - pos, std.unicode.utf8ByteSequenceLength(s.text[pos]) catch 1);
                try writeStyled(shell, w, span.style, fg.at(k, n), bg.at(k, n), s.text[pos..][0..len]);
                pos += len;
            }
        }
        i = end;
    }
}

fn writeStyled(shell: Shell, w: *Writer, style: Style, fg: ?Color, bg: ?Color, text: []const u8) Writer.Error!void {
    var sgr_buf: [96]u8 = undefined;
    var sgr: Writer = .fixed(&sgr_buf);
    const styled = style.writeSgr(fg, bg, &sgr) catch false;
    if (styled) try writeNonPrinting(shell, w, sgr.buffered());
    try writeEscaped(shell, w, text);
    if (styled) try writeNonPrinting(shell, w, "\x1b[0m");
}

fn codepoints(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

fn writeNonPrinting(shell: Shell, w: *Writer, seq: []const u8) Writer.Error!void {
    const open, const close = switch (shell) {
        .bash => .{ "\\[", "\\]" },
        .zsh => .{ "%{", "%}" },
        .fish, .powershell, .plain => .{ "", "" },
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
            .fish, .powershell, .plain => null,
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

test "gradients run across a span and its same-styled neighbors" {
    var line: Line = .{};
    try line.text(.{ .fg = "#000000 > #ffffff" }, "ab");
    try line.text(.{ .fg = "#000000 > #ffffff" }, "c");
    try line.text(.{}, "!");
    var buf: [512]u8 = undefined;
    const out = try renderToString(&line, .plain, &buf);
    try std.testing.expect(std.mem.startsWith(u8, out, "\x1b[38;2;0;0;0ma\x1b[0m"));
    try std.testing.expect(std.mem.endsWith(u8, out, "\x1b[38;2;255;255;255mc\x1b[0m!"));
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, out, "\x1b[38;2;"));
    // bash still wraps every sequence.
    const bash = try renderToString(&line, .bash, &buf);
    try std.testing.expectEqual(@as(usize, 6), std.mem.count(u8, bash, "\\["));
}

test "rainbow, multi-stop gradients and gradient edges" {
    var line: Line = .{};
    try line.text(.{ .bg = "rainbow", .bold = true }, "xyz");
    var buf: [512]u8 = undefined;
    const out = try renderToString(&line, .plain, &buf);
    try std.testing.expect(std.mem.startsWith(u8, out, "\x1b[1;48;2;255;56;56mx"));

    const p = Paint.parse("red>#00ff00>blue");
    try std.testing.expectEqual(@as(u8, 3), p.gradient.len);
    try std.testing.expectEqual([3]u8{ 0, 255, 0 }, p.at(1, 3).?.rgb);
    try std.testing.expectEqualStrings("red", Paint.edge("red > #00ff00 > blue", false));
    try std.testing.expectEqualStrings("blue", Paint.edge("red > #00ff00 > blue", true));
    try std.testing.expectEqualStrings("cyan", Paint.edge("cyan", true));
    try std.testing.expect(Paint.parse("nope") == .none);
    try std.testing.expect(Paint.parse("#zz0000>nope") == .none);
}

test "OKLab blending keeps the middle of a gradient bright" {
    // Red to blue through OKLab is a vivid purple, not the muddy
    // (128, 0, 128) of a plain RGB average.
    const mid = mixOklab(.{ 255, 0, 0 }, .{ 0, 0, 255 }, 0.5);
    try std.testing.expect(@as(u16, mid[0]) + mid[2] > 300);
    try std.testing.expectEqual([3]u8{ 18, 52, 86 }, mixOklab(.{ 18, 52, 86 }, .{ 18, 52, 86 }, 0.3));
}

test "extra style flags" {
    var line: Line = .{};
    try line.text(.{ .blink = true, .inverse = true, .strikethrough = true }, "x");
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[5;7;9mx\x1b[0m", try renderToString(&line, .plain, &buf));
}
