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
    if [[ -n $name ]]; then
      command @STATUSBAR@ new "$name" -- "$@" &
    else
      local prefix=${1:t}
      prefix=${prefix//[^A-Za-z0-9_-]/-}
      prefix=${prefix[1,43]}
      [[ -n $prefix ]] || prefix=tmp
      command @STATUSBAR@ new --prefix "$prefix" -- "$@" &
    fi
  }
fi
