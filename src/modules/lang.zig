//! What the language modules (python, node, rust, go, zig) share: finding
//! the project, finding a tool on $PATH, and learning its version.
//!
//! A version is read from a file when the toolchain leaves one around
//! (pyvenv.cfg, Go's VERSION, see the modules). Otherwise the tool is run
//! once (`node --version`) and the answer is kept in the version cache,
//! one small file per binary in `$XDG_CACHE_HOME/butaglyph/versions`,
//! keyed by the binary's path, size, mtime and inode. Later prompts read
//! that file and run nothing. Binaries in a version manager's shim
//! directory (pyenv, rbenv, asdf, mise, volta) answer differently per
//! directory without changing on disk, so their answers are never cached.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Context = @import("../context.zig").Context;
const env = @import("../env.zig");
const render_mod = @import("../render.zig");
const module = @import("../module.zig");
const Glyphs = @import("../glyphs.zig").Glyphs;
const Line = render_mod.Line;

/// What a language module needs when nothing about it is special: its
/// project files, its tool and how to ask it for its version.
pub const Spec = struct {
    id: module.Id,
    /// The default color.
    color: []const u8,
    files: []const []const u8,
    extensions: []const []const u8 = &.{},
    tool: []const u8,
    version_args: []const []const u8 = &.{"--version"},
};

/// A language module from a `Spec`: shown in a project of its language,
/// with the tool's version (see `probe`).
pub fn Simple(comptime spec: Spec) type {
    return struct {
        pub const id: module.Id = spec.id;
        pub const cost: module.Cost = .expensive;
        pub const batch = true;

        pub const Config = struct {
            style: render_mod.Style = .{ .fg = spec.color, .bold = true },
            symbol: ?[]const u8 = null,
            version_prefix: []const u8 = "v",
            detect: Detect = .{ .files = spec.files, .extensions = spec.extensions },
            /// Overrides the global `timeout_ms` for this module.
            timeout_ms: ?u32 = null,
        };

        pub const Data = struct { version: ?[]const u8 };

        pub fn compute(ctx: *const Context, cfg: *const Config, arena: Allocator) !?Data {
            _ = try findProject(ctx, arena, cfg.detect) orelse return null;
            const exe = try which(ctx, arena, spec.tool) orelse return .{ .version = null };
            return .{ .version = try probe(ctx, arena, exe, spec.version_args) };
        }

        pub fn render(data: *const Data, cfg: *const Config, g: *const Glyphs, line: *Line) Line.Error!void {
            try draw(line, cfg.style, cfg.symbol orelse @field(g, @tagName(spec.id)), cfg.version_prefix, data.version, null);
        }
    };
}

/// Options every language module has, in its Config next to `style` and
/// `symbol`.
pub const Detect = struct {
    /// Files (or directories) that mark a project of this language.
    files: []const []const u8,
    /// File extensions (without the dot) that mark one too. Only the
    /// working directory itself is searched for these.
    extensions: []const []const u8 = &.{},
    /// Also look in parent directories, up to (not above) $HOME.
    search_parents: bool = true,
};

/// The directory that holds one of `d.files`: the working directory or,
/// with `search_parents`, the nearest parent. Files with one of
/// `d.extensions` count in the working directory. null outside a project.
pub fn findProject(ctx: *const Context, arena: Allocator, d: Detect) !?[]const u8 {
    const levels = dirListings(ctx);
    var dir: []const u8 = ctx.physical_cwd;
    var level: usize = 0;
    while (true) : (level += 1) {
        const listing: ?*const Listing = if (level < levels.len and std.mem.eql(u8, levels[level].dir, dir)) &levels[level] else null;
        for (d.files) |name| {
            if (contains(ctx.io, listing, dir, name)) return try arena.dupe(u8, dir);
        }
        if (level == 0 and d.extensions.len > 0 and hasExtension(ctx.io, listing, dir, d.extensions)) {
            return try arena.dupe(u8, dir);
        }
        if (!d.search_parents) return null;
        if (ctx.home) |h| if (env.startsWithPath(dir, h) and dir.len == h.len) return null;
        dir = parent(dir) orelse return null;
    }
}

/// A directory's entries, read once and shared by the language modules:
/// sixteen modules looking for their project files cost a few directory
/// reads instead of a few hundred `access` calls.
const Listing = struct {
    dir: []const u8,
    names: []const []const u8,
    /// More than `max_entries` entries: `names` is empty, and the file
    /// system is asked about each name instead.
    truncated: bool,
};

