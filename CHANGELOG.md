# Changelog

Changes are grouped by version, newest first. Each section summarizes changes
since the previous version. Within each release, changes are listed in the
order they were added.

## Unreleased

- **Breaking:** use `default.stbt` as the startup config filename. Search the
  user config directory for themes and modules before bundled directories;
  warn about old `config.statusbar` and `config` startup files

- Let `config load FILE` also try `FILE.stbt` and `config import FILE` try
  `FILE.stbm`; bare names search the user config directory, then compiled-in
  default directories after local files. Share `-Ddefault-themes-dir` with the
  picker and add `-Ddefault-modules-dir`; configure both for Homebrew

- **Breaking:** use `.stbt` for themes and complete samples, and `.stbm` for
  module fragments. Update theme discovery, bundled files, packaging and
  examples; the startup filename is `default.stbt`, and explicit
  config paths still accept any extension

- **Breaking:** rename `set` to `update` (`upd`), `push` to `new`, and `pop`
  to `remove` (`rm`)
- Make `remove NAME` remove a standalone line or an entire group, including
  configured lines, commands, colors and temporary lines; an ID for a dotted
  line selects its whole group. No target removes the newest temporary line;
  `--all` removes only temporary lines
- Generate `tmp-ID` names for `new` without a name; add `--prefix` (`-p`)
- Add `list [--temp] [--json]` (`ls`) to inspect session lines, including hidden
  lines, with stable IDs, access modes, statuses, raw values and FIFO paths
- **Breaking:** replace config flags with `show`, `path`, `check`, `load`,
  and `import` subcommands. `config show [current|startup|default]` prints
  source text; `config path` prints the selected startup path. Keep
  `config < FILE` as a shorthand for loading stdin
- Add `config show [current|startup|default] --json` to inspect full parsed
  definitions, effective settings and compiled templates without running commands
- Add `config import FILE` for atomic additions of lines, commands and colors,
  accepting mixed prefixes and unprefixed definitions while preserving existing
  line state and running commands. Imports preserve source text without
  placeholder substitution
- Check dependencies during removal and preserve surviving lines, bindings
  and command processes
- Use `module.name` for module lines, commands and colors; support dotted
  names in `update`, `new` and FIFO bindings. Reserve group prefixes so they
  cannot collide with standalone line names or be all digits
- Bundle eleven modules using terminal-native colors, with setup instructions,
  platform requirements and checks for theme composition
- Add a Codex usage module with a usage meter, reset countdown, credits,
  available resets and lifetime token totals
- Make bundled module displays defaults, so `update` and FIFO values override
  them and `update --reset` restores their live content
- Group bundled config and theme commands under prefixes such as `system.*`,
  `hn.*` and `gh.*`
- Use terminal-native colors by default and a shared style for native themes
  and modules: muted bold labels, regular-weight values, dim dotted fills and
  colored status indicators
- **Breaking:** replace `*-native.statusbar` theme files with
  `*-color.statusbar` variants preserving the original Starship-inspired colors
  and layouts; unsuffixed theme files now use terminal colors
- Define `+ [+NAME] COMMAND` in Zsh and Fish integration for background
  statusbar jobs, generating `COMMAND-ID` names when no name is supplied;
  preserve existing `+` commands and offer `init --no-plus` to skip the shortcut
- Define `sb` as an alias for `statusbar` during shell initialization;
  preserve existing `sb` commands and offer `init --no-sb-alias` to skip it
- Add a concurrent-download demo showing the `+` shortcut, live color-theme
  changes and temporary-line cleanup

## v0.5.1

- Update VHS demos for named lines and keep example values visible before
  shell prompt hooks overwrite them
- Prevent background `push` jobs from suspending on terminal access: skip
  terminal result output and replace inherited terminal stdin with `/dev/null`
- Expand configured `default` templates at `#(value)` until a value is set,
  support `default .=`, and restore the live fallback with `--reset`;
  escape literal `#` in defaults with `##`
- Use styled user/host/load fallbacks in the built-in config and Gruvbox,
  Pastel Powerline, Pure, and Tokyo Night themes; reset value styles before
  the fill and right-side content

## v0.5.0

- Add on-demand named FIFOs for configured slots and pushed rows
- Add `#(datetime:FORMAT)` and terminal size properties to templates
- Update bundled themes to use `#(datetime:FORMAT)`
- **Breaking:** replace numbered slots with named lines. `[line.NAME]`
  sections appear in declaration order, each with one `text` template;
  `#(fill:PATTERN)` replaces `left`, `right` and `rule`, and inline `#[...]`
  styles replace line `style` keys. See docs/migration.md
- Give every line a value (`#(value)`, `default`) and a status (`normal`,
  `running`, `done`, `success`, `failed`) that selects same-section status
  templates; `[push]` replaces the `[line.push*]` sections
- Append to templates with `KEY .= FRAGMENT`, without the old 32-part limit
- Require explicit expressions: `#(command:NAME)` for named commands, with no
  inline shell commands; `%` is literal outside `#(datetime:...)`; remove
  `#(tag)`, `#(id)`, `#(stream)`, `#(exit_code)` and `#(signal)` in favor of
  `#(name)`, `#(value)` and `#(status)`
- Display values, defaults and command output literally, keeping ANSI colors
  and OSC 8 links
- Replace `set SLOT` with `set NAME [TEXT...] [--status STATE] [--reset]`,
  sent over the authenticated control socket; drop the OSC slot variables
- Name pushed lines with `push [NAME]`, print the name at EOF, derive
  success or failed from a command's result, and address lines by name or ID
