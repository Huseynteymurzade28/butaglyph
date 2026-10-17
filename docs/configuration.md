# Configuring butaglyph

Back to the [README](../README.md). For how buta works inside, see
[internals.md](internals.md).

## The config file

buta reads its config from `$BUTA_CONFIG` if set, otherwise from
`$XDG_CONFIG_HOME/butaglyph/config.zon`, otherwise from
`~/.config/butaglyph/config.zon` (on Windows `~` is your profile directory,
`%USERPROFILE%`). The file is
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
    // The cache daemon: .auto (use it, start it when needed), .manual, .off
    .daemon = .auto,

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
    .git_status = .{ .style = .{ .fg = "red" }, .show_counts = true, .untracked = true, .ahead_behind = true },
    .status = .{ .style = .{ .fg = "red", .bold = true }, .signal_names = true },
    .duration = .{ .style = .{ .fg = "yellow" }, .min_ms = 2000 },
    .jobs = .{ .style = .{ .fg = "blue" } },
    .character = .{ .success_symbol = "❯", .failure_symbol = "✗" },
}
```

## Styling

Every `style` (and `success_style`/`failure_style`) takes:

```zig
.{
    .fg = "#ff2a6d",          // "red", "bright_cyan", "208" or "#rrggbb"
    .bg = "#7a1424>#b8323b",  // a gradient: two or more colors joined by ">"
    .bold = true, .dim = false, .italic = false, .underline = false,
    .blink = false, .inverse = false, .strikethrough = false,
}
```

* **Gradients.** `"#ff0080>#7928ca>#00e5ff"` runs across the module's
  text, one color per character, through up to eight stops. The colors are
  blended in [OKLab](https://bottosson.github.io/posts/oklab/), so a red
  to blue gradient passes through purple instead of mud. Named and 256
  colors work as stops too.
* **`"rainbow"`** runs through the whole spectrum, for `fg` or `bg`.
* Gradients need a truecolor terminal. Most terminals are; where one
  isn't, the colors are approximated or ignored, and the text still shows.

**Segments.** With `.segments` set, every module that has a background
becomes a segment, and neighboring segments are joined by a glyph drawn
in both of their colors (the edges of a gradient, if they have one).
Modules without a background are drawn as usual, between runs of
segments.

```zig
.segments = .{
    .open = "\u{e0b6}",  // before a run of segments
    .join = "\u{e0b0}",  // between two segments; null: separate pills
    .close = "\u{e0b0}", // after a run
    .padding = " ",      // inside each segment, on both sides
},
```

Some shapes from the Nerd Font set (and plain Unicode, which needs no
special font):

| Shape     | open       | join       | close      |
|-----------|------------|------------|------------|
| arrow     | `\u{e0b2}` | `\u{e0b0}` | `\u{e0b0}` |
| round     | `\u{e0b6}` | `\u{e0b4}` | `\u{e0b4}` |
| slant     | `\u{e0ba}` | `\u{e0bc}` | `\u{e0bc}` |
| flame     | `\u{e0c2}` | `\u{e0c0}` | `\u{e0c0}` |
| pixel     | `\u{e0c7}` | `\u{e0c6}` | `\u{e0c6}` |
| shade     | `░▒▓`      | `\u{e0b0}` | `▓▒░`      |
| pills     | `\u{e0b6}` | `null`     | `\u{e0b4}` |

**Ornaments.** The `text` module draws fixed pieces of styled text:
motifs, frames, labels. List `.text` in `order` wherever it should go
(several times if you like):

```zig
.order = .{ .text, .dir, .git_branch, .line_break, .character },
.text = .{ .pieces = .{
    .{ .text = "╭─", .style = .{ .fg = "#585b70" } },
    .{ .text = "❧", .style = .{ .fg = "#e6a532>#b8323b" } },
} },
.character = .{ .success_symbol = "╰─❯" },
```

**Paths.** `.dir = .{ .separator = " ❯ " }` draws `~ ❯ dev ❯ butaglyph`;
any string works (`" \u{e0b1} "` for a powerline chevron, `" • "`,
`" ∕ "`). The root of an absolute path stays `/`.

## Modules

| Module       | Shows                                                         | Main options |
|--------------|---------------------------------------------------------------|--------------|
| `dir`        | Working directory, `$HOME` as `~`, fish-style abbreviation of long paths (UTF-8 aware). Windows drives and UNC roots are kept whole | `home_symbol`, `separator`, `abbreviate`, `max_length`, `abbrev_len`, `full_dirs` |
| `git_branch` | Branch from `.git/HEAD`, or the short hash when HEAD is detached. Works in subdirectories, worktrees and submodules (`.git` files with `gitdir:`) | `symbol`, `detached_symbol`, `hash_length`, `max_length`, `timeout_ms` |
| `git_status` | Conflicted (`=`), staged (`+`), modified (`!`), deleted (`✘`) and untracked (`?`) paths, and commits ahead of (`⇡`) and behind (`⇣`) the upstream. Hidden when the tree is clean and in sync | `*_symbol`, `show_counts`, `untracked`, `ahead_behind`, `worktree`, `timeout_ms` |
| `status`     | The last exit code, if non-zero. `130` is shown as `INT`, and so on | `symbol`, `signal_names` |
| `duration`   | How long the last command ran, if longer than `min_ms`        | `symbol`, `min_ms` |
| `jobs`       | Number of background jobs. Not in the default order           | `symbol`, `min`, `count_from` |
| `character`  | The prompt symbol: green on success, red on failure           | `success_symbol`, `failure_symbol`, `*_style`, `suffix` |
| `line_break` | A newline, for multi-line prompts                             | none |
| `text`       | Fixed pieces of styled text: ornaments, frames, labels        | `pieces` |

Every module except `line_break` and `text` has a `style` (or
`success_style`/`failure_style`) and a `symbol` override; leaving `symbol`
unset uses the active glyph set.

Untracked files are counted like `git status` does: an untracked
directory counts once (`dir/`), and the repository's
`status.showUntrackedFiles` (`no`, `normal`, `all`) applies. Set
`.git_status = .{ .untracked = false }` to skip the walk of the work tree
altogether.

Set `BUTA_DEBUG=1` to have modules report their errors and missed
deadlines on stderr.

## Shells in detail

| Shell      | Add to                       | Line                                                   |
|------------|------------------------------|--------------------------------------------------------|
| bash       | `~/.bashrc`                  | `eval "$(buta init bash)"`                             |
| zsh        | `~/.zshrc`                   | `eval "$(buta init zsh)"`                              |
| fish       | `~/.config/fish/config.fish` | `buta init fish \| source`                             |
| PowerShell | `$PROFILE`                   | `Invoke-Expression (& buta init powershell \| Out-String)` |

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
* **PowerShell** (Windows PowerShell 5.1 and PowerShell 7+, on any
  platform) defines `prompt`. It reads the duration from the history,
  passes PowerShell's location with `--cwd` (it isn't the process's working
  directory), keeps `$?` and `$LASTEXITCODE` intact, and tells PSReadLine
  how tall a multi-line prompt is. `pwsh` is accepted as a name too.
* **Windows**: PowerShell is the native choice. Under Git Bash, MSYS2 or
  Cygwin, `buta init bash` (or zsh, fish) writes the path of `buta.exe`
  in `C:/...` form, which those shells can run; this is less tested than
  PowerShell. Paths are shown with `/` (`C:/Users/me/dev`, or `~/dev`
  under your profile directory).

<p align="center"><img src="powershell.png" alt="butaglyph in PowerShell 7: a new untracked file, a failed cmdlet with status 1, and a slow command" width="640"></p>

You can also call `buta prompt` directly:

```sh
buta prompt --shell zsh --status 1 --duration-ms 5300 --jobs 2
```
