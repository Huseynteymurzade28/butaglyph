#!/usr/bin/env bash
# Interactive line-editing check: drives bash/zsh in tmux and asserts cursor
# positions while editing a command that wraps past the terminal width.
# "bash-broken" uses an unwrapped prompt and is expected to FAIL (control).
# usage: tests/lineedit.sh <bash|zsh|bash-broken>   (needs tmux; run `zig build` first)
set -u
mode=$1; W=50; T="tmux -L butale"; ROOT=$(cd "$(dirname "$0")/.." && pwd); B=$ROOT/zig-out/bin/buta
$T kill-server 2>/dev/null
case $mode in
  bash)        cmd="bash --norc --noprofile -i"; init="eval \"\$($B init bash)\"" ;;
  bash-broken) cmd="bash --norc --noprofile -i"; init="eval \"\$($B init bash)\"; __buta_prompt_command() { PS1=\"\$($B prompt --shell plain --status 1)\"; }" ;;
  zsh)         cmd="zsh -f -i"; init="eval \"\$($B init zsh)\"" ;;
esac
$T -f /dev/null new-session -d -x $W -y 20 -s t "env -i HOME=$HOME LANG=${TEST_LANG:-C.UTF-8} TERM=xterm-256color PATH=$PATH BUTA_CONFIG=${TEST_CONFIG:-/nonexistent} $cmd"
sleep 0.6
$T send-keys -t t "cd $ROOT; $init" Enter; sleep 0.5
$T send-keys -t t "false" Enter; sleep 0.4          # red status + red character: more escapes
$T send-keys -t t "clear" Enter; sleep 0.5
fail=0
cur() { sleep 0.3; $T display -p -t t '#{cursor_x},#{cursor_y}'; }
expect() { local got; got=$(cur); if [[ $got == "$2" ]]; then echo "  ok   $1 -> $got"; else echo "  FAIL $1 -> got $got, want $2"; fail=1; fi; }
# Prompt: row 0 = dir/git/status, row 1 = "❯ " + input (2 columns).
long="echo $(printf 'a%.0s' {1..115})"            # 120 chars
$T send-keys -t t -l "$long"
p=$((2 + 120)); expect "typed 120 chars" "$((p % W)),$((1 + p / W))"
$T send-keys -t t C-a;  expect "Ctrl-A (start)" "2,1"
$T send-keys -t t -l "X"; expect "insert at start" "3,1"
$T send-keys -t t C-e;  p=$((2 + 121)); expect "Ctrl-E (end)" "$((p % W)),$((1 + p / W))"
for i in $(seq 30); do $T send-keys -t t BSpace; done
p=$((2 + 91)); expect "30x Backspace across wrap" "$((p % W)),$((1 + p / W))"
$T send-keys -t t C-u; expect "Ctrl-U (clear line)" "2,1"
$T send-keys -t t -l "$long"; $T send-keys -t t Enter; sleep 0.4
$T send-keys -t t "clear" Enter; sleep 0.5
$T send-keys -t t Up Up; p=$((2 + 120)); expect "history recall (Up)" "$((p % W)),$((1 + p / W))"
$T send-keys -t t C-a; expect "Ctrl-A on recalled line" "2,1"
echo "  screen:"; $T capture-pane -t t -p | sed '/^$/d; s/^/    | /'
$T kill-server
exit $fail
