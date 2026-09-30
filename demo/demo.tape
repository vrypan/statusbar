# Capture frames for encoding with ffmpeg, as in tests/demo.tape.
Output demo/demo-frames/

Require statusbar

Set Shell "zsh"
Set Theme { "background": "#000000" }
Set Width 2400
Set Height 1400
Set FontSize 40
Set Framerate 60
Set TypingSpeed 20ms
Set CursorBlink false



# Start in ~/Devel/statusbar
Hide
Type "cd ~/Devel/statusbar && clear"
Enter
Show

# Initial prompt
Sleep 1300ms

# Start statusbar
Type "statusbar -c samples/default.statusbar"
Sleep 300ms
Enter
Sleep 1900ms

# Clear the terminal
Type "clear"
Sleep 300ms
Enter
Sleep 1300ms

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

# Set the prompt line's value
Type `statusbar set prompt 'Hello world!'`
Sleep 300ms
Enter
Sleep 2200ms

Type `statusbar set prompt "$(printf '\e[1;32mHello, green world!')"`
Sleep 300ms
Enter
Sleep 2200ms

# Restore the configured default
Type `statusbar set prompt --reset`
Sleep 300ms
Enter
Sleep 2600ms

Type "exit"
Sleep 300ms
Enter
Sleep 2200ms

Type "statusbar -c samples/themes/gruvbox.statusbar -- zsh -f"
Sleep 300ms
Enter
Sleep 2200ms

Type "exit"
Sleep 300ms
Enter
Sleep 2200ms

Type "statusbar -c samples/themes/pastel-powerline.statusbar -- zsh -f"
Sleep 300ms
Enter
Sleep 2200ms

Type "exit"
Sleep 300ms
Enter
Sleep 2200ms

Type "statusbar -c samples/themes/pure.statusbar -- zsh -f"
Sleep 300ms
Enter
Sleep 2200ms

Type "exit"
Sleep 300ms
Enter
Sleep 2200ms

Type "statusbar -c samples/themes/tokyo-night.statusbar -- zsh -f"
Sleep 300ms
Enter
Sleep 2200ms

Type "exit"
Sleep 300ms
Enter
Sleep 2200ms

Type "statusbar -c samples/themes/multi-line.statusbar -- zsh -f"
Sleep 300ms
Enter
Sleep 2200ms

Type "exit"
Sleep 300ms
Enter
Sleep 2200ms
