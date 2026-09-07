# Changelog

All notable changes to this project are documented in this file.
Format based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [1.1.5] - 2026-09-07

### Security
- Auto-mode's dangerous-command denylist was trivially bypassable
  (`/bin/rm -rf /`, `bash -c 'rm -rf /'`, `echo safe; /bin/rm -rf /`,
  `find / -delete`, `wipefs -a /dev/sda`, `echo broken > /etc/passwd`,
  `chmod -R 000 /`, `curl URL | sh` all skipped confirmation). Replaced
  with an allowlist: auto-mode now only skips confirmation for a fixed
  set of read-only programs (`ls`, `cat`, `grep`, `ps`, `git
  status/log/diff`, `systemctl status`, `journalctl`, `dpkg -l`, `apt
  list/search/show`, and similar) that also contain none of the shell
  metacharacters that could smuggle something else in (redirects,
  pipes, backticks, `$()`, `;`, `&`). `:auto on` is now an alias for
  the new `:auto readonly`.
- Left-panel output was always kept as AI context and sent, unredacted,
  in follow-up prompts. Now off by default; `:context
  on|off|show|clear` opts in, and stored output is scanned for common
  secret patterns (passwords, tokens, API keys, Bearer headers,
  AWS/GitHub/Slack/OpenAI-style key prefixes) first, on a best-effort
  basis.
- terminal-system now runs on its own dedicated tmux server (`tmux
  -L`) instead of the user's default one, so its copy-mode mouse-drag
  key bindings can no longer leak into the user's other tmux sessions.

### Changed
- `ts_wait_pane_idle` now requires two consecutive idle samples 100ms
  apart instead of one -- cheap insurance against a theoretical race
  in the pane-idle-detection polling that 5/5 empirical trials against
  a real tmux server didn't reproduce.
- `chmod -R <mode> /` is flagged as dangerous for any mode, not just
  the exact value 777.
- `xclip` moved from `Depends` to `Recommends`, matching the code
  (already optional via `command -v xclip`).

### Fixed
- Man page said "terminal-system 1.1.0" and was missing a date update;
  `TS_CLAUDE_MODEL`/`TS_CODEX_MODEL` are now documented.
- `Comment[it]` in the desktop file was still in English.

## [1.1.3] - 2026-09-07

### Changed
- Pane typing now sends 6-character chunks per `tmux send-keys` call
  instead of one call per character -- ~6x fewer subprocess spawns.
  Measured: 0.664s -> 0.377s to type a 67-character command (avg of 5
  runs).
- AI engine model is now overridable via `TS_CLAUDE_MODEL` /
  `TS_CODEX_MODEL` env vars (unset by default, same behavior as
  before). Tried defaulting Claude to `haiku` on the assumption that a
  lighter model would be faster for the simple instruction-to-command
  translation task; measured it was actually slower (15.18s avg vs
  10.86s avg for the CLI's own default, 5+5 interleaved runs), so left
  the default unset.

### Fixed
- `tmux send-keys -l` silently drops an unescaped `;` when it is the
  last character of the argument (verified on live tmux; a `;`
  embedded elsewhere in the argument is always safe). The old
  one-character-per-call typing loop dodged this by accident; batching
  into multi-character chunks exposed it. Now only a chunk-trailing
  `;` gets the `\;` escape.

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
