# Run from the statusbar repository: vhs demo/downloads.tape
# Encode afterward: demo/encode.sh demo/downloads-frames/
# Or make a GIF: demo/encode-gif.sh demo/downloads-frames/
# Downloads remain in the temporary directory printed during the demo.
Output demo/downloads-frames/

Require statusbar
Require yt-dlp
Require ffmpeg
Require git

Set Shell "zsh"
Set Theme { "background": "#000000" }
Set Width 2400
Set Height 1400
Set FontSize 32
Set Framerate 60
Set TypingSpeed 20ms
Set CursorBlink false

# Remember the repository across directory changes.
Hide
Type `alias sb=statusbar; export STATUSBAR_DEMO_REPO="$PWD"; clear`
Enter
Show
Sleep 1300ms

Type "sb"
Sleep 300ms
Enter
Sleep 1000ms

# Ensure the sb and + shortcuts are available in the session.
Hide
Type `eval "$(statusbar init zsh --starship=false --report-cwd=false)"; clear`
Enter
Show
Sleep 1000ms

Type `downloads_dir=$(mktemp -d); cd "$downloads_dir"`
Sleep 300ms
Enter
Sleep 1000ms

Type `+ yt-dlp -o "cc-attribution.%(ext)s" "https://www.youtube.com/watch?v=CZ2qJVQc5as"`
Sleep 300ms
Enter
Sleep 1000ms

Type `+ yt-dlp -o "cc-ethics.%(ext)s" "https://www.youtube.com/watch?v=p6egx-F-Nmk"`
Sleep 300ms
Enter
Sleep 1800ms

# Show partial files while both commands run in the background.
Type "ls -la"
Sleep 300ms
Enter
Sleep 1800ms

# Live theme replacement keeps the temporary lines and their running commands.
Type `sb config load "$STATUSBAR_DEMO_REPO/samples/themes/gruvbox-color.stbt"`
Sleep 300ms
Enter
Sleep 2200ms

Type `sb config load "$STATUSBAR_DEMO_REPO/samples/themes/tokyo-night-color.stbt"`
Sleep 300ms
Enter
Sleep 2200ms

# The downloads keep their original working directory while the shell moves.
Type `cd "$STATUSBAR_DEMO_REPO"`
Sleep 300ms
Enter
Sleep 1000ms

Type "git --no-pager status --short"
Sleep 300ms
Enter
Sleep 1500ms

Type "git --no-pager log -3 --oneline"
Sleep 300ms
Enter
Sleep 1800ms

Type "sb list --temp"
Sleep 300ms
Enter
Sleep 1800ms

# Optional longer variant: launch another recording here with
# + vhs demo/push.tape
# It needs VHS and its capture dependencies.

Type `sb config load "$STATUSBAR_DEMO_REPO/samples/themes/pastel-powerline-color.stbt"`
Sleep 300ms
Enter
Sleep 2200ms

Type `cd "$downloads_dir"`
Sleep 300ms
Enter
Sleep 1000ms

# The downloads have finished by this point; show the completed files.
Type "ls -la"
Sleep 300ms
Enter
Sleep 2200ms

# Remove the newest temporary line.
Type "sb remove"
Sleep 300ms
Enter
Sleep 1000ms

Type "sb remove"
Sleep 300ms
Enter
Sleep 2200ms

Type "exit"
Sleep 300ms
Enter
Sleep 1500ms
