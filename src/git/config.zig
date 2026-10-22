//! A small git-config reader: enough to look up single values such as
//! `branch.<name>.remote`. Section and key names are case-insensitive,
//! subsection names case-sensitive; the last occurrence of a key wins.
//! `[include]` and `[includeIf]` are listed by `includes`; following them
//! is up to the caller (see status.zig), since conditions need the repository.

const std = @import("std");

pub const Config = struct {
    text: []const u8,

    /// Looks up `section.subsection.key` (subsection may be null) and writes
    /// the unquoted, unescaped value into `buf`. A key present without `=`
    /// is boolean true and yields "true".
    pub fn get(c: Config, section: []const u8, subsection: ?[]const u8, key: []const u8, buf: []u8) ?[]const u8 {
        var result: ?[]const u8 = null;
        var in_section = false;
        var lines = std.mem.splitScalar(u8, c.text, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
            if (line[0] == '[') {
                in_section = matchHeader(line, section, subsection);
                // A header may be followed by a key on the same line.
                const close = std.mem.indexOfScalar(u8, line, ']') orelse continue;
                const after = std.mem.trim(u8, line[close + 1 ..], " \t");
                if (in_section and after.len > 0) {
                    if (matchKey(after, key, buf)) |v| result = v;
                }
                continue;
            }
            if (in_section) {
                if (matchKey(line, key, buf)) |v| result = v;
            }
        }
        return result;
    }
};

/// An `[include]` or `[includeIf "<condition>"]` section's `path`.
pub const Include = struct {
    /// null for `[include]`.
    condition: ?[]const u8,
    path: []const u8,
    /// Offset just past the line that names it: the included file's
    /// settings count as if they were written there.
    end: usize,
    /// The section header in effect at `end`, for reading the rest of the
    /// file on its own.
    header: []const u8,
};

/// The include paths of `c`, in file order.
pub fn includes(c: Config, arena: std.mem.Allocator) ![]const Include {
    var list: std.ArrayList(Include) = .empty;
    var walker: Walker = .{ .text = c.text };
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    while (walker.next()) |line| {
        const header = parseHeader(walker.header) orelse continue;
        const condition: ?[]const u8 = if (std.ascii.eqlIgnoreCase(header.name, "include") and header.sub == null)
            null
        else if (std.ascii.eqlIgnoreCase(header.name, "includeif") and header.sub != null)
            try unescapeSubsection(arena, header.sub.?)
        else
            continue;
        const path = matchKey(line, "path", &buf) orelse continue;
        try list.append(arena, .{ .condition = condition, .path = try arena.dupe(u8, path), .end = walker.pos, .header = walker.header });
    }
    return list.items;
}

/// Appends every `remote.<name>.url` value in `c` to `urls`.
pub fn remoteUrls(c: Config, arena: std.mem.Allocator, urls: *std.ArrayList([]const u8)) !void {
    var walker: Walker = .{ .text = c.text };
    var buf: [4096]u8 = undefined;
    while (walker.next()) |line| {
        const header = parseHeader(walker.header) orelse continue;
        if (!std.ascii.eqlIgnoreCase(header.name, "remote") or header.sub == null) continue;
        const url = matchKey(line, "url", &buf) orelse continue;
        try urls.append(arena, try arena.dupe(u8, url));
    }
}

/// The key lines of a config file, with the section header each is under.
const Walker = struct {
    text: []const u8,
    /// Offset of the next line.
    pos: usize = 0,
    /// The current `[...]` header, brackets included ("" before the first).
    header: []const u8 = "",

    fn next(w: *Walker) ?[]const u8 {
        while (w.pos < w.text.len) {
            const end = std.mem.indexOfScalarPos(u8, w.text, w.pos, '\n') orelse w.text.len;
            var line = std.mem.trim(u8, w.text[w.pos..end], " \t\r");
            w.pos = @min(w.text.len, end + 1);
            if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
            if (line[0] == '[') {
                const close = std.mem.indexOfScalar(u8, line, ']') orelse continue;
                w.header = line[0 .. close + 1];
                // A header may be followed by a key on the same line.
                line = std.mem.trim(u8, line[close + 1 ..], " \t");
                if (line.len == 0) continue;
            }
            return line;
        }
        return null;
    }
};

