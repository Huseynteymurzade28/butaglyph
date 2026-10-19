//! `buta config`: a configuration editor in the browser, in the spirit of
//! fish_config. It serves a single page (src/webconfig/index.html, embedded)
//! on 127.0.0.1 and a small JSON API:
//!
//!   GET  /api/state    the config file, defaults, schema, presets
//!   POST /api/preview  draw prompts with an edited config
//!   POST /api/zon      the ZON an edited config would be saved as
//!   POST /api/parse    ZON text back to the editor's JSON
//!   POST /api/save     write the config file
//!   POST /api/quit     stop the server
//!
//! The page edits the config as JSON; this side converts between JSON, the
//! `Config` type and ZON. The form is generated from a schema that is
//! derived from `Config` at compile time, so new modules and options show
//! up in the editor without changes here.
//!
//! Previews run the real `buta prompt` in a child process with the edited
//! config in a temporary file: what the page shows is exactly what the
//! shell will show, and the module tasks (which never free their memory,
//! see module.zig) live and die with the child, not with this server.
//!
//! The server only listens on 127.0.0.1. Every API call must carry a random
//! token, given in the URL's fragment when the page is opened, and the Host
//! header must name this server; other local users and other web pages
//! (cross-site requests, DNS rebinding) can't read or write the config.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const http = std.http;
const config = @import("config.zig");
const glyphs = @import("glyphs.zig");
const module = @import("module.zig");
const env_mod = @import("env.zig");
const presets = @import("presets");
const build_options = @import("build_options");

const page = @embedFile("webconfig/index.html");

pub const Options = struct {
    /// 0 picks a free port.
    port: u16 = 0,
    /// Open the page in the default browser.
    open: bool = true,
};

const State = struct {
    io: Io,
    env: env_mod.Env,
    /// The config file the editor loads and saves.
    path: []const u8,
    /// Where previews are drawn (the directory `buta config` ran in).
    cwd: []const u8,
    token: [32]u8,
    port: u16,
    /// Set once the original config has been kept as `.bak`.
    backed_up: std.atomic.Value(bool) = .init(false),
    previews: std.atomic.Value(u32) = .init(0),
};

pub fn main(io: Io, env: env_mod.Env, path: []const u8, cwd: []const u8, opts: Options, out: *Io.Writer, err: *Io.Writer) !u8 {
    const addr = Io.net.IpAddress.parse("127.0.0.1", opts.port) catch unreachable;
    // On POSIX this lets `--port` be reused right after a previous run. On
    // Windows SO_REUSEADDR would let another process take over the port.
    var server = addr.listen(io, .{ .reuse_address = builtin.os.tag != .windows }) catch |e| {
        try err.print("buta: cannot listen on 127.0.0.1:{d}: {s}\n", .{ opts.port, @errorName(e) });
        return 1;
    };
    defer server.deinit(io);

    var state: State = .{
        .io = io,
        .env = env,
        .path = path,
        .cwd = cwd,
        .token = undefined,
        .port = server.socket.address.getPort(),
    };
    var raw: [16]u8 = undefined;
    io.random(&raw);
    _ = std.fmt.bufPrint(&state.token, "{x}", .{&raw}) catch unreachable;

    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/#{s}", .{ state.port, &state.token });
    try out.print(
        \\buta config: {s}
        \\  editing {s}
        \\  previews are drawn in {s}
        \\  Ctrl-C (or "Done" on the page) stops the server.
        \\
    , .{ url, path, cwd });
    try out.flush();
    if (opts.open) openBrowser(io, url);

    var group: Io.Group = .init;
    defer group.cancel(io);
    while (true) {
        const stream = server.accept(io) catch |e| switch (e) {
            error.ConnectionAborted, error.WouldBlock => continue,
            else => {
                try err.print("buta: accept: {s}\n", .{@errorName(e)});
                return 1;
            },
        };
        // A browser may open a connection and send nothing on it for a
        // while (preconnect), so every connection gets its own task.
        group.concurrent(io, serve, .{ &state, stream }) catch {
            serve(&state, stream);
        };
    }
}

