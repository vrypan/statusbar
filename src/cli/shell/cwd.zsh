# Report to the controlling terminal, never captured prompt stdout.
__statusbar_report_cwd() {
  emulate -L zsh
  local LC_ALL=C encoded='' char hex
  local -i i
  for (( i = 1; i <= ${#PWD}; i++ )); do
    char=${PWD[i]}
    case $char in
      [a-zA-Z0-9/._~-]) encoded+=$char ;;
      *) builtin printf -v hex '%%%02X' "'$char"; encoded+=$hex ;;
    esac
  done
  builtin printf '\033]7;file://%s%s\033\\' "$HOST" "$encoded" 2>/dev/null >/dev/tty
  return 0
}
typeset -ga precmd_functions chpwd_functions
precmd_functions=(${precmd_functions:#__statusbar_report_cwd} __statusbar_report_cwd)
chpwd_functions=(${chpwd_functions:#__statusbar_report_cwd} __statusbar_report_cwd)