- Replace `fifo` with `bind [-u] NAME` and `push NAME --fifo`; rename
  `STATUSBAR_SLOTS` to `STATUSBAR_FIFOS`
- Keep configured lines' values, statuses and IDs by name across config
  replacement, and prune the FIFOs of removed lines
- Rename `init --starship-slot N` to `--starship-line NAME`, defaulting to the
  `prompt` line
- Rename shipped configs and themes to `.statusbar`; load
  `config.statusbar` by default and warn about an old `config` file
- Start the shell with the built-in config and a warning line when the
  startup config is missing, unreadable or invalid
- Add `#(env:NAME)` to show an environment variable in templates

## v0.4.3

- Add a packaged guide for AI agents setting up statusbar and custom themes

## v0.4.2

- Add terminal-palette variants of all six sample themes
- Add `statusbar-theme DIRECTORY`, an interactive theme picker using zooi
- Bundle sample themes in release archives and Homebrew installations
- Default the Homebrew theme picker to its bundled theme directory
- Show a command to save the selected theme when the picker exits after a change
- Keep the closed-stdout deadline test reliable under slow CI scheduling

## v0.4.1

- Expose command exit status and signal number in pushed-line templates
- Add completion layouts for pushed lines, with inherited done, success, and failed settings
- Add Unicode spinners for pushed lines, with configurable timing and stable frame widths
- Add `pop --all` (`-a`) to remove all pushed lines at once

## v0.4.0

- Document how I use statusbar
- Use session state for shell integration detection
- Remove the stale `STATUSBAR_LINES` variable and require session state for `set`
- Make `push` the streaming command and keep `set` for direct slot updates
- Use zunic for UTF-8 iteration and decoding where it simplifies text handling
- Split CLI, proxy, and renderer code into layer modules; share parsing and row composition code
- Fix quoted config header detection and resolve config paths without parsing their contents
- Reject C1 controls in directory titles and keep markup escaped after incomplete OSC sequences
- Map pixel mouse reports to the child's pixel height
- Repaint after selective erase and keep oversized CSI sequences out of the bar
- Validate pushed-row socket senders and centralize request and reply handling
- Keep push and pop responsive when a child leaves its cursor saved
- Update pushed streams without reformatting every bar row
- Make pushed-row slots and styling configurable with templates for stream text, tag, and ID
- Add dynamic pushed rows with command streaming, tags, stable IDs, and optional latest-row pop

## v0.3.1

- Remove nbsp from config that broke formatting
- Remove the Ctrl-X Ctrl-R config path editor
- Wake the loop on SIGCHLD to reap finished commands
- Clamp mouse motion and releases on the bar to the child
- Hold config requests while the child's cursor is saved
- End the session when the child exits
- Remove unused code
- Drain PTY while reaping integration test sessions
- Add Nushell integration sample
- Update README
- Avoid rerunning status commands on height-only resizes
- Stop idle clock work for overridden slots and literal percents
- Reuse highlight color samples across matching glyphs
- Preserve highlight preparation across untracked row updates
- Clarify command help and add practical examples
- Document XDG configuration path lookup accurately
- Support stdin configs and remove exec-mode flags
- Use Zig APIs for I/O, pipes, and system queries
- Add startup and current config snapshots to config printing
- Clarify config help and present print choices consistently
- Upgrade zecli to 0.4.4
- Bump version to 0.3.1

## v0.3.0

- Replace configuration from an in-session path editor
- Upgrade zecli to 0.4.3
- Style help output and refresh the description
- Add optional runtime logging with run --log
- Add OSC config replacement
- Add minimal statusbar theme
- Fix config replacement ordering and OSC recovery
- Restructure config command around stdin and explicit printing

## v0.2.3

- Set terminal titles from OSC 7 directories
- Add configurable shell hooks and shorten directory titles
- Bump v0.2.3

## v0.2.2

- Keep shell integrations valid across upgrades
- Bump v0.2.2

## v0.2.1

- Ignore f#@&%n .DS_Store
- Track styled grapheme cells and repaint only changed statusbar rows
- Highlight slots when tracked command output changes
- Coordinate statusbar frames and change effects
- Highlight independently tracked template regions
- Animate tracked regions using terminal-aware color ranges
- Gate releases on PTY tests and benchmark highlight scaling
- Simplify adaptive highlighting and remove stale render state
- Prepare highlights and streamline statusbar updates
- Bump v0.2.1

## v0.2.0

- Contribution guidelines
- Add Starship-inspired status bar themes
- Support configured rows and numbered slots
- Validate slot metadata and preserve padding
- Add user guide and rounded Gruvbox theme
- Support block values in configuration
- Add Fish Starship integration
- Improved docs
- Added demo
- Bump v0.2.0

## v0.1.0

- Add statusbar, a PTY proxy with a status bar above the child
- Add bar slots and tmux-style style markup
- Move the bar to the bottom by default
- Add an example bar script with a thin rule above the status line
- Add a config file with templates, named colors and per-command intervals
- Let programs set the bar's slots with statusbar set
- Add statusbar init zsh for starship prompts
- Move documentation details from the README into docs/
- Build in the sample config and always keep the bar at the bottom
- Describe the command line with zecli
- Add statusbar config to print and check the configuration
- Upgrade zecli to 0.4.1
- Add screenshot to README
- Cut the translator's cost per byte of output
- Bound terminal input sequences
- Validate bar escape sequences
- Preserve terminal input at CSI boundaries
- Validate bar styling escape sequences
- Handle empty benchmark writes
- Preserve output boundaries before repainting
- Enforce status command lifetime deadlines
- Add MIT license
- Add release and Homebrew workflows