fn openBrowser(io: Io, url: []const u8) void {
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .windows => &.{ "rundll32", "url.dll,FileProtocolHandler", url },
        .macos => &.{ "open", url },
        else => &.{ "xdg-open", url },
    };
    _ = std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch {};
}

fn serve(state: *State, stream: Io.net.Stream) void {
    const io = state.io;
    defer stream.close(io);
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var in_buf: [16 * 1024]u8 = undefined;
    var out_buf: [16 * 1024]u8 = undefined;
    var reader = stream.reader(io, &in_buf);
    var writer = stream.writer(io, &out_buf);
    var server: http.Server = .init(&reader.interface, &writer.interface);
    var request = server.receiveHead() catch return;
    // A POST must say how long its body is; browsers always do. Anything
    // else is not answered.
    if (request.head.method == .POST and request.head.content_length == null and request.head.transfer_encoding == .none) return;
    const quit = handle(state, arena, &request) catch |e| blk: {
        respondJson(&request, .internal_server_error, arena, .{ .@"error" = @errorName(e) }) catch {};
        break :blk false;
    };
    if (quit) {
        // Let the answer reach the page before the process goes away.
        stream.shutdown(io, .send) catch {};
        io.sleep(.fromMilliseconds(100), .awake) catch {};
        std.process.exit(0);
    }
}

const Route = enum { state, preview, zon, parse, save, quit };

/// Returns true when the server should stop.
fn handle(state: *State, arena: Allocator, request: *http.Server.Request) !bool {
    if (!hostAllowed(state, request)) {
        try request.respond("", .{ .status = .forbidden, .keep_alive = false });
        return false;
    }
    const target = request.head.target;
    const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];

    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) {
        try request.respond(page, .{ .keep_alive = false, .extra_headers = &.{
            .{ .name = "content-type", .value = "text/html; charset=utf-8" },
            .{ .name = "cache-control", .value = "no-store" },
            .{ .name = "content-security-policy", .value = "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:" },
        } });
        return false;
    }
    const route = if (std.mem.startsWith(u8, path, "/api/")) std.meta.stringToEnum(Route, path["/api/".len..]) else null;
    if (route == null) {
        try request.respond("not found\n", .{ .status = .not_found, .keep_alive = false });
        return false;
    }
    if (!tokenValid(state, request)) {
        try respondJson(request, .forbidden, arena, .{ .@"error" = "bad token" });
        return false;
    }
    if (route != .state and request.head.method != .POST) {
        try respondJson(request, .method_not_allowed, arena, .{ .@"error" = "POST only" });
        return false;
    }

    const body = if (request.head.method == .POST) try readBody(arena, request) else "";
    switch (route.?) {
        .state => try respondState(state, arena, request),
        .preview => try respondPreview(state, arena, request, body),
        .zon => {
            const cfg = try configFromJson(arena, body);
            try respondJson(request, .ok, arena, .{ .zon = try toZon(arena, cfg) });
        },
        .parse => {
            const P = struct { zon: []const u8 };
            const p = try std.json.parseFromSliceLeaky(P, arena, body, .{ .ignore_unknown_fields = true });
            const loaded = config.parse(arena, try arena.dupeZ(u8, p.zon), "config.zon");
            if (loaded.problem) |msg| {
                try respondJson(request, .ok, arena, .{ .@"error" = msg });
            } else try respondJson(request, .ok, arena, .{ .config = loaded.config });
        },
        .save => try respondSave(state, arena, request, body),
        .quit => {
            try respondJson(request, .ok, arena, .{ .ok = true });
            return true;
        },
    }
    return false;
}

/// The Host header names this server: a page from elsewhere that resolves
/// its own name to 127.0.0.1 (DNS rebinding) is turned away.
fn hostAllowed(state: *const State, request: *const http.Server.Request) bool {
    var it = request.iterateHeaders();
    while (it.next()) |h| {
        if (!std.ascii.eqlIgnoreCase(h.name, "host")) continue;
        var buf: [64]u8 = undefined;
        for ([_][]const u8{ "127.0.0.1", "localhost" }) |name| {
            const want = std.fmt.bufPrint(&buf, "{s}:{d}", .{ name, state.port }) catch return false;
            if (std.ascii.eqlIgnoreCase(h.value, want)) return true;
        }
        return false;
    }
    return false;
}