/// The listings of the working directory and its parents up to $HOME, read
/// on first use. The working directory is the same for every module of a
/// process; one that asks about another directory gets none.
var listings: []const Listing = &.{};
var listings_cwd: []const u8 = "";
var listing_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
/// 0: not read, 1: being read, 2: ready.
var listings_state: std.atomic.Value(u8) = .init(0);

fn dirListings(ctx: *const Context) []const Listing {
    if (listings_state.cmpxchgStrong(0, 1, .acquire, .acquire) == null) {
        readListings(ctx);
        listings_state.store(2, .release);
    } else {
        while (listings_state.load(.acquire) != 2) std.atomic.spinLoopHint();
    }
    return if (std.mem.eql(u8, listings_cwd, ctx.physical_cwd)) listings else &.{};
}

fn readListings(ctx: *const Context) void {
    // Lives until the process exits, like the module tasks that read it.
    const gpa = listing_arena.allocator();
    var all: std.ArrayList(Listing) = .empty;
    var dir: []const u8 = gpa.dupe(u8, ctx.physical_cwd) catch return;
    listings_cwd = dir;
    for (0..64) |_| {
        all.append(gpa, readListing(ctx.io, gpa, dir) orelse break) catch break;
        if (ctx.home) |h| if (env.startsWithPath(dir, h) and dir.len == h.len) break;
        dir = parent(dir) orelse break;
    }
    listings = all.items;
}

fn readListing(io: Io, gpa: Allocator, path: []const u8) ?Listing {
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch return null) |entry| {
        if (names.items.len == max_entries) return .{ .dir = path, .names = &.{}, .truncated = true };
        names.append(gpa, gpa.dupe(u8, entry.name) catch return null) catch return null;
    }
    return .{ .dir = path, .names = names.items, .truncated = false };
}

fn contains(io: Io, listing: ?*const Listing, dir: []const u8, name: []const u8) bool {
    if (listing) |l| if (!l.truncated) {
        for (l.names) |n| if (sameName(n, name)) return true;
        return false;
    };
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}/{s}", .{ trimSlash(dir), name }) catch return false;
    return exists(io, p);
}

/// Windows file names are case-insensitive.
fn sameName(a: []const u8, b: []const u8) bool {
    return if (env.is_windows) std.ascii.eqlIgnoreCase(a, b) else std.mem.eql(u8, a, b);
}

/// Whether `dir` holds a file ending in `.<ext>` for one of `exts`. Only
/// the first `max_entries` entries count: a huge directory costs no more
/// than a small one.
fn hasExtension(io: Io, listing: ?*const Listing, dir_path: []const u8, exts: []const []const u8) bool {
    if (listing) |l| if (!l.truncated) {
        for (l.names) |n| if (extensionIn(n, exts)) return true;
        return false;
    };
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var it = dir.iterate();
    var n: usize = 0;
    while (it.next(io) catch null) |entry| : (n += 1) {
        if (n == max_entries) return false;
        if (extensionIn(entry.name, exts)) return true;
    }
    return false;
}

fn extensionIn(name: []const u8, exts: []const []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    if (dot == 0) return false; // `.lua` is a hidden file, not a Lua file
    for (exts) |e| if (std.ascii.eqlIgnoreCase(name[dot + 1 ..], e)) return true;
    return false;
}

const max_entries = 1000;

fn exists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// `/a/b` -> `/a`, `/a` -> `/`, `/` -> null (also `C:/a` -> `C:/`).
pub fn parent(dir: []const u8) ?[]const u8 {
    const root = env.rootLen(dir);
    if (dir.len <= root) return null;
    const slash = std.mem.lastIndexOfScalar(u8, dir, '/') orelse return null;
    return dir[0..@max(slash, root)];
}

fn trimSlash(dir: []const u8) []const u8 {
    return if (dir.len > 0 and dir[dir.len - 1] == '/') dir[0 .. dir.len - 1] else dir;
}

