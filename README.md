# butaglyph

A fast, shell-agnostic prompt engine written in Zig, in the spirit of
Starship and Oh My Posh. The command is `buta`.

```
~/dev/butaglyph  main +1 !2 ⇡3  2.3s  1
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

The default glyph set needs a [Nerd Font](https://www.nerdfonts.com) and a
UTF-8 locale (otherwise the shell measures the glyphs in bytes, not columns,
and the cursor drifts). Without either, set `.glyphs = .ascii` (see below).

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
    .order = .{ .dir, .git_branch, .git_status, .duration, .status, .jobs, .line_break, .character },
    .separator = " ",
    // Deadline for expensive modules (git), in ms from prompt start.
    .timeout_ms = 100,

    // Colors: "red", "bright_cyan", "208" (256-color), "#7aa2f7" (truecolor).
    // Style flags: bold, dim, italic, underline. Background: .bg.
    .dir = .{
        .style = .{ .fg = "#7aa2f7", .bold = true },
        .home_symbol = "~",
        .max_length = 24, // abbreviate once longer than this (0 = always)
        .abbrev_len = 1,  // ~/d/b/src: characters kept per directory
        .full_dirs = 2,   // trailing directories never abbreviated
    },
    .git_branch = .{ .style = .{ .fg = "magenta" }, .symbol = "on ", .max_length = 32, .timeout_ms = 50 },
    .git_status = .{ .style = .{ .fg = "red" }, .show_counts = true, .ahead_behind = true },
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
| `git_branch` | Branch from `.git/HEAD`, or the short hash when HEAD is detached. Works in subdirectories, worktrees and submodules (`.git` files with `gitdir:`) | `symbol`, `detached_symbol`, `hash_length`, `max_length`, `timeout_ms` |
| `git_status` | Staged (`+`), modified (`!`), deleted (`✘`) and conflicted (`=`) paths, and commits ahead of (`⇡`) and behind (`⇣`) the upstream. Hidden when the tree is clean and in sync | `*_symbol`, `show_counts`, `ahead_behind`, `worktree`, `timeout_ms` |
| `status`     | The last exit code, if non-zero. `130` is shown as `INT`, and so on | `symbol`, `signal_names` |
| `duration`   | How long the last command ran, if longer than `min_ms`        | `symbol`, `min_ms` |
| `jobs`       | Number of background jobs. Not in the default order           | `symbol`, `min`, `count_from` |
| `character`  | The prompt symbol: green on success, red on failure           | `success_symbol`, `failure_symbol`, `*_style`, `suffix` |
| `line_break` | A newline, for multi-line prompts                             | none |

Every module except `line_break` has a `style` (or `success_style`/`failure_style`) and a
`symbol` override; leaving `symbol` unset uses the active glyph set.

Set `BUTA_DEBUG=1` to have modules report their errors and missed
deadlines on stderr.

## Design

* **The prompt never breaks.** If a module errors, it renders as empty and
  the rest of the prompt is drawn.
* **The prompt is never slow.** Modules that touch the filesystem
  (`expensive`: currently `git_branch`) run on worker threads, and each
  one has a deadline (`timeout_ms`, 100 ms by default). A module that
  misses its deadline is left out of that prompt. A late task is never
  waited for: it may be stuck in a syscall that can't be interrupted (a hung
  network mount, for example), so buta prints the prompt and exits, which
  ends the task. `cheap` modules do no I/O and run inline on the main
  thread, because dispatching them would cost more than computing them.
  If no expensive module is configured, no thread is started.
* **Computing and rendering are separate.** Each module's `compute`
  produces plain `Data` with no pointers into the process state. Its
  `render` is a pure function from `Data` to styled spans. Only
  `src/render.zig` knows about escape sequences.
* **Correct line editing.** Escape sequences are wrapped as zero-width
  (`\[ \]` in bash, `%{ %}` in zsh), so long input lines wrap correctly.
* **git without git.** `src/git/` reads repositories directly, with no
  libgit2 and no `git` subprocess. It handles `.git` files (worktrees and
  submodules), `commondir`, loose and packed refs, loose objects, and
  packfiles with OFS and REF deltas (memory-mapped `.idx`/`.pack`). It also
  reads the index (v2–v4, using the cache-tree extension to skip unchanged
  directories). Working-tree checks use `lstat`, and fall back to hashing
  the content when the stat data is inconclusive or "racy", as git does;
  large indexes are checked on several threads. Ahead/behind uses git's
  date-ordered merge-base paint. The test suite compares every result with
  the real `git status` and `git rev-list` on generated repositories, and
  checks that every object in loose, OFS-delta and REF-delta packs hashes
  back to its id.
* **Paths can't inject commands.** Text from the filesystem (directory and
  branch names) is quoted for the target shell, so a directory named
  `$(rm -rf ~)` is displayed, never executed. Control characters are
  replaced. The test suite checks this against real bash, zsh and fish.
* **Minimal allocation.** Every allocation on the prompt path comes from
  fixed buffers: one for the config, plus one per module so that modules on
  different threads never share an allocator. All of it is released
  together when the process exits.
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
  git/               the git reader (its own module, imported as "git")
    repo.zig         discovery, worktrees (.git files, commondir), HEAD
    refs.zig         loose refs, packed-refs, symbolic refs
    odb.zig          loose objects, packfiles, delta chains
    delta.zig        git's binary delta format
    object.zig       commit and tree parsing
    index.zig        index v2-v4 and the cache-tree extension
    config.zig       a small git-config reader
    status.zig       staged/modified/deleted/conflicted, ahead/behind
  modules/*.zig      one file per module
  shell/*.sh         init scripts (embedded with @embedFile)
tests/integration.zig  drives the real binary and real shells
tests/git_compat.zig   compares the git reader with the real git CLI
bench/bench.zig        prompt latency benchmark
```