fn tokenValid(state: *const State, request: *const http.Server.Request) bool {
    var it = request.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "x-buta-token")) {
            return h.value.len == state.token.len and std.crypto.timing_safe.eql([32]u8, h.value[0..32].*, state.token);
        }
    }
    return false;
}

fn readBody(arena: Allocator, request: *http.Server.Request) ![]u8 {
    if (request.head.content_length == 0) return "";
    var buf: [4096]u8 = undefined;
    const r = request.readerExpectNone(&buf);
    return r.allocRemaining(arena, .limited(1024 * 1024));
}

fn respondJson(request: *http.Server.Request, status: http.Status, arena: Allocator, value: anytype) !void {
    const json = try std.json.Stringify.valueAlloc(arena, value, .{});
    try request.respond(json, .{ .status = status, .keep_alive = false, .extra_headers = &.{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "cache-control", .value = "no-store" },
    } });
}

fn respondState(state: *State, arena: Allocator, request: *http.Server.Request) !void {
    const loaded = config.load(state.io, arena, state.path);
    var aw: Io.Writer.Allocating = .init(arena);
    var jw: std.json.Stringify = .{ .writer = &aw.writer };
    try jw.beginObject();
    try jw.objectField("version");
    try jw.write(build_options.version);
    try jw.objectField("path");
    try jw.write(state.path);
    try jw.objectField("cwd");
    try jw.write(state.cwd);
    try jw.objectField("problem");
    try jw.write(loaded.problem);
    try jw.objectField("config");
    try jw.write(loaded.config);
    try jw.objectField("defaults");
    try jw.write(config.Config{});
    try jw.objectField("schema");
    try writeSchema(config.Config, &jw);
    try jw.objectField("glyphs");
    try jw.beginObject();
    inline for (@typeInfo(glyphs.Set).@"enum".fields) |f| {
        try jw.objectField(f.name);
        try jw.write(glyphs.get(@enumFromInt(f.value)).*);
    }
    try jw.endObject();
    try jw.objectField("presets");
    try jw.beginArray();
    for (presets.all) |p| {
        const parsed = config.parse(arena, p.source, p.name);
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(p.name);
        try jw.objectField("description");
        try jw.write(p.description());
        try jw.objectField("config");
        try jw.write(parsed.config);
        try jw.endObject();
    }
    try jw.endArray();
    try jw.endObject();
    try request.respond(aw.written(), .{ .keep_alive = false, .extra_headers = &.{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "cache-control", .value = "no-store" },
    } });
}