/// The first executable called `name` (`name.exe` on Windows) in $PATH.
pub fn which(ctx: *const Context, arena: Allocator, name: []const u8) !?[]const u8 {
    const path = ctx.getEnv("PATH") orelse return null;
    const sep: u8 = if (env.is_windows) ';' else ':';
    const ext = if (env.is_windows) ".exe" else "";
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var it = std.mem.tokenizeScalar(u8, path, sep);
    while (it.next()) |raw_dir| {
        const p = std.fmt.bufPrint(&buf, "{s}/{s}{s}", .{ trimSlash(raw_dir), name, ext }) catch continue;
        if (!env.isAbsolute(env.toSlashes(p))) continue; // `.` or relative entries: never
        // Windows' `python.exe` there opens the Microsoft Store.
        if (env.is_windows and std.mem.indexOf(u8, p, "/WindowsApps/") != null) continue;
        if (isExecutable(ctx.io, p)) return try arena.dupe(u8, p);
    }
    return null;
}

fn isExecutable(io: Io, path: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    if (st.kind != .file) return false;
    if (Io.File.Permissions.has_executable_bit) return st.permissions.toMode() & 0o111 != 0;
    return true;
}

/// Runs `exe args...` and returns the version it prints, from the version
/// cache when the binary has not changed since it was last asked.
///
/// On a cache miss the tool is run by a helper process (`buta
/// __probe-version`) that writes the cache, and this prompt waits for the
/// answer as long as the module's deadline allows. The helper outlives the
/// prompt, so a tool slower than the deadline is still asked only once: the
/// next prompt finds its answer. A `.pending` file next to the entry keeps
/// prompts from starting a second helper for the same binary. Tools that
/// can't be cached (shims) run here, every time.
pub fn probe(ctx: *const Context, arena: Allocator, exe: []const u8, args: []const []const u8) !?[]const u8 {
    const st = try Io.Dir.cwd().statFile(ctx.io, exe, .{});
    const key = try std.fmt.allocPrint(arena, "{s}\t{d}\t{d}\t{d}", .{ exe, st.size, st.mtime.nanoseconds, st.inode });
    const cacheable = !isShim(exe);
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = if (cacheable) cacheDir(ctx, &dir_buf) else null;
    if (dir) |d| {
        if (readCache(ctx.io, arena, d, key)) |v| return v;
        if (startHelper(ctx, arena, d, key, exe, args)) return awaitHelper(ctx.io, arena, d, key);
    }
    const version = try runTool(ctx.io, arena, ctx.physical_cwd, exe, args, probe_timeout_ms) orelse return null;
    if (dir) |d| writeCache(ctx.io, arena, d, key, version);
    return version;
}

fn runTool(io: Io, arena: Allocator, cwd: []const u8, exe: []const u8, args: []const []const u8, timeout_ms: u32) !?[]const u8 {
    const argv = try arena.alloc([]const u8, args.len + 1);
    argv[0] = exe;
    @memcpy(argv[1..], args);
    const r = try std.process.run(arena, io, .{
        .argv = argv,
        // Shims and version managers decide by the directory they run in.
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake } },
    });
    if (r.term != .exited or r.term.exited != 0) return error.ToolFailed;
    // Python 2 prints its version on stderr.
    return parseVersion(r.stdout) orelse parseVersion(r.stderr);
}

