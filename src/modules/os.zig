//! The operating system: the distribution's logo with the Nerd Font glyph
//! set (Arch, Debian, Fedora, NixOS, ...), its name otherwise. On Linux it
//! comes from os-release (`ID`, then `ID_LIKE`, so Arch-based systems get
//! the Arch logo). Not in the default order.

const std = @import("std");
const builtin = @import("builtin");
const module = @import("../module.zig");
const Context = @import("../context.zig").Context;
const Glyphs = @import("../glyphs.zig").Glyphs;
const render_mod = @import("../render.zig");
const Line = render_mod.Line;
const lang = @import("lang.zig");

pub const id: module.Id = .os;
pub const cost: module.Cost = .expensive;
pub const batch = true;

pub const Config = struct {
    style: render_mod.Style = .{ .fg = "blue", .bold = true },
    /// Replaces the logo (or, without logos, the name).
    symbol: ?[]const u8 = null,
    /// The name after the logo: "Arch Linux".
    show_name: bool = false,
    /// Overrides the global `timeout_ms` for this module.
    timeout_ms: ?u32 = null,
};

pub const Data = struct {
    /// Lowercase id: "arch", "ubuntu", "macos", "windows".
    id: []const u8,
    /// The logo's key in `logos` (the id or one it is like), if any.
    logo: ?[]const u8,
    name: []const u8,
};

pub fn compute(ctx: *const Context, _: *const Config, arena: std.mem.Allocator) !?Data {
    switch (builtin.os.tag) {
        .macos => return .{ .id = "macos", .logo = "macos", .name = "macOS" },
        .windows => return .{ .id = "windows", .logo = "windows", .name = "Windows" },
        else => {},
    }
    const release = lang.readSmall(ctx.io, arena, "/etc/os-release") orelse
        lang.readSmall(ctx.io, arena, "/usr/lib/os-release") orelse
        return .{ .id = @tagName(builtin.os.tag), .logo = logoFor(@tagName(builtin.os.tag)), .name = @tagName(builtin.os.tag) };
    return parse(release);
}

fn parse(release: []const u8) Data {
    const os_id = lang.iniValue(release, "ID") orelse "linux";
    var logo = logoFor(os_id);
    if (logo == null) if (lang.iniValue(release, "ID_LIKE")) |like| {
        var it = std.mem.tokenizeScalar(u8, like, ' ');
        while (it.next()) |l| if (logoFor(l)) |found| {
            logo = found;
            break;
        };
    };
    return .{
        .id = os_id,
        .logo = logo orelse "linux",
        .name = lang.iniValue(release, "NAME") orelse os_id,
    };
}

/// Nerd Font logos (nf-linux-*, nf-fa-*), by os-release ID.
const logos = std.StaticStringMap([]const u8).initComptime(.{
    .{ "almalinux", "\u{f31d}" },           .{ "alpine", "\u{f300}" },     .{ "arch", "\u{f303}" },
    .{ "artix", "\u{f31f}" },               .{ "centos", "\u{f304}" },     .{ "debian", "\u{f306}" },
    .{ "devuan", "\u{f307}" },              .{ "elementary", "\u{f309}" }, .{ "endeavouros", "\u{f322}" },
    .{ "fedora", "\u{f30a}" },              .{ "freebsd", "\u{f30c}" },    .{ "gentoo", "\u{f30d}" },
    .{ "guix", "\u{f325}" },                .{ "kali", "\u{f327}" },       .{ "linuxmint", "\u{f30e}" },
    .{ "mageia", "\u{f310}" },              .{ "manjaro", "\u{f312}" },    .{ "nixos", "\u{f313}" },
    .{ "openbsd", "\u{f328}" },             .{ "opensuse", "\u{f314}" },   .{ "opensuse-leap", "\u{f314}" },
    .{ "opensuse-tumbleweed", "\u{f314}" }, .{ "parrot", "\u{f329}" },     .{ "pop", "\u{f32a}" },
    .{ "raspbian", "\u{f315}" },            .{ "rhel", "\u{f316}" },       .{ "rocky", "\u{f32b}" },
    .{ "slackware", "\u{f318}" },           .{ "solus", "\u{f32d}" },      .{ "ubuntu", "\u{f31b}" },
    .{ "void", "\u{f32e}" },                .{ "zorin", "\u{f32f}" },      .{ "linux", "\u{f31a}" },
    .{ "macos", "\u{f179}" },               .{ "windows", "\u{f17a}" },
});

fn logoFor(os_id: []const u8) ?[]const u8 {
    return if (logos.has(os_id)) os_id else null;
}

pub fn render(data: *const Data, cfg: *const Config, g: *const Glyphs, line: *Line) Line.Error!void {
    if (cfg.symbol) |s| {
        if (cfg.show_name) return line.print(cfg.style, "{s} {s}", .{ s, data.name });
        return line.text(cfg.style, s);
    }
    const logo = if (g.logos) if (data.logo) |l| logos.get(l) else null else null;
    if (logo) |l| {
        if (cfg.show_name) return line.print(cfg.style, "{s} {s}", .{ l, data.name });
        return line.text(cfg.style, l);
    }
    try line.text(cfg.style, data.name);
}

test parse {
    const arch = parse("NAME=\"Arch Linux\"\nPRETTY_NAME=\"Arch Linux\"\nID=arch\nBUILD_ID=rolling\n");
    try std.testing.expectEqualStrings("arch", arch.id);
    try std.testing.expectEqualStrings("arch", arch.logo.?);
    try std.testing.expectEqualStrings("Arch Linux", arch.name);
    // An Arch-based system without a logo of its own gets Arch's.
    const cachy = parse("NAME=\"CachyOS Linux\"\nID=cachyos\nID_LIKE=arch\n");
    try std.testing.expectEqualStrings("arch", cachy.logo.?);
    try std.testing.expectEqualStrings("cachyos", cachy.id);
    const unknown = parse("NAME=Mystery\nID=mystery\n");
    try std.testing.expectEqualStrings("linux", unknown.logo.?);
}

test "os rendering" {
    const glyphs = @import("../glyphs.zig");
    const data: Data = .{ .id = "arch", .logo = "arch", .name = "Arch Linux" };
    var line: Line = .{};
    try render(&data, &.{}, glyphs.get(.nerd), &line);
    try render(&data, &.{ .show_name = true }, glyphs.get(.nerd), &line);
    try render(&data, &.{}, glyphs.get(.unicode), &line);
    try render(&data, &.{ .symbol = "A" }, glyphs.get(.nerd), &line);
    try std.testing.expectEqualStrings("\u{f303}", line.items()[0].text);
    try std.testing.expectEqualStrings("\u{f303} Arch Linux", line.items()[1].text);
    try std.testing.expectEqualStrings("Arch Linux", line.items()[2].text);
    try std.testing.expectEqualStrings("A", line.items()[3].text);
}
