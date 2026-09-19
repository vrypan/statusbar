Output demo/demo-1.gif

Require statusbar

Set Shell "zsh"
Set Width 1200
Set Height 700
Set FontSize 20
Set Framerate 60
Set TypingSpeed 50ms
Set CursorBlink false

# Start in ~/Devel/statusbar
Hide
Type "cd ~/Devel/statusbar && clear"
Enter
Show

# Initial prompt
Sleep 1300ms

# Start statusbar
Type "statusbar -c samples/default.config"
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

# Clean up — dirty marker disappears
Type "rm test"
Sleep 300ms
Enter
Sleep 2200ms

# Override the right side
Type `statusbar set 4 'Hello world!'`
Sleep 300ms
Enter
Sleep 2200ms

Type `statusbar set 4 '#[fg=green,bold]Hello, green world!'`
Sleep 300ms
Enter
Sleep 2200ms

# Restore the configured right side
Type `statusbar set 4 ""`
Sleep 300ms
Enter
Sleep 2600ms

Type "exit"
Sleep 300ms
Enter
Sleep 2200ms

Type "statusbar -c samples/themes/gruvbox.config"
Sleep 300ms
Enter
Sleep 2200ms

Type "exit"
Sleep 300ms
Enter
Sleep 2200ms

Type "statusbar -c samples/themes/pastel-powerline.config"
Sleep 300ms
Enter
Sleep 2200ms

Type "exit"
Sleep 300ms
Enter
Sleep 2200ms

Type "statusbar -c samples/themes/pure.config"
Sleep 300ms
Enter
Sleep 2200ms

Type "exit"
Sleep 300ms
Enter
Sleep 2200ms

Type "statusbar -c samples/themes/tokyo-night.config"
Sleep 300ms
Enter
Sleep 2200ms

Type "exit"
Sleep 300ms
Enter
Sleep 2200ms

Type "statusbar -c samples/themes/multi-line.config"
Sleep 300ms
Enter
Sleep 2200ms

Type "exit"
Sleep 300ms
Enter
Sleep 2200ms
