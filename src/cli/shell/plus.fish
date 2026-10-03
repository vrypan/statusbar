# Keep a user's existing + command, alias or function.
if not type -q +
  function + --description 'Run a command in a background statusbar line'
    set -l name
    if test "$argv[1]" = --
      set -e argv[1]
    else if string match -q '+*' -- "$argv[1]"
      set name (string sub -s 2 -- "$argv[1]")
      set -e argv[1]
      if test -z "$name"
        printf '%s\n' 'Usage: + [+NAME] COMMAND [ARG...]' >&2
        return 2
      end
      if test "$argv[1]" = --
        set -e argv[1]
      end
    end
    if not set -q argv[1]; or test -z "$argv[1]"
      printf '%s\n' 'Usage: + [+NAME] COMMAND [ARG...]' >&2
      return 2
    end
    if test -n "$name"
      command @STATUSBAR@ new "$name" -- $argv &
    else
      set -l prefix (string replace -r '^.*/' '' -- "$argv[1]")
      set prefix (string replace -ar '[^A-Za-z0-9_-]' '-' -- "$prefix" | string sub -l 43)
      if test -z "$prefix"
        set prefix tmp
      end
      command @STATUSBAR@ new --prefix "$prefix" -- $argv &
    end
  end
end
