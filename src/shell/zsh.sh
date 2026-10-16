# butaglyph: zsh integration. Load with:  eval "$(buta init zsh)"

zmodload zsh/datetime 2>/dev/null   # $EPOCHREALTIME
zmodload zsh/parameter 2>/dev/null  # $jobstates

typeset -g __buta_bin=::BUTA::
typeset -g __buta_prompt=''

__buta_preexec() {
    typeset -g __buta_start=$EPOCHREALTIME
}

__buta_precmd() {
    local __buta_status=$?
    local __buta_duration=''
    if [[ -n ${__buta_start-} ]]; then
        local -i __buta_ms
        (( __buta_ms = (EPOCHREALTIME - __buta_start) * 1000 ))
        __buta_duration=$__buta_ms
        unset __buta_start
    fi
    __buta_prompt="$("$__buta_bin" prompt --shell zsh --status "$__buta_status" \
        --duration-ms "$__buta_duration" --jobs ${#jobstates})"
    return $__buta_status
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec __buta_preexec
# Run first, so $? is still the user's command status. Idempotent.
precmd_functions=(__buta_precmd ${precmd_functions:#__buta_precmd})

# With prompt_subst the variable is expanded once and its value is not
# re-expanded, so only `%` needs quoting (buta does that); `$(...)` in a
# directory name stays inert.
setopt prompt_subst
PROMPT='${__buta_prompt}'
