//! butaglyph's own git reader. No libgit2, no `git` subprocess.

pub const Oid = @import("oid.zig").Oid;
pub const repo = @import("repo.zig");
pub const refs = @import("refs.zig");
pub const object = @import("object.zig");
pub const odb = @import("odb.zig");
pub const delta = @import("delta.zig");
pub const index = @import("index.zig");
pub const config = @import("config.zig");
pub const status = @import("status.zig");
pub const ignore = @import("ignore.zig");
pub const untracked = @import("untracked.zig");

pub const Repo = repo.Repo;
pub const Status = status.Status;

test {
    @import("std").testing.refAllDecls(@This());
}
