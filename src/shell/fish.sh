# butaglyph: fish integration. Load with:  buta init fish | source

set -g __buta_bin ::BUTA::

# fish_postexec fires only when a command actually ran, so pressing Enter
# on an empty line does not repeat the previous duration.
function __buta_postexec --on-event fish_postexec
    set -g __buta_duration $CMD_DURATION
end

function fish_prompt
    set -l last_status $status
    set -l duration $__buta_duration
    set -e __buta_duration
    $__buta_bin prompt --shell fish --status $last_status \
        --duration-ms "$duration" --jobs (count (jobs -p 2>/dev/null))
end
