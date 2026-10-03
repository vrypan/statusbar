# Keep a user's existing + command, alias or function.
if ! whence -w + >/dev/null 2>&1; then
  function '+' {
    emulate -L zsh
    local name
    if [[ ${1-} == -- ]]; then
      shift
    elif [[ ${1-} == +* ]]; then
      name=${1#+}
      shift
      if [[ -z $name ]]; then
        print -u2 -- 'Usage: + [+NAME] COMMAND [ARG...]'
        return 2
      fi
      [[ ${1-} == -- ]] && shift
    fi
    if (( $# == 0 )) || [[ -z $1 ]]; then
      print -u2 -- 'Usage: + [+NAME] COMMAND [ARG...]'
      return 2
    fi
    [[ -n $name ]] || name=${1:t}
    command @STATUSBAR@ add "$name" -- "$@" &
  }
fi
