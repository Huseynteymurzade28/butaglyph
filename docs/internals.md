# butaglyph internals

The daemon, the design, development and the roadmap. Back to the
[README](../README.md); settings are in [configuration.md](configuration.md).

## The daemon

`buta daemon` keeps the git modules' results in memory and refreshes them
only when something in the repository changes, so a prompt in a large
repository costs about as much as one anywhere else. It runs on Linux
(inotify) and macOS (kqueue).

By default (`.daemon = .auto`) you don't have to do anything: when a
prompt finds no daemon, it starts `buta daemon --detach` in the background
and computes this one prompt itself; the next prompt asks the daemon. A
daemon that can't start is tried again only every 30 seconds, so it never
costs more than one process spawn per half minute. With `.daemon = .manual`
buta uses a daemon only if you started one, and with `.off` it never asks.

```sh
buta daemon --detach   # start it in the background
buta daemon status     # pid, cached repositories, watches, hits and misses
buta daemon stop       # with .daemon = .auto, a prompt restarts it after 30 s
```

`buta daemon` without `--detach` stays in the foreground, which suits a
systemd user service (`~/.config/systemd/user/buta.service`, then
`systemctl --user enable --now buta`; set `.daemon = .manual` then):

```ini
[Unit]
Description=butaglyph prompt cache

[Service]
ExecStart=%h/.local/bin/buta daemon
Restart=on-failure

[Install]
WantedBy=default.target
```

The socket is `$BUTA_SOCKET` if set (an empty `BUTA_SOCKET` turns the
daemon off for that shell), else `$XDG_RUNTIME_DIR/butaglyph.sock`, else
on macOS `$TMPDIR/butaglyph.sock` (both directories are private to you).
Otherwise there is no daemon.

**Upgrades.** Client and daemon compare a fingerprint of their protocol
and of every type that crosses the socket. A prompt from a different build
never trusts the daemon's answers and computes everything itself. When
that happens and the daemon's own executable has been replaced on disk
(an upgrade), the daemon exits, and the next prompt starts the new one.

* **Never stale.** A cached result is used only if the file system has
  reported no change in the repository since it was computed. The kernel
  queues an event before the syscall that caused it returns, and the
  daemon reads the queue before every lookup, so a command that has
  finished is always reflected in the next prompt. The test suite runs a
  long sequence of git operations (commits, stashes, branch switches,
  worktrees, `pack-refs`, moved directories, rapid same-size rewrites,
  untracked files, `.gitignore`, `info/exclude` and global excludes
  changes) and checks every prompt the daemon serves against a local
  computation.
* **Watches only what matters.** HEAD, the index, config, packed-refs,
  `info/exclude`, everything under `refs/`, your global git config and
  excludes files, and the work tree directories that are not ignored.
  Ignored directories (build output, `node_modules`) are not watched, so
  churn there costs nothing. kqueue can't see writes to the files in a
  watched directory, so on macOS every tracked file is watched too (one
  file descriptor each; the daemon raises its limit as far as the system
  allows). If the watches run out (`fs.inotify.max_user_watches` on
  Linux, file descriptors on macOS), that repository is simply not cached.
* **Never slower than its deadline.** The prompt sends its request
  before computing the cheap modules and waits for each answer only until
  that module's deadline. No daemon, a refused connection or a daemon from
  another build means computing locally; a daemon that hangs up early
  means computing locally whatever it didn't answer.
* **Private.** The daemon answers only processes of its own user, and on
  Linux only in its own mount namespace (a shell in a container computes
  locally).

## Design

* **The prompt never breaks.** If a module errors, it renders as empty and
  the rest of the prompt is drawn.
* **The prompt is never slow.** Modules that touch the filesystem
  (`expensive`: the git modules) run on worker threads, and each one has a
  deadline (`timeout_ms`, 100 ms by default). A module that misses its
  deadline is left out of that prompt. A late task is never waited for: it
  may be stuck in a syscall that can't be interrupted (a hung network
  mount, for example), so buta prints the prompt and exits, which ends the
  task. `cheap` modules do no I/O and run inline on the main thread,
  because dispatching them would cost more than computing them. If no
  expensive module is configured, no thread is started. The language
  modules are `batch`ed: they share one worker thread, one after
  another, because outside their projects each of them is done after a
  few `stat` calls, much less than the cost of a thread.
* **Computing and rendering are separate.** Each module's `compute`
  produces plain `Data` with no pointers into the process state. Its
  `render` is a pure function from `Data` to styled spans. Only
  `src/render.zig` knows about escape sequences. That is what lets the
  daemon compute `Data` in another process: modules that declare
  `scope = .repo` (their result depends only on the repository and their
  config) are served by it, and a module's `Config` and `Data` cross the
  socket through a small generic codec (`src/wire.zig`). Client and
  daemon compare a hash of all those types' shapes before talking.