/// Starts the helper unless one is already asking this binary. Returns
/// whether a helper is (now) at work.
fn startHelper(ctx: *const Context, arena: Allocator, dir: []const u8, key: []const u8, exe: []const u8, args: []const []const u8) bool {
    const io = ctx.io;
    const cwd = Io.Dir.cwd();
    cwd.createDirPath(io, dir) catch return false;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const pending = pendingPath(&buf, dir, key) orelse return false;
    const file = cwd.createFile(io, pending, .{ .exclusive = true }) catch |e| switch (e) {
        error.PathAlreadyExists => {
            // A helper is at work, unless it died long ago.
            const st = cwd.statFile(io, pending, .{}) catch return false;
            const age_ns = Io.Clock.real.now(io).nanoseconds - st.mtime.nanoseconds;
            if (age_ns < helper_timeout_ms * std.time.ns_per_ms + std.time.ns_per_s) return true;
            cwd.deleteFile(io, pending) catch {};
            return false; // the next prompt starts a new one
        },
        else => return false,
    };
    file.close(io);

    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.process.executablePath(io, &exe_buf) catch return giveUp(io, pending);
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(arena, &.{ exe_buf[0..n], "__probe-version", dir, key, ctx.physical_cwd, exe }) catch return giveUp(io, pending);
    argv.appendSlice(arena, args) catch return giveUp(io, pending);
    _ = std.process.spawn(io, .{
        .argv = argv.items,
        .cwd = .{ .path = ctx.physical_cwd },
        // Never hold the shell's command substitution open.
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return giveUp(io, pending);
    // Not waited for: it runs on after this prompt is printed.
    return true;
}

fn giveUp(io: Io, pending: []const u8) bool {
    Io.Dir.cwd().deleteFile(io, pending) catch {};
    return false;
}

/// Waits for the helper's answer. The module's deadline cuts this short;
/// then the answer is for the next prompt.
fn awaitHelper(io: Io, arena: Allocator, dir: []const u8, key: []const u8) ?[]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const pending = pendingPath(&buf, dir, key) orelse return null;
    const start = Io.Clock.awake.now(io);
    while (start.durationTo(Io.Clock.awake.now(io)).toMilliseconds() < probe_timeout_ms) {
        io.sleep(.fromMilliseconds(3), .awake) catch return null;
        if (readCache(io, arena, dir, key)) |v| return v;
        // Done without an answer (the tool failed or printed no version).
        Io.Dir.cwd().access(io, pending, .{}) catch return readCache(io, arena, dir, key);
    }
    return null;
}

fn pendingPath(buf: []u8, dir: []const u8, key: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{x:0>16}.pending", .{ dir, std.hash.Wyhash.hash(0, key) }) catch null;
}

/// `buta __probe-version <cache dir> <key> <cwd> <exe> [args...]`: runs
/// the tool, writes its version to the cache and removes the `.pending`
/// file. Started by `probe`; not meant to be run by hand.
pub fn probeMain(io: Io, args: []const []const u8) u8 {
    if (args.len < 4) return 2;
    const dir, const key, const cwd, const exe = .{ args[0], args[1], args[2], args[3] };
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    defer if (pendingPath(&buf, dir, key)) |p| Io.Dir.cwd().deleteFile(io, p) catch {};
    const version = (runTool(io, arena, cwd, exe, args[4..], helper_timeout_ms) catch return 1) orelse return 1;
    writeCache(io, arena, dir, key, version);
    return 0;
}

/// How long a prompt waits for the helper (the module's deadline usually
/// ends the wait sooner), and how long the helper waits for the tool.
const probe_timeout_ms = 2000;
const helper_timeout_ms = 30_000;

/// A shim's answer depends on where it runs, not on the shim itself.
fn isShim(exe: []const u8) bool {
    return std.mem.indexOf(u8, exe, "/shims/") != null or std.mem.indexOf(u8, exe, "/.volta/") != null;
}

/// `$XDG_CACHE_HOME/butaglyph/versions`, else `~/.cache/...`; on Windows
/// `%LOCALAPPDATA%/butaglyph/versions`.
pub fn cacheDir(ctx: *const Context, buf: []u8) ?[]const u8 {
    if (env.is_windows) {
        var tmp: [std.fs.max_path_bytes]u8 = undefined;
        const local = env.toSlashesCopy(&tmp, ctx.getEnv("LOCALAPPDATA") orelse return null) orelse return null;
        if (!env.isAbsolute(local)) return null;
        return std.fmt.bufPrint(buf, "{s}/butaglyph/versions", .{trimSlash(local)}) catch null;
    }
    if (ctx.getEnv("XDG_CACHE_HOME")) |x| if (env.isAbsolute(x)) {
        return std.fmt.bufPrint(buf, "{s}/butaglyph/versions", .{trimSlash(x)}) catch null;
    };
    const h = ctx.home orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.cache/butaglyph/versions", .{h}) catch null;
}

/// Each entry is `<key>\n<version>\n` in a file named after the key's hash.
fn entryPath(buf: []u8, dir: []const u8, key: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{x:0>16}", .{ dir, std.hash.Wyhash.hash(0, key) }) catch null;
}

fn readCache(io: Io, arena: Allocator, dir: []const u8, key: []const u8) ?[]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = entryPath(&buf, dir, key) orelse return null;
    var data: [std.fs.max_path_bytes + 256]u8 = undefined;
    const content = Io.Dir.cwd().readFile(io, p, &data) catch return null;
    var lines = std.mem.splitScalar(u8, content, '\n');
    // A hash collision, or an entry for an older binary at the same path.
    if (!std.mem.eql(u8, lines.first(), key)) return null;
    const v = lines.next() orelse return null;
    if (v.len == 0) return null;
    return arena.dupe(u8, v) catch null;
}

