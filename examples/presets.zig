//! The presets in this directory, embedded in the binary for `buta preset`
//! and `buta preview`. Each file starts with `// name: description`.

pub const Preset = struct {
    name: []const u8,
    source: [:0]const u8,

    /// The first comment line, without `// name: `.
    pub fn description(p: Preset) []const u8 {
        const std = @import("std");
        const first = p.source[0 .. std.mem.indexOfScalar(u8, p.source, '\n') orelse p.source.len];
        const colon = std.mem.indexOf(u8, first, ": ") orelse return "";
        return first[colon + 2 ..];
    }
};

pub const all = [_]Preset{
    .{ .name = "carpet", .source = @embedFile("carpet.zon") },
    .{ .name = "neon", .source = @embedFile("neon.zon") },
    .{ .name = "acid", .source = @embedFile("acid.zon") },
    .{ .name = "pixel", .source = @embedFile("pixel.zon") },
    .{ .name = "aurora", .source = @embedFile("aurora.zon") },
    .{ .name = "bubbles", .source = @embedFile("bubbles.zon") },
    .{ .name = "glitch", .source = @embedFile("glitch.zon") },
    .{ .name = "inferno", .source = @embedFile("inferno.zon") },
    .{ .name = "hypnosis", .source = @embedFile("hypnosis.zon") },
    .{ .name = "vaporwave", .source = @embedFile("vaporwave.zon") },
    .{ .name = "matrix", .source = @embedFile("matrix.zon") },
    .{ .name = "static", .source = @embedFile("static.zon") },
    .{ .name = "circuit", .source = @embedFile("circuit.zon") },
    .{ .name = "tokyo-night", .source = @embedFile("tokyo-night.zon") },
    .{ .name = "two-line", .source = @embedFile("two-line.zon") },
    .{ .name = "minimal", .source = @embedFile("minimal.zon") },
    .{ .name = "ascii", .source = @embedFile("ascii.zon") },
};

pub fn find(name: []const u8) ?Preset {
    for (all) |p| if (@import("std").mem.eql(u8, p.name, name)) return p;
    return null;
}
