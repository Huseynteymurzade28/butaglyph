//! .gitignore rules, as git applies them (gitignore(5)).
//!
//! * A line is a pattern; `#` starts a comment, trailing spaces are dropped
//!   unless escaped, `!` negates, a trailing `/` matches directories only.
//! * A pattern without a `/` (other than a trailing one) matches the base
//!   name at any depth. Otherwise it is matched against the path relative
//!   to the directory of the file that holds it.
//! * Wildcards follow git's wildmatch: `*`, `?`, `[...]` (with `!`/`^`,
//!   ranges and `[:class:]`), `\` escapes, and `**` as a whole path
//!   component.
//! * Precedence: the deepest .gitignore first, then its parents up to the
//!   work tree root, then `$GIT_DIR/info/exclude`, then `core.excludesFile`.
//!   Within one file the last matching pattern wins.
//!
//! "A file can't be re-included if a parent directory is excluded" is the
//! caller's job: it never descends into an ignored directory.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Pattern = struct {
    /// Without the leading `!`, a leading `/` or the trailing `/`.
    text: []const u8,
    negative: bool,
    /// Had a trailing `/`: matches directories only.
    dir_only: bool,
    /// Had no `/`: matched against the base name at any depth.
    basename: bool,
};

pub const List = struct {
    /// Directory of the file that holds the patterns, relative to the work
    /// tree root, with a trailing `/` ("" for the root and for the
    /// repository-wide files).
    base: []const u8,
    patterns: []const Pattern,

    /// Parses an ignore file. Pattern text points into `text`, which must
    /// outlive the list.
    pub fn parse(arena: Allocator, base: []const u8, text: []const u8) Allocator.Error!List {
        var data = text;
        if (std.mem.startsWith(u8, data, "\xEF\xBB\xBF")) data = data[3..];
        var patterns: std.ArrayList(Pattern) = .empty;
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |raw| {
            var line = if (std.mem.endsWith(u8, raw, "\r")) raw[0 .. raw.len - 1] else raw;
            if (line.len == 0 or line[0] == '#') continue;
            line = trimTrailingSpaces(line);
            if (line.len == 0) continue;
            try patterns.append(arena, parsePattern(line));
        }
        return .{ .base = base, .patterns = patterns.items };
    }

    /// The last pattern matching `path` (relative to the work tree), or null.
    pub fn lastMatch(l: *const List, path: []const u8, is_dir: bool, ignore_case: bool) ?*const Pattern {
        const name = path[if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| i + 1 else 0..];
        var i = l.patterns.len;
        while (i > 0) {
            i -= 1;
            const p = &l.patterns[i];
            if (p.dir_only and !is_dir) continue;
            const flags: Flags = .{ .pathname = !p.basename, .casefold = ignore_case };
            const subject = if (p.basename) name else blk: {
                // Patterns with a slash are relative to the file's directory.
                if (!startsWith(path, l.base, ignore_case)) continue;
                break :blk path[l.base.len..];
            };
            if (wildmatch(p.text, subject, flags)) return p;
        }
        return null;
    }
};

fn parsePattern(line: []const u8) Pattern {
    var p = line;
    const negative = p[0] == '!';
    if (negative) p = p[1..];
    const dir_only = p.len > 0 and p[p.len - 1] == '/';
    if (dir_only) p = p[0 .. p.len - 1];
    const basename = std.mem.indexOfScalar(u8, p, '/') == null;
    if (!basename and p[0] == '/') p = p[1..];
    return .{ .text = p, .negative = negative, .dir_only = dir_only, .basename = basename };
}

/// Drops trailing spaces that are not escaped with a backslash (git's
/// trim_trailing_spaces; tabs are kept).
fn trimTrailingSpaces(line: []const u8) []const u8 {
    var last_space: ?usize = null;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        switch (line[i]) {
            ' ' => last_space = last_space orelse i,
            '\\' => {
                last_space = null;
                i += 1; // the escaped character is kept, whatever it is
            },
            else => last_space = null,
        }
    }
    return line[0 .. last_space orelse line.len];
}

