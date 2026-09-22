# Changelog

Changes are grouped by version tag, newest first. `dev` contains commits
since the latest version tag. Entries preserve commit subjects verbatim.

## v0.3.0

- Restructure config command around stdin and explicit printing
- Fix config replacement ordering and OSC recovery
- Add minimal statusbar theme
- Add OSC config replacement
- Add optional runtime logging with run --log
- Style help output and refresh the description
- Upgrade zecli to 0.4.3
- Replace configuration from an in-session path editor

## v0.2.3

- Bump v0.2.3
- Add configurable shell hooks and shorten directory titles
- Set terminal titles from OSC 7 directories

## v0.2.2

- Bump v0.2.2
- Keep shell integrations valid across upgrades

## v0.2.1

- Bump v0.2.1
- Prepare highlights and streamline statusbar updates
- Simplify adaptive highlighting and remove stale render state
- Gate releases on PTY tests and benchmark highlight scaling
- Animate tracked regions using terminal-aware color ranges
- Highlight independently tracked template regions
- Coordinate statusbar frames and change effects
- Highlight slots when tracked command output changes
- Track styled grapheme cells and repaint only changed statusbar rows
- Ignore f#@&%n .DS_Store

## v0.2.0

- Bump v0.2.0
- Added demo
- Improved docs
- Add Fish Starship integration
- Support block values in configuration
- Add user guide and rounded Gruvbox theme
- Validate slot metadata and preserve padding
- Support configured rows and numbered slots
- Add Starship-inspired status bar themes
- Contribution guidelines

## v0.1.0

- Add release and Homebrew workflows
- Add MIT license
- Enforce status command lifetime deadlines
- Preserve output boundaries before repainting
- Handle empty benchmark writes
- Validate bar styling escape sequences
- Preserve terminal input at CSI boundaries
- Validate bar escape sequences
- Bound terminal input sequences
- Cut the translator's cost per byte of output
- Add screenshot to README
- Upgrade zecli to 0.4.1
- Add statusbar config to print and check the configuration
- Describe the command line with zecli
- Build in the sample config and always keep the bar at the bottom
- Move documentation details from the README into docs/
- Add statusbar init zsh for starship prompts
- Let programs set the bar's slots with statusbar set
- Add a config file with templates, named colors and per-command intervals
- Add an example bar script with a thin rule above the status line
- Move the bar to the bottom by default
- Add bar slots and tmux-style style markup
- Add statusbar, a PTY proxy with a status bar above the child
