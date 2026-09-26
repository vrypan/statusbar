# Capture frames for encoding with ffmpeg, as in tests/demo.tape.
Output demo/push-frames/

Require statusbar
Require zig
Require curl

Set Shell "zsh"
Set Theme { "background": "#000000" }
Set Width 2400
Set Height 1400
Set FontSize 40
Set Framerate 60
Set TypingSpeed 20ms
Set CursorBlink false

# Start in the repository with the Gruvbox theme's pushed-line spinner.
Hide
Type "setopt interactive_comments && cd ~/Devel/statusbar && clear"
Enter
Show
Sleep 1300ms

Type "statusbar -c samples/themes/gruvbox.config -- zsh"
Sleep 300ms
Enter
Sleep 1000ms

# Start three overlapping tasks. The failure takes 30 seconds; the benchmark
# usually takes about 18 seconds. Curl stays active through the final pop.
Type `statusbar push -t "failure test" -- sh -c 'sleep 20; exit 7' &`
Sleep 300ms
Enter
Sleep 1200ms

Type `statusbar push -t 100mb.dat -- curl --progress-bar --limit-rate 10M -o /dev/null https://proof.ovh.net/files/100Mb.dat 2>&1 &`
Sleep 300ms
Enter
Sleep 500ms

Type "statusbar push -t bench -- zig build bench --color off --summary line &"
Sleep 300ms
Enter
Sleep 1800ms

# Show that ordinary shell and Git activity continues while push lines run.
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
Type "statusbar pop -a"
Sleep 300ms
Enter
Sleep 2200ms