fn startsWith(s: []const u8, prefix: []const u8, ignore_case: bool) bool {
    if (s.len < prefix.len) return false;
    return if (ignore_case) std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix) else std.mem.eql(u8, s[0..prefix.len], prefix);
}

/// The rules in effect for one path: a stack of per-directory lists (root
/// first) plus the repository-wide ones.
pub const Stack = struct {
    /// Root first; the walker pushes and pops as it enters and leaves
    /// directories.
    dirs: std.ArrayList(List) = .empty,
    /// `$GIT_DIR/info/exclude`, then `core.excludesFile`.
    repo_wide: [2]?List = .{ null, null },
    ignore_case: bool = false,

    pub fn isIgnored(s: *const Stack, path: []const u8, is_dir: bool) bool {
        var i = s.dirs.items.len;
        while (i > 0) {
            i -= 1;
            if (s.dirs.items[i].lastMatch(path, is_dir, s.ignore_case)) |p| return !p.negative;
        }
        for (&s.repo_wide) |*l| if (l.*) |*list| {
            if (list.lastMatch(path, is_dir, s.ignore_case)) |p| return !p.negative;
        };
        return false;
    }
};

// ---------------------------------------------------------------- wildmatch

pub const Flags = struct {
    /// `*` and `?` don't match `/`; `**` does (as a whole component).
    pathname: bool = false,
    casefold: bool = false,
};

const Result = enum { match, no_match, abort_all, abort_to_starstar };

/// git's wildmatch(): does `pattern` match all of `text`?
pub fn wildmatch(pattern: []const u8, text: []const u8, flags: Flags) bool {
    return doWild(pattern, 0, text, 0, flags) == .match;
}

/// Byte at `i`, or 0 past the end (the C code walks NUL-terminated strings).
fn at(s: []const u8, i: usize) u8 {
    return if (i < s.len) s[i] else 0;
}

fn fold(c: u8, flags: Flags) u8 {
    return if (flags.casefold) std.ascii.toLower(c) else c;
}

fn isGlobSpecial(c: u8) bool {
    return switch (c) {
        '*', '?', '[', '\\' => true,
        else => false,
    };
}

