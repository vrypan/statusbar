#!/bin/sh
printf "#[fg=#45475a]%${STATUSBAR_COLUMNS}s\n" '' | sed 's/ /─/g'
printf ' #[fg=#89b4fa,bold]%s#[default] #[fg=#7f849c]·#[default] %s\t#[italics]main#[default]\t%s  #[bold]%s#[default] \n' \
  "$(hostname -s)" "$(sysctl -n vm.loadavg | awk '{print $2}')" "$(date '+%a %d %b')" "$(date +%H:%M:%S)"
