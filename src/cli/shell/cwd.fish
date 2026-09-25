# Replacing the function also replaces its event registrations.
functions -e __statusbar_report_cwd
function __statusbar_report_cwd --on-event fish_prompt --on-variable PWD
  set -l saved_status $status
  set -l encoded (string escape --style=url -- "$PWD" | string replace -a '%2F' '/')
  printf '\033]7;file://%s%s\033\\' "$hostname" "$encoded" 2>/dev/null >/dev/tty
  return $saved_status
end