fn doWild(pattern: []const u8, p_start: usize, text: []const u8, t_start: usize, flags: Flags) Result {
    var p = p_start;
    var t = t_start;
    while (p < pattern.len) : ({
        p += 1;
        t += 1;
    }) {
        var p_ch = pattern[p];
        var t_ch = at(text, t);
        if (t_ch == 0 and p_ch != '*') return .abort_all;
        t_ch = fold(t_ch, flags);
        p_ch = fold(p_ch, flags);
        switch (p_ch) {
            '?' => {
                if (flags.pathname and t_ch == '/') return .no_match;
                continue;
            },
            '*' => {
                var match_slash: bool = undefined;
                p += 1;
                if (at(pattern, p) == '*') {
                    const prev_is_start_or_slash = p < 2 or pattern[p - 2] == '/';
                    while (at(pattern, p) == '*') p += 1;
                    const next = at(pattern, p);
                    if (!flags.pathname) {
                        match_slash = true;
                    } else if (prev_is_start_or_slash and (next == 0 or next == '/' or (next == '\\' and at(pattern, p + 1) == '/'))) {
                        // `**/` may also match no directory at all: try the
                        // rest of the pattern right here first.
                        if (next == '/' and doWild(pattern, p + 1, text, t, flags) == .match) return .match;
                        match_slash = true;
                    } else {
                        match_slash = false; // `**` not alone in its component: same as `*`
                    }
                } else {
                    match_slash = !flags.pathname;
                }
                if (p >= pattern.len) {
                    // A trailing `**` matches everything; a trailing `*` only
                    // if no slash is left.
                    if (!match_slash and std.mem.indexOfScalarPos(u8, text, t, '/') != null) return .no_match;
                    return .match;
                }
                if (!match_slash and pattern[p] == '/') {
                    // `*/` matches up to the next slash.
                    const slash = std.mem.indexOfScalarPos(u8, text, t, '/') orelse return .no_match;
                    t = slash;
                    // The for loop's increments consume both slashes.
                    continue;
                }
                while (true) {
                    if (t_ch == 0) break;
                    // Skip ahead to the next occurrence of a literal that
                    // follows the star.
                    if (!isGlobSpecial(pattern[p])) {
                        const want = fold(pattern[p], flags);
                        while (t < text.len and (match_slash or text[t] != '/')) : (t += 1) {
                            if (fold(text[t], flags) == want) break;
                        }
                        t_ch = fold(at(text, t), flags);
                        if (t_ch != want) return if (match_slash) .abort_all else .abort_to_starstar;
                    }
                    const r = doWild(pattern, p, text, t, flags);
                    if (r != .no_match) {
                        if (!match_slash or r != .abort_to_starstar) return r;
                    } else if (!match_slash and t_ch == '/') {
                        return .abort_to_starstar;
                    }
                    t += 1;
                    t_ch = fold(at(text, t), flags);
                }
                return .abort_all;
            },
            '[' => {
                p += 1;
                p_ch = at(pattern, p);
                if (p_ch == '^') p_ch = '!';
                const negated = p_ch == '!';
                if (negated) {
                    p += 1;
                    p_ch = at(pattern, p);
                }
                var prev_ch: u8 = 0;
                var matched = false;
                while (true) {
                    if (p_ch == 0) return .abort_all;
                    if (p_ch == '\\') {
                        p += 1;
                        p_ch = at(pattern, p);
                        if (p_ch == 0) return .abort_all;
                        if (t_ch == p_ch) matched = true;
                    } else if (p_ch == '-' and prev_ch != 0 and at(pattern, p + 1) != 0 and at(pattern, p + 1) != ']') {
                        p += 1;
                        p_ch = at(pattern, p);
                        if (p_ch == '\\') {
                            p += 1;
                            p_ch = at(pattern, p);
                            if (p_ch == 0) return .abort_all;
                        }
                        if (t_ch <= p_ch and t_ch >= prev_ch) {
                            matched = true;
                        } else if (flags.casefold and std.ascii.isLower(t_ch)) {
                            const upper = std.ascii.toUpper(t_ch);
                            if (upper <= p_ch and upper >= prev_ch) matched = true;
                        }
                        p_ch = 0; // so that prev_ch becomes 0
                    } else if (p_ch == '[' and at(pattern, p + 1) == ':') {
                        const s = p + 2;
                        var e = s;
                        while (at(pattern, e) != 0 and at(pattern, e) != ']') e += 1;
                        if (at(pattern, e) == 0) return .abort_all;
                        if (e == s or pattern[e - 1] != ':') {
                            // No ":]": an ordinary '['.
                            p_ch = '[';
                            if (t_ch == p_ch) matched = true;
                        } else {
                            const class = pattern[s .. e - 1];
                            matched = matched or (charClass(class, t_ch, flags) orelse return .abort_all);
                            p = e;
                            p_ch = 0;
                        }
                    } else if (t_ch == p_ch) {
                        matched = true;
                    }
                    prev_ch = p_ch;
                    p += 1;
                    p_ch = fold(at(pattern, p), flags);
                    if (p_ch == ']') break;
                }
                if (matched == negated or (flags.pathname and t_ch == '/')) return .no_match;
                continue;
            },
            '\\' => {
                // Literal match with the next character.
                p += 1;
                if (fold(at(pattern, p), flags) != t_ch) return .no_match;
                continue;
            },
            else => {
                if (t_ch != p_ch) return .no_match;
                continue;
            },
        }
    }
    return if (t < text.len) .no_match else .match;
}

