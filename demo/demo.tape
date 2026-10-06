# Run from the statusbar repository: vhs demo/demo.tape
# Encode afterward: demo/encode.sh demo/demo-frames/
# Output demo/demo-frames/
Output demo/demo.mp4

Require statusbar

Set Shell "zsh"
Set Theme { "background": "#000000" }
Set Width 2400
Set Height 1400
Set FontSize 32
Set Framerate 60
Set TypingSpeed 20ms
Set CursorBlink false


# Start in ~/Devel/statusbar
Hide
Type "alias sb=statusbar; cd ~/Devel/statusbar && clear"
Enter
Hide
Type `eval "$(statusbar init zsh --starship=false --report-cwd=false)"; clear`
Enter
Show

# Initial prompt
Sleep 1300ms

Type "sb --help"
Sleep 300ms
Enter
Sleep 3000ms

# Start statusbar
Type "sb -c samples/default.stbt"
Sleep 300ms
Enter
Sleep 3000ms


# Create a dirty working tree
Type "ls -l"
Sleep 300ms
Enter
Sleep 1000ms

Type "touch test"
Sleep 300ms
Enter
Sleep 1500ms

# Clean up — dirty marker disappears
Type "rm test"
Sleep 300ms
Enter
Sleep 2200ms

# Move to tj — statusbar follows cwd/git state
Type "cd ../tj"
Sleep 300ms
Enter
Sleep 2100ms

# Return
Type "cd -"
Sleep 300ms
Enter
Sleep 2100ms

# Hold each value before the shell prompt hook overwrites it.
Type `sb update prompt 'Hello world!'; sleep 2`
Sleep 300ms
Enter
Sleep 2200ms

Type `sb update prompt "$(printf '\e[1;32mHello, green world!')"; sleep 2`
Sleep 300ms
Enter
Sleep 2200ms

# Restore the configured default
Type `sb update prompt --reset; sleep 2`
Sleep 300ms
Enter
Sleep 2600ms

Type "sb config load gruvbox-color"
Sleep 300ms
Enter
Sleep 2200ms

Type "sb config load pastel-powerline-color"
Sleep 300ms
Enter
Sleep 3200ms

Type "sb config load pure-color"
Sleep 300ms
Enter
Sleep 3200ms

Type "sb config load tokyo-night-color"
Sleep 300ms
Enter
Sleep 3200ms

Type "sb config load multi-line-color"
Sleep 300ms
Enter
Sleep 3200ms

Type "sb config load minimal"
Sleep 300ms
Enter
Sleep 3200ms

Type "sb config import compute"
Sleep 300ms
Enter
Sleep 2200ms

Type "sb config import disk"
Sleep 300ms
Enter
Sleep 2200ms

Type "sb config import battery"
Sleep 300ms
Enter
Sleep 2200ms

Type "sb config import network"
Sleep 300ms
Enter
Sleep 2200ms

Type "sb config import weather"
Sleep 300ms
Enter
Sleep 2200ms

Type "sb config import clock"
Sleep 300ms
Enter
Sleep 2200ms

Type "sb ls"
Sleep 300ms
Enter
Sleep 2200ms

Type "sb rm weather"
Sleep 300ms
Enter
Sleep 2200ms

Type "sb rm clock"
Sleep 300ms
Enter
Sleep 2200ms

Type "sb rm network"
Sleep 300ms
Enter
Sleep 2200ms

Type "sb rm disk"
Sleep 300ms
Enter
Sleep 2200ms

Type "sb rm battery"
Sleep 300ms
Enter
Sleep 2200ms
