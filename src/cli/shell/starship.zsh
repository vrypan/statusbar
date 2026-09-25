# statusbar integration for zsh: eval "$(statusbar init zsh)"
#
# Runs starship's normal prompt and splits it: every line but the last goes
# to the bar's left slot, and the last line, the prompt character, stays in
# the terminal. A one-line prompt stays whole and leaves the bar alone.
if (( $+commands[starship] )); then
  __statusbar_prompt() {
    local out full rest newline
    out=$(STARSHIP_SHELL=zsh starship prompt --terminal-width="$COLUMNS" --keymap="${KEYMAP:-}" --status="${STARSHIP_CMD_STATUS:-}" --pipestatus="${STARSHIP_PIPE_STATUS[*]:-}" --cmd-duration="${STARSHIP_DURATION:-}" --jobs="$STARSHIP_JOBS_COUNT")
    full=$out
    # Starship's add_newline blank line separates the prompt from the last
    # command's output; it stays with the prompt, not the bar.
    if [[ $out == $'\n'* ]]; then
      newline=$'\n'
      out=${out#$'\n'}
    fi
    if [[ $out == *$'\n'* ]]; then
      rest=${out%$'\n'*}
      out=${out##*$'\n'}
      # Starship marks escape codes with %{ %} and doubles literal percent
      # signs for zsh; prompt expansion turns that back into plain output.
      if ! command @STATUSBAR@ set @SLOT@ "${(%)rest}" 2>/dev/null; then
        out=$full
        newline=''
      fi
    fi
    print -rn -- "$newline$out"
  }

  # starship init sets PROMPT when it is evaluated, so take it over at the
  # first prompt instead. That works whichever init comes first in .zshrc.
  __statusbar_setup() {
    precmd_functions=(${precmd_functions:#__statusbar_setup})
    setopt prompt_subst
    PROMPT='$(__statusbar_prompt)'
  }
  precmd_functions=(${precmd_functions:#__statusbar_setup} __statusbar_setup)
fi