* **Correct line editing.** Escape sequences are wrapped as zero-width
  (`\[ \]` in bash, `%{ %}` in zsh), so long input lines wrap correctly.
* **git without git.** `src/git/` reads repositories directly, with no
  libgit2 and no `git` subprocess. It handles `.git` files (worktrees and
  submodules), `commondir`, loose and packed refs, loose objects, and
  packfiles with OFS and REF deltas (memory-mapped `.idx`/`.pack`). It also
  reads the index (v2–v4, using the cache-tree extension to skip unchanged
  directories). Working-tree checks use `lstat`, and fall back to hashing
  the content when the stat data is inconclusive or "racy", as git does;
  `core.fileMode`, `core.symlinks`, `core.trustCtime` and `core.checkStat`
  are honored, and on Windows the stat fields Git for Windows doesn't
  record are left out. Large indexes are checked on several threads.
  Untracked files come from a walk of the work tree that never enters an
  ignored directory, with a port of git's `wildmatch` and its precedence
  rules (nested `.gitignore` files, `info/exclude`, `core.excludesFile`).
  Staged renames are found with git's own similarity estimate and pairing
  order (exact matches, then unique file names, then the best-scoring
  pairs at 50% or more). Ahead/behind uses git's date-ordered merge-base paint. The test suite
  compares every result with the real `git status` and `git rev-list` on
  generated repositories (including random trees with random ignore rules),
  and checks that every object in loose, OFS-delta and REF-delta packs
  hashes back to its id.
* **Paths can't inject commands.** Text from the filesystem (directory and
  branch names) is quoted for the target shell, so a directory named
  `$(rm -rf ~)` is displayed, never executed. Control characters are
  replaced. The test suite checks this against real bash, zsh and fish.
* **Minimal allocation.** Every allocation on the prompt path comes from
  fixed buffers: one for the config, plus one per module so that modules on
  different threads never share an allocator. All of it is released
  together when the process exits.
  Output is written once, through a buffered writer.
* **One code base, three systems.** Paths are handled in `/` form
  everywhere (Windows accepts it), environment access goes through
  `src/env.zig` (Windows keeps its environment in UTF-16), and the
  daemon's system calls go through `src/sys.zig` (raw syscalls on Linux,
  libc on macOS) and `src/watch.zig` (inotify or kqueue).

```
src/
  main.zig           entry point, `init`, `prompt` and `daemon` commands
  cli.zig            argument parsing (lenient for `prompt`)
  env.zig            environment variables and paths on every platform
  daemon.zig         the cache daemon: socket, watches, cache
  client.zig         the prompt's side of the daemon protocol; autostart
  protocol.zig       messages, socket path, protocol fingerprint
  wire.zig           binary codec for module Config and Data
  sys.zig            Unix sockets, locks, processes (Linux and macOS)
  watch.zig          file change notification: inotify and kqueue
  context.zig        shared read-only input: cwd, env, status, duration, jobs
  module.zig         module interface, registry, compute/render drivers
  config.zig         ZON config loading
  webconfig.zig      `buta config`: HTTP server, JSON/ZON conversion, schema
  webconfig/         the editor page (embedded)
  glyphs.zig         glyph sets: Unicode (default), Nerd Font, ASCII
  render.zig         spans, colors, gradients (OKLab), ANSI, per-shell quoting
  git/               the git reader (its own module, imported as "git")
    repo.zig         discovery, worktrees (.git files, commondir), HEAD
    refs.zig         loose refs, packed-refs, symbolic refs
    odb.zig          loose objects, packfiles, delta chains
    delta.zig        git's binary delta format
    object.zig       commit and tree parsing
    index.zig        index v2-v4 and the cache-tree extension
    config.zig       a small git-config reader
    ignore.zig       .gitignore rules and wildmatch
    untracked.zig    the work tree walk for untracked files
    status.zig       staged/modified/deleted/conflicted/untracked, ahead/behind
    rename.zig       staged rename detection (git's diffcore-rename)
  modules/*.zig      one file per module
    lang.zig         what the language modules share: project detection
                     (directory listings read once), $PATH lookup, the
                     version cache and its helper, `Simple` modules
    langs.zig        ruby, php, deno, bun, lua, haskell
  shell/             init scripts (embedded with @embedFile)
examples/            presets (embedded in the binary by presets.zig)
docs/tools/          scripts that regenerate the screenshots and the GIF
tests/integration.zig  drives the real binary and real shells
tests/git_compat.zig   compares the git reader with the real git CLI
tests/daemon.zig       checks the daemon's answers against local computation
bench/bench.zig        prompt latency benchmark
```

## Development