## Development

```sh
zig build test    # unit + integration tests (shell tests run for installed shells)
zig build bench   # 1000 × `buta prompt` in ReleaseFast: mean / p50 / p99
zig build bench -- 5000
tests/lineedit.sh bash   # interactive cursor check in tmux (also: zsh)
```

Measured on the development machine (Linux, x86-64) with a full config
file, including fork/exec. The target is a mean under 2 ms.

| Configuration                                      | Mean     | p99     |
|----------------------------------------------------|----------|---------|
| Default modules in this repo (git branch + status) | ≈0.78 ms | ≈1.4 ms |
| No expensive module (no thread)                    | ≈0.33 ms | ≈0.8 ms |

Each worker thread costs ≈0.1 ms on this machine; that is the kernel cost
of creating it, measured with `std.Thread.spawn` on its own. `git_status`
grows with the number of tracked files, mostly because of one `lstat` per
file. Best-of-15 wall time with `git_status` was ≈3.1 ms on a 2.9k-file repo
and ≈4.1 ms on a 5.4k-file repo; `git status -uno` took 60–95 ms on the same
repos. The Phase 3 daemon will serve this from a cache.

## Roadmap

* **Phase 0 (done).** The CLI, the modules listed above, ZON config, glyph
  sets and the bash/zsh/fish integration.
* **Phase 1 (done): parallel modules with deadlines.** Expensive modules
  run concurrently through `std.Io`, each with its own deadline, and a
  module that misses it renders as empty. Only `module.computeAll`
  changed; the modules themselves did not.
* **Phase 2 (done): a native git reader.** HEAD, refs, the index, loose
  objects, packfiles and deltas, all without libgit2 or `git`. This powers
  `git_status`. Known gaps:
  * untracked files are not reported (planned with the daemon, which can
    keep the ignore rules and directory state warm);
  * rename detection is not done, so a rename counts as a deletion plus an
    addition, as with `git status --no-renames`;
  * clean/smudge filters (autocrlf, LFS) are not applied;
  * not supported: SHA-256 repositories, reftable, split or sparse
    indexes, and object alternates. In any of these cases the module
    renders as empty.
* **Phase 3: a daemon.** `butad` runs in the background, caches expensive
  module data and watches for changes with inotify (kqueue on macOS). `buta`
  asks it over a Unix socket and falls back to computing directly when the
  daemon isn't running. Module `Data` is already plain, serializable values.