/// null for an unknown class name (malformed pattern).
fn charClass(name: []const u8, c: u8, flags: Flags) ?bool {
    const eql = std.mem.eql;
    if (eql(u8, name, "alnum")) return std.ascii.isAlphanumeric(c);
    if (eql(u8, name, "alpha")) return std.ascii.isAlphabetic(c);
    if (eql(u8, name, "blank")) return c == ' ' or c == '\t';
    if (eql(u8, name, "cntrl")) return std.ascii.isControl(c);
    if (eql(u8, name, "digit")) return std.ascii.isDigit(c);
    if (eql(u8, name, "graph")) return c > 0x20 and c < 0x7f;
    if (eql(u8, name, "lower")) return std.ascii.isLower(c) or (flags.casefold and std.ascii.isUpper(c));
    if (eql(u8, name, "print")) return c >= 0x20 and c < 0x7f;
    if (eql(u8, name, "punct")) return std.ascii.isPrint(c) and !std.ascii.isAlphanumeric(c) and c != ' ';
    if (eql(u8, name, "space")) return std.ascii.isWhitespace(c);
    if (eql(u8, name, "upper")) return std.ascii.isUpper(c) or (flags.casefold and std.ascii.isLower(c));
    if (eql(u8, name, "xdigit")) return std.ascii.isHex(c);
    return null;
}

// ---------------------------------------------------------------- tests

fn expectWild(expected: bool, pattern: []const u8, text: []const u8, pathname: bool) !void {
    const got = wildmatch(pattern, text, .{ .pathname = pathname });
    if (got != expected) {
        std.debug.print("wildmatch(\"{s}\", \"{s}\", pathname={}) = {}, expected {}\n", .{ pattern, text, pathname, got, expected });
        return error.TestUnexpectedResult;
    }
}