```sh
zig build test    # unit + integration tests (shell tests run for installed shells)
zig build bench   # 1000 × `buta prompt` in ReleaseFast: mean / p50 / p99
zig build bench -- 5000
tests/lineedit.sh bash   # interactive cursor check in tmux (also: zsh)
zig build test -Dtarget=x86_64-windows -fwine   # the Windows build, under wine
docs/tools/demo.sh       # regenerate docs/*.png and docs/demo.gif from real shells
```

CI (`.github/workflows/ci.yml`) runs the tests on Linux, macOS and Windows,
checks formatting and cross-compiles every release target.

Measured on the development machine (Linux, x86-64) with the daemon off,
including fork/exec. The target is a mean under 2 ms.

| Configuration                                      | Mean     | p99     |
|----------------------------------------------------|----------|---------|
| Default modules in this repo (git branch + status, untracked included) | ≈0.95 ms | ≈1.6 ms |
| No expensive module (no thread)                    | ≈0.39 ms | ≈0.8 ms |

Each worker thread costs ≈0.1 ms on this machine; that is the kernel cost
of creating it, measured with `std.Thread.spawn` on its own. `git_status`
grows with the number of tracked files, mostly because of one `lstat` per
file, and with the number of directories that aren't ignored (untracked
files need a walk). Best-of-15 wall time with `git_status` (before
untracked files were counted) was ≈3.1 ms on a 2.9k-file repo and ≈4.1 ms
on a 5.4k-file repo; `git status -uno` took 60–95 ms on the same repos.

With the daemon running, a cache hit is one round trip over the socket and
starts no thread. In one 2000-run benchmark in this repository (with a
dirty work tree), `buta prompt` took 0.08 ms more than `/bin/true` with the
daemon and 0.98 ms more without it. The cost no longer grows with the
repository; after a change, the first prompt pays for one recomputation in
the daemon.

## Roadmap

* **Phase 0 (done).** The CLI, the modules listed above, ZON config, glyph
  sets and the bash/zsh/fish integration.
* **Phase 1 (done): parallel modules with deadlines.** Expensive modules
  run concurrently through `std.Io`, each with its own deadline, and a
  module that misses it renders as empty. Only `module.computeAll`
  changed; the modules themselves did not.
* **Phase 2 (done): a native git reader.** HEAD, refs, the index, loose
  objects, packfiles and deltas, all without libgit2 or `git`. This powers
  `git_status`.
* **Phase 3 (done): a daemon.** `buta daemon` caches the git modules'
  data and watches repositories. `buta prompt` asks it over a Unix socket
  and computes directly when it isn't running. It is a subcommand rather
  than a separate `butad` binary, so client and daemon always come from
  the same build.
* **Phase 4 (done): everywhere, and complete.** Untracked files with
  exact `.gitignore` semantics; the daemon starts by itself and makes way
  after an upgrade; the daemon runs on macOS (kqueue); buta builds and
  runs on Windows, with PowerShell integration; presets, screenshots, CI
  on three systems and release binaries.
* **Phase 5 (done): looks.** Gradients and rainbows blended in OKLab,
  self-joining segments with any edge shape, the `text` module for
  ornaments, path separators, more style flags, ten presets embedded in
  the binary, and `buta preview` / `buta preset` to try and install them.
* **Phase 6 (done): languages.** `python` (with virtual and conda
  environments), `node`, `rust` (rustup toolchains resolved without the
  proxy), `go` and `zig`. They are detected from project files in the
  working directory and its parents. Versions are read from files where
  the toolchain leaves one, and otherwise asked once and cached on disk.
  The modules share one worker thread, so with all five in the default
  order a prompt costs no more than before.
* **Phase 7 (done): no font dependency, and contexts.** The default
  glyphs and every preset use standard Unicode only (block elements for
  segment shapes), and Nerd Font icons are opt-in. New modules: `aws`,
  `docker_context` and `kubernetes`, read from their config files without
  running any CLI.
* **Phase 8 (done): `buta config`.** A configuration editor in the
  browser. The page's forms are built from a schema that is derived from
  the `Config` type at compile time. The preview runs the real prompt in
  a child process. Saving writes minimal ZON that is checked to read back
  as the same config.

Planned work and known gaps are tracked in
[GitHub issues](https://github.com/Huseynteymurzade28/butaglyph/issues).

Known gaps:

* clean/smudge filters (autocrlf, LFS) are not applied when hashing (on
  Windows with `core.autocrlf`, a file whose stat data changed but whose
  content didn't may show as modified until git refreshes the index);
* the system git config (`/etc/gitconfig`) and `[include]` are not read;
* not supported: SHA-256 repositories, reftable, split or sparse indexes,
  and object alternates. In any of these cases the module renders as empty;
* no daemon on Windows yet; prompts there are computed directly;
* on macOS, kqueue reports no file names, so any file created or removed
  directly in your home directory (where `~/.gitconfig` lives) makes the
  daemon rebuild its watches once.