/// Parses `body`, an object with a `config` in JSON form.
fn configFromJson(arena: Allocator, body: []const u8) !config.Config {
    const W = struct { config: config.Config = .{} };
    @setEvalBranchQuota(20000);
    const w = try std.json.parseFromSliceLeaky(W, arena, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    return w.config;
}

const Run = struct {
    status: i32 = 0,
    duration_ms: ?u64 = null,
    jobs: u32 = 0,
};

fn respondPreview(state: *State, arena: Allocator, request: *http.Server.Request, body: []const u8) !void {
    const P = struct {
        config: config.Config = .{},
        runs: []const Run = &.{.{}},
        cwd: ?[]const u8 = null,
    };
    @setEvalBranchQuota(20000);
    const p = try std.json.parseFromSliceLeaky(P, arena, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    const zon = try toZon(arena, p.config);

    // A file of its own per preview: previews may run concurrently.
    const n = state.previews.fetchAdd(1, .monotonic);
    const tmp = try std.fmt.allocPrint(arena, "{s}/buta-config-{s}-{d}.zon", .{ tempDir(state), state.token[0..8], n });
    const cwd_dir = Io.Dir.cwd();
    try cwd_dir.writeFile(state.io, .{ .sub_path = tmp, .data = zon });
    defer cwd_dir.deleteFile(state.io, tmp) catch {};

    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = exe_buf[0..try std.process.executablePath(state.io, &exe_buf)];
    var map = try state.env.environ.createMap(arena);
    try map.put("BUTA_CONFIG", tmp);
    const dir = if (p.cwd) |c| (if (c.len > 0) c else state.cwd) else state.cwd;

    var aw: Io.Writer.Allocating = .init(arena);
    var jw: std.json.Stringify = .{ .writer = &aw.writer };
    try jw.beginObject();
    try jw.objectField("runs");
    try jw.beginArray();
    for (p.runs) |run| {
        var status_buf: [16]u8 = undefined;
        var duration_buf: [24]u8 = undefined;
        var jobs_buf: [16]u8 = undefined;
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &.{ exe, "prompt", "--shell", "plain", "--cwd", dir });
        try argv.appendSlice(arena, &.{ "--status", try std.fmt.bufPrint(&status_buf, "{d}", .{run.status}) });
        try argv.appendSlice(arena, &.{ "--jobs", try std.fmt.bufPrint(&jobs_buf, "{d}", .{run.jobs}) });
        if (run.duration_ms) |d| try argv.appendSlice(arena, &.{ "--duration-ms", try std.fmt.bufPrint(&duration_buf, "{d}", .{d}) });
        const r = std.process.run(arena, state.io, .{
            .argv = argv.items,
            .environ_map = &map,
            .stdout_limit = .limited(256 * 1024),
            .stderr_limit = .limited(64 * 1024),
            .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } },
        }) catch |e| {
            try jw.write(.{ .prompt = "", .stderr = @errorName(e) });
            continue;
        };
        try jw.write(.{ .prompt = r.stdout, .stderr = r.stderr });
    }
    try jw.endArray();
    try jw.objectField("zon");
    try jw.write(zon);
    try jw.endObject();
    try request.respond(aw.written(), .{ .keep_alive = false, .extra_headers = &.{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "cache-control", .value = "no-store" },
    } });
}

/// $TMPDIR (or %TEMP%), else the config file's directory, which must be
/// writable anyway for saving.
fn tempDir(state: *const State) []const u8 {
    for ([_][]const u8{ "TMPDIR", "TEMP", "TMP" }) |name| {
        if (state.env.get(name)) |d| if (d.len > 0) return std.mem.trimEnd(u8, d, "/\\");
    }
    return std.fs.path.dirname(state.path) orelse ".";
}

fn respondSave(state: *State, arena: Allocator, request: *http.Server.Request, body: []const u8) !void {
    const cfg = try configFromJson(arena, body);
    const zon = try toZon(arena, cfg);
    // What is written must read back as the same config.
    const check = config.parse(arena, try arena.dupeZ(u8, zon), state.path);
    if (check.problem) |msg| return respondJson(request, .ok, arena, .{ .@"error" = msg });

    const io = state.io;
    const dir = Io.Dir.cwd();
    if (std.fs.path.dirname(state.path)) |d| try dir.createDirPath(io, d);
    var backup: ?[]const u8 = null;
    if (!state.backed_up.swap(true, .acq_rel)) {
        // The file as it was before this session, once.
        const bak = try std.fmt.allocPrint(arena, "{s}.bak", .{state.path});
        if (dir.copyFile(state.path, dir, bak, io, .{})) {
            backup = bak;
        } else |e| switch (e) {
            error.FileNotFound => {},
            else => return respondJson(request, .ok, arena, .{ .@"error" = try std.fmt.allocPrint(arena, "cannot back up {s}: {s}", .{ state.path, @errorName(e) }) }),
        }
    }
    const tmp = try std.fmt.allocPrint(arena, "{s}.tmp-{s}", .{ state.path, state.token[0..8] });
    try dir.writeFile(io, .{ .sub_path = tmp, .data = zon });
    dir.rename(tmp, dir, state.path, io) catch |e| {
        dir.deleteFile(io, tmp) catch {};
        return e;
    };
    try respondJson(request, .ok, arena, .{ .path = state.path, .backup = backup, .zon = zon });
}