const Header = struct { name: []const u8, sub: ?[]const u8 };

/// `[name "sub"]` (sub still quoted-escaped), `[name.sub]` or `[name]`.
fn parseHeader(header: []const u8) ?Header {
    if (header.len < 2) return null;
    const inner = std.mem.trim(u8, header[1 .. header.len - 1], " \t");
    if (std.mem.indexOfScalar(u8, inner, '"')) |q| {
        const end = std.mem.lastIndexOfScalar(u8, inner, '"') orelse return null;
        if (end <= q) return null;
        return .{ .name = std.mem.trim(u8, inner[0..q], " \t"), .sub = inner[q + 1 .. end] };
    }
    if (std.mem.indexOfScalar(u8, inner, '.')) |dot| return .{ .name = inner[0..dot], .sub = inner[dot + 1 ..] };
    return .{ .name = inner, .sub = null };
}

fn unescapeSubsection(arena: std.mem.Allocator, quoted: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < quoted.len) : (i += 1) {
        if (quoted[i] == '\\' and i + 1 < quoted.len) i += 1;
        try out.append(arena, quoted[i]);
    }
    return out.items;
}

fn matchHeader(line: []const u8, section: []const u8, subsection: ?[]const u8) bool {
    const close = std.mem.indexOfScalar(u8, line, ']') orelse return false;
    const inner = std.mem.trim(u8, line[1..close], " \t");
    if (std.mem.indexOfScalar(u8, inner, '"')) |q| {
        // [section "subsection"]
        const name = std.mem.trim(u8, inner[0..q], " \t");
        if (!std.ascii.eqlIgnoreCase(name, section)) return false;
        const sub = subsection orelse return false;
        const end = std.mem.lastIndexOfScalar(u8, inner, '"') orelse return false;
        if (end <= q) return false;
        return subsectionEql(inner[q + 1 .. end], sub);
    }
    if (std.mem.indexOfScalar(u8, inner, '.')) |dot| {
        // Deprecated [section.subsection] form: subsection compared case-insensitively.
        const sub = subsection orelse return false;
        return std.ascii.eqlIgnoreCase(inner[0..dot], section) and std.ascii.eqlIgnoreCase(inner[dot + 1 ..], sub);
    }
    return subsection == null and std.ascii.eqlIgnoreCase(inner, section);
}

/// Compares a quoted subsection (with `\"` and `\\` escapes) to `want`.
fn subsectionEql(quoted: []const u8, want: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (i < quoted.len) : (i += 1) {
        var c = quoted[i];
        if (c == '\\' and i + 1 < quoted.len) {
            i += 1;
            c = quoted[i];
        }
        if (j >= want.len or want[j] != c) return false;
        j += 1;
    }
    return j == want.len;
}

fn matchKey(line: []const u8, key: []const u8, buf: []u8) ?[]const u8 {
    var name_end: usize = 0;
    while (name_end < line.len and (std.ascii.isAlphanumeric(line[name_end]) or line[name_end] == '-')) name_end += 1;
    if (!std.ascii.eqlIgnoreCase(line[0..name_end], key)) return null;
    const rest = std.mem.trimStart(u8, line[name_end..], " \t");
    if (rest.len == 0 or rest[0] == '#' or rest[0] == ';') return "true";
    if (rest[0] != '=') return null;
    return parseValue(std.mem.trim(u8, rest[1..], " \t"), buf);
}

fn parseValue(raw: []const u8, buf: []u8) ?[]const u8 {
    var n: usize = 0;
    var quoted = false;
    var pending_space: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        var c = raw[i];
        if (!quoted and (c == '#' or c == ';')) break;
        if (c == '"') {
            quoted = !quoted;
            continue;
        }
        if (c == '\\' and i + 1 < raw.len) {
            i += 1;
            c = switch (raw[i]) {
                'n' => '\n',
                't' => '\t',
                'b' => 8,
                else => raw[i],
            };
        } else if (!quoted and (c == ' ' or c == '\t')) {
            pending_space += 1; // trailing unquoted whitespace is dropped
            continue;
        }
        while (pending_space > 0) : (pending_space -= 1) {
            if (n == buf.len) return null;
            buf[n] = ' ';
            n += 1;
        }
        if (n == buf.len) return null;
        buf[n] = c;
        n += 1;
    }
    return buf[0..n];
}

