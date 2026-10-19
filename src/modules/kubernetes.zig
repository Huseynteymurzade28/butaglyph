//! The current Kubernetes context and its namespace, read from the
//! kubeconfig files ($KUBECONFIG, else ~/.kube/config) without running
//! kubectl. Not in the default order.
//!
//! As kubectl merges them, `current-context` comes from the first file
//! that sets it, and a context from the first file that defines it. Only
//! the block-style YAML that kubectl writes is understood; a file it can't
//! read is skipped.

const std = @import("std");
const module = @import("../module.zig");
const Context = @import("../context.zig").Context;
const env = @import("../env.zig");
const Glyphs = @import("../glyphs.zig").Glyphs;
const render_mod = @import("../render.zig");
const Line = render_mod.Line;
const lang = @import("lang.zig");

pub const id: module.Id = .kubernetes;
pub const cost: module.Cost = .expensive;
pub const batch = true;

pub const Config = struct {
    style: render_mod.Style = .{ .fg = "cyan", .bold = true },
    symbol: ?[]const u8 = null,
    /// The context's namespace, in parentheses, when it sets one.
    show_namespace: bool = true,
    /// Overrides the global `timeout_ms` for this module.
    timeout_ms: ?u32 = null,
};

pub const Data = struct {
    context: []const u8,
    namespace: ?[]const u8,
};

pub fn compute(ctx: *const Context, cfg: *const Config, arena: std.mem.Allocator) !?Data {
    var files: std.ArrayList([]const u8) = .empty;
    if (ctx.getEnv("KUBECONFIG")) |list| {
        var it = std.mem.tokenizeScalar(u8, list, if (env.is_windows) ';' else ':');
        while (it.next()) |p| {
            if (lang.readSmall(ctx.io, arena, env.toSlashes(try arena.dupe(u8, p)))) |c| try files.append(arena, c);
        }
    } else {
        const p = try std.fmt.allocPrint(arena, "{s}/.kube/config", .{ctx.home orelse return null});
        if (lang.readSmall(ctx.io, arena, p)) |c| try files.append(arena, c);
    }

    const current = for (files.items) |f| {
        if (topScalar(f, "current-context")) |c| if (c.len > 0) break c;
    } else return null;
    var namespace: ?[]const u8 = null;
    if (cfg.show_namespace) for (files.items) |f| {
        if (findContext(f, current)) |entry| {
            namespace = entry.namespace;
            break;
        }
    };
    return .{ .context = current, .namespace = namespace };
}

/// `key: value` at the top level.
fn topScalar(yaml: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, yaml, '\n');
    while (lines.next()) |line| {
        if (keyValue(line, key)) |v| return v;
    }
    return null;
}

/// The value of `key: value` on this line (unindented), unquoted.
fn keyValue(line: []const u8, key: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, key) or line.len <= key.len or line[key.len] != ':') return null;
    return unquote(line[key.len + 1 ..]);
}

fn unquote(raw: []const u8) []const u8 {
    const v = std.mem.trim(u8, raw, " \t\r");
    if (v.len >= 2 and (v[0] == '"' or v[0] == '\'') and v[v.len - 1] == v[0]) return v[1 .. v.len - 1];
    return v;
}

const Entry = struct { namespace: ?[]const u8 };

/// The entry called `name` in the top-level `contexts:` list:
///
///     contexts:
///     - context:
///         cluster: c
///         namespace: ns
///       name: prod
fn findContext(yaml: []const u8, name: []const u8) ?Entry {
    const start = std.mem.indexOf(u8, yaml, "\ncontexts:") orelse
        (if (std.mem.startsWith(u8, yaml, "contexts:")) @as(usize, 0) else return null);
    var lines = std.mem.splitScalar(u8, yaml[start..], '\n');
    if (start > 0) _ = lines.next(); // the empty piece before `\n`
    _ = lines.next(); // `contexts:`

    var item_indent: ?usize = null;
    var item_name: ?[]const u8 = null;
    var item_ns: ?[]const u8 = null;
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        const trimmed = std.mem.trimStart(u8, line, " ");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const indent = line.len - trimmed.len;
        if (indent == 0 and trimmed[0] != '-') break; // the next top-level key
        const new_item = trimmed[0] == '-' and (item_indent == null or indent == item_indent.?);
        if (new_item) {
            if (item_name != null and std.mem.eql(u8, item_name.?, name)) return .{ .namespace = item_ns };
            item_indent = indent;
            item_name = null;
            item_ns = null;
        }
        const body = if (new_item) std.mem.trimStart(u8, trimmed[1..], " ") else trimmed;
        const body_indent = if (new_item) indent + 2 else indent;
        // `name` belongs to the item itself, not to something nested in it.
        if (body_indent == item_indent.? + 2) if (keyValue(body, "name")) |n| {
            item_name = n;
        };
        if (keyValue(body, "namespace")) |ns| if (ns.len > 0) {
            item_ns = ns;
        };
    }
    if (item_name != null and std.mem.eql(u8, item_name.?, name)) return .{ .namespace = item_ns };
    return null;
}

pub fn render(data: *const Data, cfg: *const Config, g: *const Glyphs, line: *Line) Line.Error!void {
    try lang.draw(line, cfg.style, cfg.symbol orelse g.kubernetes, "", data.context, data.namespace);
}

const sample =
    \\apiVersion: v1
    \\clusters:
    \\- cluster:
    \\    server: https://example.com
    \\  name: prod-cluster
    \\contexts:
    \\- context:
    \\    cluster: prod-cluster
    \\    namespace: payments
    \\    user: admin
    \\  name: prod
    \\- name: "dev"
    \\  context:
    \\    cluster: dev-cluster
    \\    user: me
    \\current-context: prod
    \\kind: Config
    \\users:
    \\- name: admin
    \\  user:
    \\    namespace: not-a-context
    \\
;

test topScalar {
    try std.testing.expectEqualStrings("prod", topScalar(sample, "current-context").?);
    try std.testing.expectEqualStrings("v1", topScalar(sample, "apiVersion").?);
    try std.testing.expectEqual(@as(?[]const u8, null), topScalar(sample, "current"));
    try std.testing.expectEqualStrings("a b", topScalar("current-context: 'a b'\n", "current-context").?);
}

test findContext {
    try std.testing.expectEqualStrings("payments", findContext(sample, "prod").?.namespace.?);
    try std.testing.expectEqual(@as(?[]const u8, null), findContext(sample, "dev").?.namespace);
    // Names of clusters and users are not contexts.
    try std.testing.expectEqual(@as(?Entry, null), findContext(sample, "prod-cluster"));
    try std.testing.expectEqual(@as(?Entry, null), findContext(sample, "admin"));
    try std.testing.expectEqual(@as(?Entry, null), findContext("contexts: []\n", "prod"));
    // Indented lists, as other tools write them.
    const indented = "contexts:\n  - context:\n      namespace: ns\n    name: x\n";
    try std.testing.expectEqualStrings("ns", findContext(indented, "x").?.namespace.?);
}

test "kubernetes rendering" {
    const g = @import("../glyphs.zig").get(.ascii);
    var line: Line = .{};
    try render(&.{ .context = "prod", .namespace = "payments" }, &.{}, g, &line);
    try render(&.{ .context = "dev", .namespace = null }, &.{}, g, &line);
    try std.testing.expectEqualStrings("k8s prod (payments)", line.items()[0].text);
    try std.testing.expectEqualStrings("k8s dev", line.items()[1].text);
}
