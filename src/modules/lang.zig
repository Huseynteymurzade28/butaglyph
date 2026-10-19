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
const Line = render_mod.Line;

/// Options every language module has, in its Config next to `style` and
/// `symbol`.
pub const Detect = struct {
    /// Files (or directories) that mark a project of this language.
    files: []const []const u8,
    /// Also look in parent directories, up to (not above) $HOME.
    search_parents: bool = true,
};

/// The directory that holds one of `d.files`: the working directory or,
/// with `search_parents`, the nearest parent. null outside a project.
pub fn findProject(ctx: *const Context, arena: Allocator, d: Detect) !?[]const u8 {
    var dir: []const u8 = ctx.physical_cwd;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    while (true) {
        for (d.files) |name| {
            const p = std.fmt.bufPrint(&buf, "{s}/{s}", .{ trimSlash(dir), name }) catch continue;
            if (exists(ctx.io, p)) return try arena.dupe(u8, dir);
        }
        if (!d.search_parents) return null;
        if (ctx.home) |h| if (env.startsWithPath(dir, h) and dir.len == h.len) return null;
        dir = parent(dir) orelse return null;
    }
}

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
    while (it.next()) |word| {
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
