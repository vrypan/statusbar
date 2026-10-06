# Run from the statusbar repository: vhs demo/push.tape
# Encode afterward: demo/encode.sh demo/push-frames/
Output demo/push-frames/

Require statusbar
Require zig
Require curl

Set Shell "zsh"
Set Theme { "background": "#000000" }
Set Width 2400
Set Height 1400
Set FontSize 32
Set Framerate 60
Set TypingSpeed 20ms
Set CursorBlink false

# Start in the repository with the Gruvbox theme's temporary-line spinner.
Hide
Type "alias sb=statusbar; setopt interactive_comments && cd ~/Devel/statusbar && clear"
Enter
Show
Sleep 1300ms

Type "sb -c samples/themes/gruvbox-color.stbt -- zsh -f"
Sleep 300ms
Enter
Sleep 1000ms

# zsh -f skips startup files; enable sb and + explicitly.
Hide
Type `eval "$(statusbar init zsh --starship=false --report-cwd=false)"; clear`
Enter
Show

# Start three overlapping tasks. The failure takes 20 seconds; the benchmark
# usually takes about 18 seconds. Curl stays active through the final removal.
Type `+ sh -c 'sleep 20; exit 7'`
Sleep 300ms
Enter
Sleep 1200ms

Type `+ curl --progress-bar --limit-rate 5M -o /dev/null https://proof.ovh.net/files/100Mb.dat`
Sleep 300ms
Enter
Sleep 500ms

Type "+ zig build bench --color off --summary line"
Sleep 300ms
Enter
Sleep 1800ms

# Show that ordinary shell and Git activity continues while temporary lines run.
Type "cat demo/message.txt"
Sleep 300ms
Enter
Sleep 1800ms
Type "ls"
Sleep 300ms
Enter
Sleep 1000ms

# Leave the finished benchmark and failed command visible before clearing.
Sleep 18000ms
Type "clear"
Sleep 300ms
Enter
Sleep 500ms
Type "sb remove --all"
Sleep 300ms
Enter
Sleep 2200ms
