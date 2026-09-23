# Source this file from config.nu, after Starship's own init if you use it.
# Edit the slot number below if your layout uses a different slot.
# Nothing changes outside a statusbar session.

if ($env.STATUSBAR_LINES? != null) {
  # Report the current directory before each prompt so statusbar can update
  # the terminal title. The guard keeps repeated sourcing from adding hooks.
  if $env.__STATUSBAR_NU_CWD_HOOK? != true {
    let hooks = ($env.config.hooks? | default {})
    let previous = ($hooks.pre_prompt? | default [])
    $env.config.hooks = ($hooks | upsert pre_prompt ($previous | append {||
      let encoded = ($env.PWD | url encode --all | str replace --all '%2F' '/')
      print -n $"(char --unicode '1b')]7;file://($encoded)(char bel)"
    }))
    $env.__STATUSBAR_NU_CWD_HOOK = true
  }

  if (which starship | is-not-empty) {
    $env.STARSHIP_SHELL = 'nu'
    $env.STARSHIP_SESSION_KEY = (random chars -l 16)
    $env.PROMPT_MULTILINE_INDICATOR = (^starship prompt --continuation)
    $env.PROMPT_INDICATOR = ''
    $env.config.render_right_prompt_on_last_line = true

    $env.PROMPT_COMMAND = {||
      let duration = if $env.CMD_DURATION_MS == '0823' { 0 } else { $env.CMD_DURATION_MS }
      let args = [--cmd-duration $duration $"--status=($env.LAST_EXIT_CODE)" --terminal-width (term size).columns]
      let jobs = if (which 'job list' | where type == built-in | is-not-empty) { [--jobs (job list | length)] } else { [] }
      let full = (^starship prompt ...$args ...$jobs)
      let leading = if ($full | str starts-with "\n") { "\n" } else { '' }
      let body = if $leading == '' { $full } else { $full | str substring 1.. }
      let lines = ($body | split row "\n")
      if ($lines | length) < 2 { return $full }

      let bar = ($lines | drop 1 | str join "\n")
      let prompt = ($lines | last)
      let update = (^statusbar set 3 -- $bar | complete)
      if $update.exit_code != 0 { return $full }
      $"($leading)($prompt)"
    }

    $env.PROMPT_COMMAND_RIGHT = {||
      let duration = if $env.CMD_DURATION_MS == '0823' { 0 } else { $env.CMD_DURATION_MS }
      let args = [--right --cmd-duration $duration $"--status=($env.LAST_EXIT_CODE)" --terminal-width (term size).columns]
      let jobs = if (which 'job list' | where type == built-in | is-not-empty) { [--jobs (job list | length)] } else { [] }
      ^starship prompt ...$args ...$jobs
    }
  }
}