/// Best effort: a cache that cannot be written only costs a run next time.
/// Written to a temporary name and renamed, so a reader never sees half an
/// entry.
fn writeCache(io: Io, arena: Allocator, dir: []const u8, key: []const u8, version: []const u8) void {
    const cwd = Io.Dir.cwd();
    cwd.createDirPath(io, dir) catch return;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = entryPath(&buf, dir, key) orelse return;
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    var nonce: [4]u8 = undefined;
    io.random(&nonce);
    const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.{x}", .{ p, std.mem.readInt(u32, &nonce, .little) }) catch return;
    const content = std.fmt.allocPrint(arena, "{s}\n{s}\n", .{ key, version }) catch return;
    cwd.writeFile(io, .{ .sub_path = tmp, .data = content }) catch return;
    cwd.rename(tmp, cwd, p, io) catch cwd.deleteFile(io, tmp) catch {};
}

/// The version in a tool's `--version` output: the first word that starts
/// with a digit, once a leading `v` or `go` is dropped. `v20.11.1`,
/// `Python 3.12.1`, `rustc 1.82.0 (f6e511eec 2024-10-15)`,
/// `go version go1.22.1 linux/amd64` and `0.16.0` all work.
pub fn parseVersion(out: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, out, " \t\r\n");
    while (it.next()) |raw| {
        // Java quotes it: openjdk version "21.0.2" 2024-01-16
        const word = std.mem.trim(u8, raw, "\"'");
        if (word.len == 0) continue;
        const w = if (std.mem.startsWith(u8, word, "go")) word[2..] else if (word[0] == 'v') word[1..] else word;
        if (w.len > 0 and std.ascii.isDigit(w[0])) return std.mem.trimEnd(u8, w, ",;");
    }
    return null;
}

/// The value of `key = value` (or `key: value`) in a simple config file:
/// pyvenv.cfg, rust-toolchain.toml. Quotes around the value are dropped.
pub fn iniValue(content: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, key)) continue;
        const rest = std.mem.trimStart(u8, line[key.len..], " \t");
        if (rest.len == 0 or (rest[0] != '=' and rest[0] != ':')) continue;
        return std.mem.trim(u8, rest[1..], " \t\"'");
    }
    return null;
}

/// Reads a small file whole; null if it is missing or unreadable.
pub fn readSmall(io: Io, arena: Allocator, path: []const u8) ?[]const u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024)) catch null;
}

/// `symbol`, `prefix` and `version`, then ` (extra)`. Without a version or
/// extra, the symbol's trailing space is dropped.
pub fn draw(line: *Line, style: render_mod.Style, symbol: []const u8, prefix: []const u8, version: ?[]const u8, extra: ?[]const u8) Line.Error!void {
    if (version == null and extra == null) return line.text(style, std.mem.trimEnd(u8, symbol, " "));
    var w: Io.Writer = .fixed(line.scratchBuffer());
    w.writeAll(symbol) catch return error.NoSpaceLeft;
    if (version) |v| w.print("{s}{s}", .{ prefix, v }) catch return error.NoSpaceLeft;
    if (extra) |e| w.print("{s}({s})", .{ if (version != null) " " else "", e }) catch return error.NoSpaceLeft;
    try line.commitScratch(style, w.end);
}

test parseVersion {
    const cases = [_][2][]const u8{
        .{ "v20.11.1\n", "20.11.1" },
        .{ "Python 3.12.1\n", "3.12.1" },
        .{ "rustc 1.82.0 (f6e511eec 2024-10-15)\n", "1.82.0" },
        .{ "go version go1.22.1 linux/amd64\n", "1.22.1" },
        .{ "0.16.0\n", "0.16.0" },
        .{ "0.15.0-dev.1+abc\r\n", "0.15.0-dev.1+abc" },
        .{ "openjdk version \"21.0.2\" 2024-01-16\n", "21.0.2" },
        .{ "ruby 3.3.0 (2023-12-25 revision 5124f9ac75) [x86_64-linux]\n", "3.3.0" },
        .{ "PHP 8.3.1 (cli) (built: Dec 20 2023)\n", "8.3.1" },
        .{ "deno 2.1.4 (stable, release, x86_64-unknown-linux-gnu)\n", "2.1.4" },
        .{ "Lua 5.4.6  Copyright (C) 1994-2023 Lua.org, PUC-Rio\n", "5.4.6" },
    };
    for (cases) |c| try std.testing.expectEqualStrings(c[1], parseVersion(c[0]).?);
    try std.testing.expectEqual(@as(?[]const u8, null), parseVersion("no version here"));
    try std.testing.expectEqual(@as(?[]const u8, null), parseVersion(""));
}