// ---------------------------------------------------------------------------
// ZON output

/// The config as ZON, with only the fields that differ from their defaults.
pub fn toZon(arena: Allocator, cfg: config.Config) ![]u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.print("// Written by `buta config` (butaglyph {s}).\n", .{build_options.version});
    try writeZon(w, config.Config, cfg, 0);
    try w.writeByte('\n');
    return aw.written();
}

fn writeZon(w: *Io.Writer, comptime T: type, v: T, indent: usize) Io.Writer.Error!void {
    switch (@typeInfo(T)) {
        .bool => try w.writeAll(if (v) "true" else "false"),
        .int => try w.print("{d}", .{v}),
        .@"enum" => try w.print(".{f}", .{std.zig.fmtIdFlags(@tagName(v), .{ .allow_primitive = true })}),
        .optional => |o| if (v) |inner| try writeZon(w, o.child, inner, indent) else try w.writeAll("null"),
        .pointer => |p| {
            if (p.child == u8) return writeString(w, v);
            const multiline = @typeInfo(p.child) == .@"struct";
            try w.writeAll(".{");
            for (v, 0..) |item, i| {
                if (multiline) {
                    try w.writeByte('\n');
                    try w.splatByteAll(' ', (indent + 1) * 4);
                } else try w.writeAll(if (i == 0) " " else ", ");
                try writeZon(w, p.child, item, indent + 1);
                if (multiline) try w.writeByte(',');
            }
            if (multiline and v.len > 0) {
                try w.writeByte('\n');
                try w.splatByteAll(' ', indent * 4);
            } else if (v.len > 0) try w.writeByte(' ');
            try w.writeByte('}');
        },
        .@"struct" => |s| {
            var any = false;
            inline for (s.fields) |f| {
                const value = @field(v, f.name);
                const keep = if (f.defaultValue()) |d| !deepEql(f.type, value, d) else true;
                if (keep) {
                    if (!any) try w.writeAll(".{\n");
                    any = true;
                    try w.splatByteAll(' ', (indent + 1) * 4);
                    try w.print(".{f} = ", .{std.zig.fmtIdFlags(f.name, .{ .allow_primitive = true })});
                    try writeZon(w, f.type, value, indent + 1);
                    try w.writeAll(",\n");
                }
            }
            if (any) {
                try w.splatByteAll(' ', indent * 4);
                try w.writeByte('}');
            } else try w.writeAll(".{}");
        },
        else => @compileError("no ZON output for " ++ @typeName(T)),
    }
}

/// A ZON string: UTF-8 as is, except quotes, backslashes, control
/// characters and Private Use Area code points (Nerd Font glyphs, which
/// most editors can't show), which are escaped.
fn writeString(w: *Io.Writer, s: []const u8) Io.Writer.Error!void {
    try w.writeByte('"');
    var it = (std.unicode.Utf8View.init(s) catch return w.print("{f}\"", .{std.zig.fmtString(s)})).iterator();
    while (it.nextCodepointSlice()) |cs| {
        const c = std.unicode.utf8Decode(cs) catch unreachable;
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\t' => try w.writeAll("\\t"),
            0...8, 11...0x1f, 0x7f => try w.print("\\x{x:0>2}", .{c}),
            else => if (glyphs.hasPrivateUse(cs)) try w.print("\\u{{{x}}}", .{c}) else try w.writeAll(cs),
        }
    }
    try w.writeByte('"');
}

fn deepEql(comptime T: type, a: T, b: T) bool {
    switch (@typeInfo(T)) {
        .optional => |o| {
            if (a == null or b == null) return a == null and b == null;
            return deepEql(o.child, a.?, b.?);
        },
        .pointer => |p| {
            if (a.len != b.len) return false;
            for (a, b) |x, y| if (!deepEql(p.child, x, y)) return false;
            return true;
        },
        .@"struct" => |s| {
            inline for (s.fields) |f| if (!deepEql(f.type, @field(a, f.name), @field(b, f.name))) return false;
            return true;
        },
        else => return a == b,
    }
}