test "wildmatch: cases from git's t3070" {
    const cases = [_]struct { bool, []const u8, []const u8 }{
        // { matches with WM_PATHNAME (as for gitignore patterns with a slash), text, pattern }
        .{ true, "foo", "foo" },
        .{ false, "foo", "bar" },
        .{ true, "", "" },
        .{ true, "foo", "???" },
        .{ false, "foo", "??" },
        .{ true, "foo", "*" },
        .{ true, "foo", "f*" },
        .{ false, "foo", "*f" },
        .{ true, "foo", "*foo*" },
        .{ true, "foobar", "*ob*a*r*" },
        .{ true, "aaaaaaabababab", "*ab" },
        .{ true, "foo*", "foo\\*" },
        .{ false, "foobar", "foo\\*bar" },
        .{ true, "f\\oo", "f\\\\oo" },
        .{ true, "ball", "*[al]?" },
        .{ false, "ten", "[ten]" },
        .{ true, "ten", "**[!te]" },
        .{ false, "ten", "**[!ten]" },
        .{ true, "ten", "t[a-g]n" },
        .{ false, "ten", "t[!a-g]n" },
        .{ true, "ton", "t[!a-g]n" },
        .{ true, "ton", "t[^a-g]n" },
        .{ true, "a]b", "a[]]b" },
        .{ true, "a-b", "a[]-]b" },
        .{ true, "a]b", "a[]-]b" },
        .{ false, "aab", "a[]-]b" },
        .{ true, "aab", "a[]a-]b" },
        .{ true, "]", "]" },
        // Extended slash-matching features
        .{ false, "foo/baz/bar", "foo*bar" },
        .{ false, "foo/baz/bar", "foo**bar" },
        .{ true, "foobazbar", "foo**bar" },
        .{ true, "foo/baz/bar", "foo/**/bar" },
        .{ true, "foo/baz/bar", "foo/**/**/bar" },
        .{ true, "foo/b/a/z/bar", "foo/**/bar" },
        .{ true, "foo/b/a/z/bar", "foo/**/**/bar" },
        .{ true, "foo/bar", "foo/**/bar" },
        .{ true, "foo/bar", "foo/**/**/bar" },
        .{ false, "foo/bar", "foo?bar" },
        .{ false, "foo/bar", "foo[/]bar" },
        .{ false, "foo/bar", "foo[^a-z]bar" },
        .{ false, "foo/bar", "f[^eiu][^eiu][^eiu][^eiu][^eiu]r" },
        .{ true, "foo-bar", "f[^eiu][^eiu][^eiu][^eiu][^eiu]r" },
        .{ true, "foo", "**/foo" },
        .{ true, "XXX/foo", "**/foo" },
        .{ true, "bar/baz/foo", "**/foo" },
        .{ false, "bar/baz/foo", "*/foo" },
        .{ false, "foo/bar/baz", "**/bar*" },
        .{ true, "deep/foo/bar/baz", "**/bar/*" },
        .{ false, "deep/foo/bar/baz/", "**/bar/*" },
        .{ true, "deep/foo/bar/baz/", "**/bar/**" },
        .{ false, "deep/foo/bar", "**/bar/*" },
        .{ true, "deep/foo/bar/", "**/bar/**" },
        .{ false, "foo/bar/baz", "**/bar**" },
        .{ true, "foo/bar/baz/x", "*/bar/**" },
        .{ false, "deep/foo/bar/baz/x", "*/bar/**" },
        .{ true, "deep/foo/bar/baz/x", "**/bar/*/*" },
        // Various additional tests
        .{ false, "acrt", "a[c-c]st" },
        .{ true, "acrt", "a[c-c]rt" },
        .{ false, "]", "[!]-]" },
        .{ true, "a", "[!]-]" },
        .{ false, "", "\\" },
        .{ false, "\\", "\\" },
        .{ false, "XXX/\\", "*/\\" },
        .{ true, "XXX/\\", "*/\\\\" },
        .{ true, "foo", "foo" },
        .{ true, "@foo", "@foo" },
        .{ false, "foo", "@foo" },
        .{ true, "[ab]", "\\[ab]" },
        .{ true, "[ab]", "[[]ab]" },
        .{ true, "[ab]", "[[:]ab]" },
        .{ false, "[ab]", "[[::]ab]" },
        .{ true, "[ab]", "[[:digit]ab]" },
        .{ true, "[ab]", "[\\[:]ab]" },
        .{ true, "?a?b", "\\??\\?b" },
        .{ true, "abc", "\\a\\b\\c" },
        .{ true, "foo/bar/baz/to", "**/t[o]" },
        // Character class tests
        .{ true, "a1B", "[[:alpha:]][[:digit:]][[:upper:]]" },
        .{ false, "a", "[[:digit:][:upper:][:space:]]" },
        .{ true, "A", "[[:digit:][:upper:][:space:]]" },
        .{ true, "1", "[[:digit:][:upper:][:space:]]" },
        .{ true, " ", "[[:digit:][:upper:][:space:]]" },
        .{ false, ".", "[[:digit:][:upper:][:space:]]" },
        .{ true, ".", "[[:digit:][:punct:][:space:]]" },
        .{ true, "5", "[[:xdigit:]]" },
        .{ true, "f", "[[:xdigit:]]" },
        .{ true, "D", "[[:xdigit:]]" },
        .{ true, "_", "[[:alnum:][:alpha:][:blank:][:cntrl:][:digit:][:graph:][:lower:][:print:][:punct:][:space:][:upper:][:xdigit:]]" },
        .{ true, ".", "[^[:alnum:][:alpha:][:blank:][:cntrl:][:digit:][:lower:][:space:][:upper:][:xdigit:]]" },
        .{ true, "5", "[a-c[:digit:]x-z]" },
        .{ true, "b", "[a-c[:digit:]x-z]" },
        .{ true, "y", "[a-c[:digit:]x-z]" },
        .{ false, "q", "[a-c[:digit:]x-z]" },
        // Additional tests, including some malformed wildmatch patterns
        .{ true, "]", "[\\\\-^]" },
        .{ false, "[", "[\\\\-^]" },
        .{ true, "-", "[\\-_]" },
        .{ true, "]", "[\\]]" },
        .{ false, "\\]", "[\\]]" },
        .{ false, "\\", "[\\]]" },
        .{ false, "ab", "a[]b" },
        .{ false, "a[]b", "a[]b" },
        .{ false, "ab[", "ab[" },
        .{ false, "ab", "[!" },
        .{ false, "ab", "[-" },
        .{ true, "-", "[-]" },
        .{ false, "-", "[a-" },
        .{ false, "-", "[!a-" },
        .{ true, "-", "[--A]" },
        .{ true, "5", "[--A]" },
        .{ true, " ", "[ --]" },
        .{ true, "$", "[ --]" },
        .{ true, "-", "[ --]" },
        .{ false, "0", "[ --]" },
        .{ true, "-", "[---]" },
        .{ true, "-", "[------]" },
        .{ false, "j", "[a-e-n]" },
        .{ true, "-", "[a-e-n]" },
        .{ true, "a", "[!------]" },
        .{ false, "[", "[]-a]" },
        .{ true, "^", "[]-a]" },
        .{ false, "^", "[!]-a]" },
        .{ true, "[", "[!]-a]" },
        .{ true, "^", "[a^bc]" },
        .{ true, "-b]", "[a-]b]" },
        .{ false, "\\", "[\\]" },
        .{ true, "\\", "[\\\\]" },
        .{ false, "\\", "[!\\\\]" },
        .{ true, "G", "[A-\\\\]" },
        .{ false, "aaabbb", "b*a" },
        .{ false, "aabcaa", "*ba*" },
        .{ true, ",", "[,]" },
        .{ true, ",", "[\\\\,]" },
        .{ true, "\\", "[\\\\,]" },
        .{ true, "-", "[,-.]" },
        .{ false, "+", "[,-.]" },
        .{ false, "-.]", "[,-.]" },
        .{ true, "2", "[\\1-\\3]" },
        .{ true, "3", "[\\1-\\3]" },
        .{ false, "4", "[\\1-\\3]" },
        .{ true, "\\", "[[-\\]]" },
        .{ true, "[", "[[-\\]]" },
        .{ true, "]", "[[-\\]]" },
        .{ false, "-", "[[-\\]]" },
        // Test recursion
        .{ true, "-adobe-courier-bold-o-normal--12-120-75-75-m-70-iso8859-1", "-*-*-*-*-*-*-12-*-*-*-m-*-*-*" },
        .{ false, "-adobe-courier-bold-o-normal--12-120-75-75-X-70-iso8859-1", "-*-*-*-*-*-*-12-*-*-*-m-*-*-*" },
        .{ false, "-adobe-courier-bold-o-normal--12-120-75-75-/-70-iso8859-1", "-*-*-*-*-*-*-12-*-*-*-m-*-*-*" },
        .{ true, "XXX/adobe/courier/bold/o/normal//12/120/75/75/m/70/iso8859/1", "XXX/*/*/*/*/*/*/12/*/*/*/m/*/*/*" },
        .{ false, "XXX/adobe/courier/bold/o/normal//12/120/75/75/X/70/iso8859/1", "XXX/*/*/*/*/*/*/12/*/*/*/m/*/*/*" },
        .{ true, "abcd/abcdefg/abcdefghijk/abcdefghijklmnop.txt", "**/*a*b*g*n*t" },
        .{ false, "abcd/abcdefg/abcdefghijk/abcdefghijklmnop.txtz", "**/*a*b*g*n*t" },
        .{ false, "foo", "*/*/*" },
        .{ false, "foo/bar", "*/*/*" },
        .{ true, "foo/bba/arr", "*/*/*" },
        .{ false, "foo/bb/aa/rr", "*/*/*" },
        .{ true, "foo/bb/aa/rr", "**/**/**" },
        .{ true, "abcXdefXghi", "*X*i" },
        .{ false, "ab/cXd/efXg/hi", "*X*i" },
        .{ true, "ab/cXd/efXg/hi", "*/*X*/*/*i" },
        .{ true, "ab/cXd/efXg/hi", "**/*X*/**/*i" },
        // Extra pathmatch tests
        .{ false, "foo", "fo" },
        .{ true, "foo/bar", "foo/bar" },
        .{ true, "foo/bar", "foo/*" },
        .{ false, "foo/bba/arr", "foo/*" },
        .{ true, "foo/bba/arr", "foo/**" },
        .{ false, "foo/bba/arr", "foo*" },
        .{ false, "foo/bba/arr", "foo/*arr" },
        .{ false, "foo/bba/arr", "foo/**arr" },
        .{ false, "foo/bba/arr", "foo/*z" },
        .{ false, "foo/bba/arr", "foo/**z" },
        .{ false, "foo/bar", "foo?bar" },
        .{ false, "foo/bar", "foo[/]bar" },
        .{ false, "foo/bar", "foo[^a-z]bar" },
        .{ false, "ab/cXd/efXg/hi", "*Xg*i" },
    };
    var failed = false;
    for (cases) |c| expectWild(c[0], c[2], c[1], true) catch {
        failed = true;
    };
    if (failed) return error.TestUnexpectedResult;
    // Without WM_PATHNAME (base names), `*` also matches `/`.
    try expectWild(true, "foo*bar", "foo/baz/bar", false);
    try expectWild(true, "*/foo", "bar/baz/foo", false);
}