test Config {
    const c: Config = .{ .text =
        \\# comment
        \\[core]
        \\    repositoryformatversion = 0
        \\    bare = false
        \\[Branch "main"]
        \\    remote = origin
        \\    merge = refs/heads/main
        \\[branch "Main"]
        \\    remote = other
        \\[branch "feat/x"]
        \\    REMOTE = "up stream" ; trailing comment
        \\    merge = refs/heads/feat/x  # another
        \\[remote "origin"]
        \\    url = https://example.com/r.git
        \\[branch.legacy]
        \\    remote = old
        \\[extensions]
        \\    objectFormat = sha256
        \\    worktreeConfig
        \\[branch "main"]
        \\    merge = refs/heads/trunk
    };
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("origin", c.get("branch", "main", "remote", &buf).?);
    try std.testing.expectEqualStrings("refs/heads/trunk", c.get("branch", "main", "merge", &buf).?); // last wins
    try std.testing.expectEqualStrings("other", c.get("branch", "Main", "remote", &buf).?); // subsection is case-sensitive
    try std.testing.expectEqualStrings("up stream", c.get("branch", "feat/x", "remote", &buf).?);
    try std.testing.expectEqualStrings("refs/heads/feat/x", c.get("branch", "feat/x", "merge", &buf).?);
    try std.testing.expectEqualStrings("old", c.get("branch", "legacy", "remote", &buf).?);
    try std.testing.expectEqualStrings("sha256", c.get("extensions", null, "objectformat", &buf).?);
    try std.testing.expectEqualStrings("true", c.get("extensions", null, "worktreeconfig", &buf).?);
    try std.testing.expectEqualStrings("false", c.get("core", null, "bare", &buf).?);
    try std.testing.expectEqual(@as(?[]const u8, null), c.get("branch", "nope", "remote", &buf));
    try std.testing.expectEqual(@as(?[]const u8, null), c.get("core", null, "missing", &buf));
}

test includes {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text =
        \\[core]
        \\    x = 1
        \\[include]
        \\    path = a.inc
        \\    path = "~/b.inc"
        \\[includeIf "gitdir:~/work/"] path = c.inc
        \\[includeIf "onbranch:feat/\"x\""]
        \\    path = d.inc
        \\[includeIf]
        \\    path = ignored
        \\[remote "origin"]
        \\    url = https://example.com/r.git
        \\[remote "up"]
        \\    url = git@example.com:r.git
        \\
    ;
    const c: Config = .{ .text = text };
    const list = try includes(c, arena);
    try std.testing.expectEqual(@as(usize, 4), list.len);
    try std.testing.expectEqual(@as(?[]const u8, null), list[0].condition);
    try std.testing.expectEqualStrings("a.inc", list[0].path);
    try std.testing.expectEqualStrings("[include]", list[0].header);
    try std.testing.expectEqualStrings("~/b.inc", list[1].path);
    try std.testing.expectEqualStrings("gitdir:~/work/", list[2].condition.?);
    try std.testing.expectEqualStrings("c.inc", list[2].path);
    try std.testing.expectEqualStrings("onbranch:feat/\"x\"", list[3].condition.?);
    try std.testing.expect(std.mem.startsWith(u8, text[list[0].end..], "    path = \"~/b.inc\""));
    try std.testing.expect(std.mem.startsWith(u8, text[list[3].end..], "[includeIf]"));

    var urls: std.ArrayList([]const u8) = .empty;
    try remoteUrls(c, arena, &urls);
    try std.testing.expectEqual(@as(usize, 2), urls.items.len);
    try std.testing.expectEqualStrings("git@example.com:r.git", urls.items[1]);
}