test iniValue {
    const cfg =
        \\home = /usr/bin
        \\include-system-site-packages = false
        \\version_info = 3.12.1.final.0
        \\version = 3.11.4
        \\prompt = 'myproj'
    ;
    try std.testing.expectEqualStrings("3.11.4", iniValue(cfg, "version").?);
    try std.testing.expectEqualStrings("3.12.1.final.0", iniValue(cfg, "version_info").?);
    try std.testing.expectEqualStrings("myproj", iniValue(cfg, "prompt").?);
    try std.testing.expectEqual(@as(?[]const u8, null), iniValue(cfg, "missing"));
    try std.testing.expectEqualStrings("1.85", iniValue("[toolchain]\nchannel = \"1.85\"\n", "channel").?);
}

test parent {
    try std.testing.expectEqualStrings("/a", parent("/a/b").?);
    try std.testing.expectEqualStrings("/", parent("/a").?);
    try std.testing.expectEqual(@as(?[]const u8, null), parent("/"));
}

test draw {
    var line: Line = .{};
    try draw(&line, .{}, "py ", "v", "3.12.1", ".venv");
    try draw(&line, .{}, "py ", "v", null, ".venv");
    try draw(&line, .{}, "py ", "v", null, null);
    try draw(&line, .{}, "rs ", "", "1.82.0", null);
    try std.testing.expectEqualStrings("py v3.12.1 (.venv)", line.items()[0].text);
    try std.testing.expectEqualStrings("py (.venv)", line.items()[1].text);
    try std.testing.expectEqualStrings("py", line.items()[2].text);
    try std.testing.expectEqualStrings("rs 1.82.0", line.items()[3].text);
}

test "the version cache keeps an answer per binary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    const d = try std.fmt.allocPrint(a, "{s}/versions", .{env.toSlashes(dir)});
    try std.testing.expectEqual(@as(?[]const u8, null), readCache(std.testing.io, a, d, "/bin/x\t1\t2\t3"));
    writeCache(std.testing.io, a, d, "/bin/x\t1\t2\t3", "1.2.3");
    try std.testing.expectEqualStrings("1.2.3", readCache(std.testing.io, a, d, "/bin/x\t1\t2\t3").?);
    // Same path, rebuilt binary: a different key, so a miss.
    try std.testing.expectEqual(@as(?[]const u8, null), readCache(std.testing.io, a, d, "/bin/x\t1\t9\t3"));
}

test isShim {
    try std.testing.expect(isShim("/home/u/.pyenv/shims/python"));
    try std.testing.expect(isShim("/home/u/.volta/bin/node"));
    try std.testing.expect(!isShim("/usr/bin/node"));
}

test hasExtension {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const dir = env.toSlashes(try tmp.dir.realPathFileAlloc(io, ".", arena.allocator()));
    try tmp.dir.writeFile(io, .{ .sub_path = ".lua", .data = "" });
    try std.testing.expect(!hasExtension(io, null, dir, &.{"lua"}));
    try tmp.dir.writeFile(io, .{ .sub_path = "App.CSPROJ", .data = "" });
    try std.testing.expect(hasExtension(io, null, dir, &.{ "sln", "csproj" }));
    try std.testing.expect(!hasExtension(io, null, dir, &.{"cabal"}));
    // The same answers from a listing.
    const l = readListing(io, arena.allocator(), dir).?;
    try std.testing.expect(hasExtension(io, &l, dir, &.{ "sln", "csproj" }));
    try std.testing.expect(!hasExtension(io, &l, dir, &.{"lua"}));
    try std.testing.expect(contains(io, &l, dir, "App.CSPROJ"));
    try std.testing.expect(!contains(io, &l, dir, "pom.xml"));
}