test "wildmatch: case folding" {
    try std.testing.expect(wildmatch("*.TXT", "notes.txt", .{ .casefold = true }));
    try std.testing.expect(!wildmatch("*.TXT", "notes.txt", .{}));
    try std.testing.expect(wildmatch("[A-C]x", "bx", .{ .casefold = true }));
    try std.testing.expect(wildmatch("[[:upper:]]", "a", .{ .casefold = true }));
}

test "parse: comments, negation, escapes, trailing spaces" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const l = try List.parse(arena.allocator(), "", "\xEF\xBB\xBF# comment\r\n" ++
        "\n" ++
        "*.log  \n" ++
        "!keep.log\n" ++
        "\\#hash\n" ++
        "\\!bang\n" ++
        "build/\n" ++
        "/root-only\n" ++
        "doc/*.txt\n" ++
        "space\\ \n" ++
        "   \n");
    const p = l.patterns;
    try std.testing.expectEqual(@as(usize, 8), p.len);
    try std.testing.expectEqualStrings("*.log", p[0].text);
    try std.testing.expect(p[1].negative and std.mem.eql(u8, p[1].text, "keep.log"));
    try std.testing.expectEqualStrings("\\#hash", p[2].text);
    try std.testing.expect(!p[3].negative);
    try std.testing.expect(p[4].dir_only and p[4].basename and std.mem.eql(u8, p[4].text, "build"));
    try std.testing.expect(!p[5].basename and std.mem.eql(u8, p[5].text, "root-only"));
    try std.testing.expect(!p[6].basename);
    try std.testing.expectEqualStrings("space\\ ", p[7].text);
}

