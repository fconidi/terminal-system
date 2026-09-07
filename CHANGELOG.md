# Changelog

All notable changes to this project are documented in this file.
Format based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [1.1.1] - 2026-09-07

### Fixed
- Package description and script header comments still said "pane"
  while the man page, `--help` text, and bundled doc README already
  used "panel" for the terminal-system UI concept; made consistent.

## [1.1.0] - 2026-09-07

### Added
- Application icon and "SysLinuxOS Tools" menu entry.
- Up/down arrow history recall in the `ts-brain` instruction prompt.
- Mouse scrolling in both tmux panels; ran/cancelled commands are logged
  to session history.

### Fixed
- Mouse-drag copy-mode selection never reached the system clipboard on
  VTE-based terminals (no OSC 52 fallback); mouse-drag selection is now
  piped to `xclip` explicitly (new `xclip` dependency).
- `codex exec` refused to run when launched from a directory that isn't
  a trusted or git-tracked project; added `--skip-git-repo-check`.
- Command-concatenation race when multiple generated commands were
  typed into the left panel in quick succession.
- `postinst` read the wrong package version.

## [1.0.0] - 2026-09-06

Initial release.

### Added
- `terminal-system` tmux launcher: two-panel session, left panel a normal
  shell, right panel running `ts-brain`.
- `ts-brain` instruction REPL: natural-language instructions translated
  into shell commands via Claude Code or Codex, called non-interactively
  with no tool access.
- Manual confirmation on every generated command (run / edit / cancel),
  with an opt-in `:auto on` mode.
- Fixed danger-pattern guardrail that always forces manual confirmation
  for destructive commands, regardless of auto-mode.
- Automatic focus handoff to the left panel for commands likely to need
  interactive input (`sudo`, `ssh`, `passwd`, editors, pagers).
- In-memory session history and prompt builder (nothing persisted to
  disk).
- Debian packaging (`build-deb.sh`, `.deb` layout, man page).
- Test suite: library unit tests, tmux helper tests, launcher smoke
  test, and an end-to-end `ts-brain` test, all running against stubbed
  AI engines with no live tmux display required.
