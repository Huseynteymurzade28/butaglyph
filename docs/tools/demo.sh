#!/usr/bin/env bash
# Regenerates the screenshots in docs/ from real shell sessions.
#
#   docs/tools/demo.sh [work-dir]
#
# Builds buta, sets up a demo repository (with an upstream) under a fake
# $HOME in work-dir, plays scenes in zsh and pwsh inside tmux, and renders
# the captures with render.py, and records docs/demo.gif. Needs zig, git,
# tmux, zsh, chromium and DejaVu Sans Mono (a plain font, to show that no
# Nerd Font is needed); pwsh (PWSH=/path/to/pwsh) and agg (for the GIF) are
# optional.
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
font="DejaVu Sans Mono"
render() { python3 "$root/docs/tools/render.py" "$@" --font "$font"; }
work=${1:-$(mktemp -d)}
out=$root/docs
home=$work/home
repo=$home/projects/carpet
bin=$work/bin/buta
mkdir -p "$home" "$work/bin"

(cd "$root" && zig build -Doptimize=ReleaseFast -p "$work/zig-out")
cp "$work/zig-out/bin/buta" "$bin"

export HOME=$home LANG=C.UTF-8 TERM=xterm-256color BUTA_SOCKET=
export GIT_AUTHOR_NAME=Demo GIT_AUTHOR_EMAIL=demo@example.com
export GIT_COMMITTER_NAME=Demo GIT_COMMITTER_EMAIL=demo@example.com
export GIT_CONFIG_GLOBAL=$home/.gitconfig
printf '[init]\n\tdefaultBranch = main\n[advice]\n\tdetachedHead = false\n' > "$home/.gitconfig"

# The demo repository, its upstream, and a commit upstream not fetched yet.
setup_repo() {
    rm -rf "$home/projects" "$home/remotes"
    mkdir -p "$home/remotes" "$home/projects"
    git init -q --bare "$home/remotes/carpet.git"
    git clone -q "$home/remotes/carpet.git" "$repo" 2>/dev/null
    cd "$repo"
    printf 'buta\nmedallion\n' > motifs.txt
    printf '# carpet\nWoven patterns.\n' > README.md
    mkdir -p src && printf 'pub fn weave() void {}\n' > src/loom.zig
    printf '*.o\nzig-out/\n' > .gitignore
    git add -A && git commit -qm "First pattern" && git push -q origin main
    git clone -q "$home/remotes/carpet.git" "$work/other" 2>/dev/null
    (cd "$work/other" && echo "border" >> motifs.txt && git commit -qam "Add border" && git push -q origin main)
    rm -rf "$work/other"
    cd "$work"
}

# play SESSION SHELL COLS ROWS COMMAND... : types each command, waits for it.
play() {
    local session=$1 shell=$2 cols=$3 rows=$4
    shift 4
    tmux kill-session -t "$session" 2>/dev/null || true
    tmux new-session -d -s "$session" -x "$cols" -y "$rows" -c "$repo" "$shell"
    sleep 1.5
    tmux send-keys -t "$session" C-l
    sleep 0.5
    local cmd
    for cmd in "$@"; do
        tmux send-keys -t "$session" -l "$cmd"
        tmux send-keys -t "$session" Enter
        case $cmd in *[Ss]leep*) sleep 3.5 ;; *) sleep 1 ;; esac
    done
    tmux capture-pane -e -p -t "$session" > "$work/$session.ans"
    tmux kill-session -t "$session"
}

zsh_with() { # zsh_with CONFIG: a zsh that loads buta with that config
    local dir=$work/zdot-$(basename "${1:-default}" .zon)
    mkdir -p "$dir"
    {
        [[ -n $1 ]] && echo "export BUTA_CONFIG='$1'"
        echo "unset RPROMPT; eval \"\$('$bin' init zsh)\""
    } > "$dir/.zshrc"
    echo "env ZDOTDIR=$dir zsh -i"
}

# 1. The tour: every git state, a failure and a slow command.
setup_repo
BUTA_CONFIG=/nonexistent play hero "$(zsh_with "")" 86 22 \
    'echo "ornament" >> motifs.txt' \
    'touch sketch.svg' \
    'git add motifs.txt' \
    'ls threads/' \
    'sleep 2.4' \
    'git commit -qm "Add ornament"' \
    'git fetch -q'
render "$work/hero.ans" "$out/hero.png" --title "zsh — ~/projects/carpet" --cols 86

# 2. The presets in examples/, on the same dirty repository.
for preset in $(grep -o 'name = "[^"]*"' "$root/examples/presets.zig" | cut -d'"' -f2); do
    setup_repo
    play "preset-$preset" "$(zsh_with "$root/examples/$preset.zon")" 90 10 \
        'echo "ornament" >> motifs.txt; touch sketch.svg' \
        'sleep 2.2; false'
    render "$work/preset-$preset.ans" "$out/preset-$preset.png" --title "examples/$preset.zon" --cols 90
done

# 3. Every preset at once, as `buta preview` draws them.
setup_repo
play gallery "$(zsh_with "")" 100 70 "echo ornament >> motifs.txt; touch sketch.svg; clear; '$bin' preview"
render "$work/gallery.ans" "$out/gallery.png" --title "buta preview" --cols 100

# 4. PowerShell.
if [[ -n ${PWSH:-} ]]; then
    setup_repo
    play pwsh "$PWSH -NoLogo -NoProfile -NoExit -Command \"Invoke-Expression (& '$bin' init powershell | Out-String)\"" 76 14 \
        'Set-Content notes.md "todo"' \
        'Get-Process nope' \
        'Start-Sleep 2.6'
    render "$work/pwsh.ans" "$out/powershell.png" --title "PowerShell 7" --cols 76
fi
# 5. The animated tour, recorded from a real terminal session, in the
# project's own preset.
if command -v agg > /dev/null; then
    setup_repo
    (cd "$repo" && python3 "$root/docs/tools/record.py" "$work/demo.cast" 80 15 "$(zsh_with "$root/examples/carpet.zon")" \
        'echo "ornament" >> motifs.txt' \
        'touch sketch.svg' \
        'git add motifs.txt' \
        'sleep 2.5; false' \
        'git commit -qm "Add ornament"' \
        'git fetch -q')
    # Catppuccin Mocha, as in the screenshots.
    agg --quiet --font-family "$font" --font-size 22 --line-height 1.35 --last-frame-duration 4 \
        --theme 1e1e2e,cdd6f4,45475a,f38ba8,a6e3a1,f9e2af,89b4fa,f5c2e7,94e2d5,bac2de,585b70,f38ba8,a6e3a1,f9e2af,89b4fa,f5c2e7,94e2d5,a6adc8 \
        "$work/demo.cast" "$out/demo.gif"
fi
echo "screenshots written to $out (work dir: $work)"
