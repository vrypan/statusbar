# statusbar integration for fish: statusbar init fish | source
#
# Load this after `starship init fish | source`. Fish has a prompt
# function rather than Bash-style traps, so replace Starship's prompt
# renderer with one that moves all but its final line into the bar.
if command -q starship
  function fish_prompt
    set -l statusbar_status $status
    set -l statusbar_pipestatus $pipestatus
    set -l statusbar_duration "$CMD_DURATION$cmd_duration"
    set -l statusbar_keymap insert
    switch "$fish_key_bindings"
      case fish_hybrid_key_bindings fish_vi_key_bindings fish_helix_key_bindings
        set statusbar_keymap "$fish_bind_mode"
    end
    set -l statusbar_columns 80
    if set -q COLUMNS
      set statusbar_columns $COLUMNS
    end
    set -l out (STARSHIP_SHELL=fish starship prompt --terminal-width="$statusbar_columns" --keymap="$statusbar_keymap" --status="$statusbar_status" --pipestatus="(string join ' ' -- $statusbar_pipestatus)" --cmd-duration="$statusbar_duration" --jobs="(jobs -p 2>/dev/null | count)" | string collect)
    set -l full "$out"
    # Starship clears below the old prompt before its optional leading
    # newline. That terminal sequence belongs with the prompt, not the bar.
    set -l prefix ""
    if string match -rq '^\\e\\[J\\n' -- "$out"
      set prefix (string sub -s 1 -l 4 -- "$out")
      set out (string sub -s 5 -- "$out")
    end
    if string match -rq '(?s)^.*\\n.*$' -- "$out"
      set -l bar (string replace -r '(?s)\\n[^\\n]*$' '' -- "$out" | string collect)
      set out (string replace -r '(?s)^.*\\n' '' -- "$out")
      if not command @STATUSBAR@ set @SLOT@ "$bar" 2>/dev/null
        set prefix ""
        set out "$full"
      end
    end
    printf '%s%s' "$prefix" "$out"
  end
end
