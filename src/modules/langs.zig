//! Language modules with nothing special about them: project files, a
//! tool, `--version`. See `lang.Simple`.

const lang = @import("lang.zig");

pub const ruby = lang.Simple(.{
    .id = .ruby,
    .color = "red",
    .files = &.{ "Gemfile", ".ruby-version", "Rakefile" },
    .extensions = &.{"gemspec"},
    .tool = "ruby",
});

pub const php = lang.Simple(.{
    .id = .php,
    .color = "magenta",
    .files = &.{ "composer.json", ".php-version" },
    .extensions = &.{"php"},
    .tool = "php",
});

pub const deno = lang.Simple(.{
    .id = .deno,
    .color = "green",
    .files = &.{ "deno.json", "deno.jsonc", "deno.lock" },
    .tool = "deno",
});

pub const bun = lang.Simple(.{
    .id = .bun,
    .color = "yellow",
    .files = &.{ "bun.lock", "bun.lockb", "bunfig.toml" },
    .tool = "bun",
});

pub const lua = lang.Simple(.{
    .id = .lua,
    .color = "blue",
    .files = &.{ ".lua-version", ".luarc.json", "stylua.toml", ".stylua.toml" },
    .extensions = &.{ "lua", "rockspec" },
    .tool = "lua",
    .version_args = &.{"-v"},
});

pub const haskell = lang.Simple(.{
    .id = .haskell,
    .color = "magenta",
    .files = &.{ "stack.yaml", "cabal.project", "package.yaml" },
    .extensions = &.{ "cabal", "hs" },
    .tool = "ghc",
    .version_args = &.{"--numeric-version"},
});