test "Stack: precedence and anchoring" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s: Stack = .{};
    try s.dirs.append(a, try List.parse(a, "", "*.log\nbuild/\n/top.txt\ndoc/*.md\n"));
    try s.dirs.append(a, try List.parse(a, "sub/", "!important.log\nlocal\n/anchored\n"));
    s.repo_wide[0] = try List.parse(a, "", "*.tmp\n");
    s.repo_wide[1] = try List.parse(a, "", "!x.tmp\n*.bak\n");

    try std.testing.expect(s.isIgnored("a.log", false));
    try std.testing.expect(s.isIgnored("deep/er/a.log", false));
    try std.testing.expect(!s.isIgnored("sub/important.log", false)); // deeper file wins
    try std.testing.expect(s.isIgnored("build", true));
    try std.testing.expect(!s.isIgnored("build", false)); // directories only
    try std.testing.expect(s.isIgnored("top.txt", false));
    try std.testing.expect(!s.isIgnored("x/top.txt", false)); // anchored to the root
    try std.testing.expect(s.isIgnored("doc/a.md", false));
    try std.testing.expect(!s.isIgnored("x/doc/a.md", false));
    try std.testing.expect(s.isIgnored("sub/local", false));
    try std.testing.expect(s.isIgnored("sub/anchored", false));
    try std.testing.expect(!s.isIgnored("sub/x/anchored", false));
    try std.testing.expect(s.isIgnored("x.tmp", false)); // info/exclude beats core.excludesFile
    try std.testing.expect(s.isIgnored("y.bak", false));
    try std.testing.expect(!s.isIgnored("keep.txt", false));
}