// ---------------------------------------------------------------------------
// Schema for the page

/// Describes `T` for the page's form generator:
/// `{"kind": "struct", "fields": [{"name": ..., "type": ...}, ...]}`, with
/// kinds bool, int, string, enum (with `values`), optional and list (with
/// `child`), and struct. A struct whose type is a `Style` is marked, so the
/// page can draw a color editor for it.
fn writeSchema(comptime T: type, jw: *std.json.Stringify) std.json.Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("kind");
    switch (@typeInfo(T)) {
        .bool => try jw.write("bool"),
        .int => {
            try jw.write("int");
            try jw.objectField("max");
            try jw.write(std.math.maxInt(T));
        },
        .@"enum" => |e| {
            try jw.write("enum");
            try jw.objectField("values");
            try jw.beginArray();
            inline for (e.fields) |f| try jw.write(f.name);
            try jw.endArray();
        },
        .optional => |o| {
            try jw.write("optional");
            try jw.objectField("child");
            try writeSchema(o.child, jw);
        },
        .pointer => |p| if (p.child == u8) try jw.write("string") else {
            try jw.write("list");
            try jw.objectField("child");
            try writeSchema(p.child, jw);
        },
        .@"struct" => |s| {
            try jw.write("struct");
            try jw.objectField("style");
            try jw.write(T == @import("render.zig").Style);
            try jw.objectField("fields");
            try jw.beginArray();
            inline for (s.fields) |f| {
                try jw.beginObject();
                try jw.objectField("name");
                try jw.write(f.name);
                try jw.objectField("required");
                try jw.write(f.defaultValue() == null);
                try jw.objectField("type");
                try writeSchema(f.type, jw);
                try jw.endObject();
            }
            try jw.endArray();
        },
        else => @compileError("no schema for " ++ @typeName(T)),
    }
    try jw.endObject();
}

test "toZon writes only what differs, and reads back the same" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectEqualStrings("// Written by `buta config` (butaglyph " ++ build_options.version ++ ").\n.{}\n", try toZon(a, .{}));

    for (presets.all) |p| {
        const original = config.parse(a, p.source, p.name).config;
        const zon = try toZon(a, original);
        const back = config.parse(a, try a.dupeZ(u8, zon), p.name);
        if (back.problem) |msg| {
            std.debug.print("{s}\n{s}\n", .{ msg, zon });
            return error.ZonDoesNotParse;
        }
        try std.testing.expect(deepEql(config.Config, original, back.config));
    }

    var cfg: config.Config = .{};
    cfg.dir.style = .{ .fg = "#ff0000" };
    cfg.segments = .{ .open = "\u{e0b6}", .join = null };
    cfg.order = &.{ .dir, .character };
    const zon = try toZon(a, cfg);
    // The style is written whole (`bold` differs from dir's default but not
    // from Style's), the Nerd Font glyph escaped.
    try std.testing.expect(std.mem.indexOf(u8, zon, ".style = .{\n            .fg = \"#ff0000\",\n        },") != null);
    try std.testing.expect(std.mem.indexOf(u8, zon, ".open = \"\\u{e0b6}\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, zon, ".join = null") != null);
    try std.testing.expect(std.mem.indexOf(u8, zon, ".order = .{ .dir, .character }") != null);
    const back = config.parse(a, try a.dupeZ(u8, zon), "t").config;
    try std.testing.expect(!back.dir.style.bold);
    try std.testing.expect(deepEql(config.Config, cfg, back));
}

test "JSON round trip of the config" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (presets.all) |p| {
        const original = config.parse(a, p.source, p.name).config;
        const json = try std.json.Stringify.valueAlloc(a, .{ .config = original }, .{});
        const back = try configFromJson(a, json);
        try std.testing.expect(deepEql(config.Config, original, back));
    }
}

test "the schema is valid JSON" {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer };
    try writeSchema(config.Config, &jw);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, aw.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("struct", parsed.value.object.get("kind").?.string);
}
