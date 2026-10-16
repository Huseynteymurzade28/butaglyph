# butaglyph

A fast, shell-agnostic prompt engine written in Zig, in the spirit of
Starship and Oh My Posh. The command is `buta`.

```
~/dev/butaglyph  master  2.3s  1
❯
```

## The name

*Buta* is the teardrop-shaped motif woven into Azerbaijani carpets, and a
national symbol of Azerbaijan. butaglyph weaves small glyphs into your prompt
line the way buta motifs are woven into a carpet.

## Install

Requires Zig 0.16.0. There are no other dependencies.

```sh
git clone <repo-url> butaglyph && cd butaglyph
zig build -Doptimize=ReleaseFast
install -Dm755 zig-out/bin/buta ~/.local/bin/buta
```

The default glyph set needs a [Nerd Font](https://www.nerdfonts.com). If you
don't have one, set `.glyphs = .ascii` (see below).

## Shell setup

| Shell | Add to                       | Line                         |
|-------|------------------------------|------------------------------|
| bash  | `~/.bashrc`                  | `eval "$(buta init bash)"`   |
| zsh   | `~/.zshrc`                   | `eval "$(buta init zsh)"`    |
| fish  | `~/.config/fish/config.fish` | `buta init fish \| source`   |

`buta init` prints a small hook script that records each command's exit
status and duration, then calls `buta prompt`. The script uses the absolute
path of the `buta` binary that generated it, so the hooks don't depend on
`$PATH`.

* **bash** uses `PROMPT_COMMAND` together with `PS0`. Command durations need
  bash ≥ 4.4, and millisecond precision needs bash ≥ 5.0 (`$EPOCHREALTIME`).
  Older versions still get every other module.
* **zsh** uses `preexec`/`precmd` and `$EPOCHREALTIME`. It also enables
  `prompt_subst`.
* **fish** uses `fish_postexec` and `$CMD_DURATION`, and defines `fish_prompt`.

You can also call `buta prompt` directly:

```sh
buta prompt --shell zsh --status 1 --duration-ms 5300 --jobs 2
```

## Configuration

buta reads its config from `$BUTA_CONFIG` if set, otherwise from
`$XDG_CONFIG_HOME/butaglyph/config.zon`, otherwise from
`~/.config/butaglyph/config.zon`. The file is
[ZON](https://ziglang.org/documentation/master/#ZON) and every field is
optional. If the file is missing, buta uses the defaults. If the file is
invalid, buta prints one located error on stderr (e.g.
`config.zon:3:15: error: ...`) and draws the default prompt, so a broken
config never costs you the prompt.

```zig
.{
    // .nerd (default, needs a Nerd Font) or .ascii
    .glyphs = .nerd,
    // Modules in display order; modules left out are never computed.
    .order = .{ .dir, .git_branch, .duration, .status, .jobs, .line_break, .character },
    .separator = " ",

    // Colors: "red", "bright_cyan", "208" (256-color), "#7aa2f7" (truecolor).
    // Style flags: bold, dim, italic, underline. Background: .bg.
    .dir = .{
        .style = .{ .fg = "#7aa2f7", .bold = true },
        .home_symbol = "~",
        .max_length = 24, // abbreviate once longer than this (0 = always)
        .abbrev_len = 1,  // ~/d/b/src: characters kept per directory
        .full_dirs = 2,   // trailing directories never abbreviated
    },
    .git_branch = .{ .style = .{ .fg = "magenta" }, .symbol = "on ", .max_length = 32 },
    .status = .{ .style = .{ .fg = "red", .bold = true }, .signal_names = true },
    .duration = .{ .style = .{ .fg = "yellow" }, .min_ms = 2000 },
    .jobs = .{ .style = .{ .fg = "blue" } },
    .character = .{ .success_symbol = "❯", .failure_symbol = "✗" },
}
```

### Modules

| Module       | Shows                                                         | Main options |
|--------------|---------------------------------------------------------------|--------------|
| `dir`        | Working directory, `$HOME` as `~`, fish-style abbreviation of long paths (UTF-8 aware) | `home_symbol`, `abbreviate`, `max_length`, `abbrev_len`, `full_dirs` |
| `git_branch` | Branch from `.git/HEAD`, or the short hash when HEAD is detached. Works in subdirectories, worktrees and submodules (`.git` files with `gitdir:`) | `symbol`, `detached_symbol`, `hash_length`, `max_length` |
| `status`     | The last exit code, if non-zero. `130` is shown as `INT`, and so on | `symbol`, `signal_names` |
| `duration`   | How long the last command ran, if longer than `min_ms`        | `symbol`, `min_ms` |
| `jobs`       | Number of background jobs. Not in the default order           | `symbol`, `min`, `count_from` |
| `character`  | The prompt symbol: green on success, red on failure           | `success_symbol`, `failure_symbol`, `*_style`, `suffix` |
| `line_break` | A newline, for multi-line prompts                             | none |

Every module except `line_break` has a `style` (or `success_style`/`failure_style`) and a
`symbol` override; leaving `symbol` unset uses the active glyph set.

Set `BUTA_DEBUG=1` to have modules report their errors on stderr.

## Design

* **The prompt never breaks.** If a module errors, it renders as empty and
  the rest of the prompt is drawn.
* **Computing and rendering are separate.** Each module's `compute`
  produces plain `Data` with no pointers into the process state. Its
  `render` is a pure function from `Data` to styled spans. Only
  `src/render.zig` knows about escape sequences.
* **Correct line editing.** Escape sequences are wrapped as zero-width
  (`\[ \]` in bash, `%{ %}` in zsh), so long input lines wrap correctly.
* **Paths can't inject commands.** Text from the filesystem (directory and
  branch names) is quoted for the target shell, so a directory named
  `$(rm -rf ~)` is displayed, never executed. Control characters are
  replaced. The test suite checks this against real bash, zsh and fish.
* **Minimal allocation.** Every allocation on the prompt path comes from one
  fixed buffer, and all of it is released together when the process exits.
  Output is written once, through a buffered writer.

```
src/
  main.zig           entry point, `init` and `prompt` commands
  cli.zig            argument parsing (lenient for `prompt`)
  context.zig        shared read-only input: cwd, env, status, duration, jobs
  module.zig         module interface, registry, compute/render drivers
  config.zig         ZON config loading
  glyphs.zig         Nerd Font and ASCII glyph sets
  render.zig         spans, ANSI, per-shell wrapping and quoting
  git/repo.zig       repository discovery and HEAD parsing
  modules/*.zig      one file per module
  shell/*.sh         init scripts (embedded with @embedFile)
tests/integration.zig  drives the real binary and real shells
bench/bench.zig        prompt latency benchmark
```

## Development

```sh
zig build test    # unit + integration tests (shell tests run for installed shells)
zig build bench   # 1000 × `buta prompt` in ReleaseFast: mean / p50 / p99
zig build bench -- 5000
```

On the development machine (Linux, x86-64), with the working directory
inside a git repository and a full config file, the mean was **≈0.33 ms**
and the p99 was **≈0.8 ms**, including fork/exec. The target is a mean
under 2 ms.

## Roadmap

* **Phase 0 (current).** The CLI, the modules listed above, ZON config, glyph
  sets and the bash/zsh/fish integration.
* **Phase 1: parallel modules with deadlines.** Modules run concurrently
  through `std.Io`. Each module gets a deadline, and a module that misses
  it renders as empty. Only `module.computeAll` changes; modules already
  declare whether they are `cheap` or `expensive`.
* **Phase 2: a native git reader.** No libgit2 and no shelling out to `git`.
  It will read HEAD, the index, loose objects, and packfiles with deltas,
  which enables dirty/ahead/behind status. This work grows under
  `src/git/`.
* **Phase 3: a daemon.** `butad` runs in the background, caches expensive
  module data and watches for changes with inotify (kqueue on macOS). `buta`
  asks it over a Unix socket and falls back to computing directly when the
  daemon isn't running. Module `Data` is already plain, serializable values.
