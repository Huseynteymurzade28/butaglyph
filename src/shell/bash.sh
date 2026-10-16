# butaglyph: bash integration. Load with:  eval "$(buta init bash)"
# Needs bash >= 4.4 for command durations (PS0); bash >= 5.0 for ms precision.

__buta_bin=::BUTA::

# PS0 is expanded in the current shell right before a command runs, so an
# arithmetic assignment inside it records the start time without forking.
# `${PS0:0:N}` with N = 0 expands to nothing; PS0 is used because it is
# guaranteed to be set while it is being expanded (bash skips the offset
# arithmetic for unset variables).
if [[ -n ${EPOCHREALTIME-} ]]; then
    __buta_now='${EPOCHREALTIME/[.,]/}'
else
    __buta_now='SECONDS*1000000'
fi
__buta_ps0='${PS0:0:$((__buta_start_us='"$__buta_now"', 0))}'

__buta_prompt_command() {
    local __buta_status=$? __buta_duration= __buta_jobs=0
    if [[ -n ${__buta_start_us-} ]]; then
        local __buta_end_us
        if [[ -n ${EPOCHREALTIME-} ]]; then
            __buta_end_us=${EPOCHREALTIME/[.,]/}
        else
            __buta_end_us=$((SECONDS * 1000000))
        fi
        __buta_duration=$(( (__buta_end_us - __buta_start_us) / 1000 ))
        unset __buta_start_us
    fi
    if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )); then
        __buta_jobs='\j'
        __buta_jobs=${__buta_jobs@P}  # job count without a subshell
    else
        __buta_jobs=$(jobs -p | wc -l)
    fi
    PS1="$("$__buta_bin" prompt --shell bash --status "$__buta_status" \
        --duration-ms "$__buta_duration" --jobs "$__buta_jobs")"
    return "$__buta_status"  # keep $? intact for later PROMPT_COMMAND entries
}

# Run first, so $? is still the user's command status. Idempotent.
if [[ ${PROMPT_COMMAND[*]-} != *__buta_prompt_command* ]]; then
    if [[ $(declare -p PROMPT_COMMAND 2>/dev/null) == "declare -a"* ]]; then
        PROMPT_COMMAND=(__buta_prompt_command "${PROMPT_COMMAND[@]}")
    else
        PROMPT_COMMAND="__buta_prompt_command${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
    fi
fi
if [[ ${PS0-} != *__buta_start_us* ]]; then
    PS0="$__buta_ps0${PS0-}"
fi
