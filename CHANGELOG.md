# Changelog

All notable changes to this project are documented in this file.
Format based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Added
- Support for `agy` (Antigravity CLI) as an AI engine alongside `claude` and `codex`.
- Support for `TS_AGY_MODEL` environment variable to override the model for `agy`.
- Engine switching and fallback support for `agy` (`terminal-system agy`, `:engine agy`).

## [1.2.1] - 2026-11-01

### Fixed
- Cancelling a command stops the remaining batch and ends the current `:follow` run.
- `:cmd` no longer reports a command as completed when waiting was interrupted or timed out.

## [1.2.0] - 2026-11-01

### Added
- Every instruction carries a short description of the left panel:
  distribution, user, working directory, git branch, shell, and the
  foreground program when it is not a plain shell (for example `ssh`).
  The model no longer has to guess the package manager or the path. No
  terminal output is part of it.
- The exit status of each command is reported (`-> ran: cmd (exit N)`).
  `:fix` diagnoses the last failed command from its exit status and the
  last 30 lines of output (secrets redacted, best effort), prints the
  likely cause and proposes a fix that always asks for confirmation,
  even in auto-mode. `:fix on` runs it automatically after every
  failure; default off. Ctrl-C and a plain "no match" from
  grep/diff/cmp/test are not treated as failures.
- `:follow <goal>`: closed loop in which each step's output is fed back
  to the AI to get the next step. Every step keeps the normal
  confirmation (or read-only auto-mode); it stops on DONE, a cancelled
  step, a repeated step, or after 5 steps.
- `:watch on|all|off|pause|resume`: an observer panel (`ts-watch`) that
  follows the left panel and prints advice when something goes wrong.
  It waits for the output to settle, skips full-screen programs, sends
  only secrets-redacted output, and never types anything. `on` asks the
  AI only when new output looks like an error; `all` asks after every
  change. A one-time notice about what is sent to the AI provider must
  be acknowledged. F9 / F10 (or `pause` / `resume`) stop and restart
  reading; output produced while paused is never sent.
- Structured AI replies: every command carries a short explanation and
  a risk level, shown in the confirmation step. `?` there asks the AI to
  explain the command. A command rated high, or matching the built-in
  dangerous patterns, always asks for confirmation, even in auto-mode,
  and needs a short code typed instead of Enter.
- `:explain` explains the last command and its output; `:explain
  <command>` explains a command without running it.
- Prompt detection: a yes/no question, password or passphrase prompt,
  "Continue?" or pager on the left panel's screen moves focus there and
  brings it back afterwards. Before, only the command name decided this.
- Long-running commands: "still running" status lines, a bell and a
  tmux message on completion of commands that ran 15 s or more, and
  Ctrl-C to stop waiting. `TS_STATUS_AFTER`, `TS_STATUS_EVERY`,
  `TS_NOTIFY_AFTER`, `TS_MAX_WAIT` adjust the timings.

### Changed
- The system prompt no longer assumes Debian/Ubuntu when the
  environment block says otherwise.
- Long commands are no longer rejected by the 12-word heuristic when the
  reply is structured. Plain-text replies (or a system without
  `python3`) still use the line-per-command parser.
- The 120-second limit that abandoned the rest of a batch is now 30
  minutes, and only after the status lines above have been shown.

## [1.1.9] - 2026-09-16

### Fixed
- The auto/confirm send path polled tmux's `pane_current_command` to
  decide a typed command had finished, but that reading can't tell
  "hasn't started yet" from "already finished" -- under real scheduling
  load, the next queued command could get typed while the previous
  one's Enter was still unprocessed, landing on the same open input
  line with no separator (e.g. `lscpu` + `free -h` glued into
  `lscpufree -h`, then executed as one broken command). Replaced the
  poll with an in-band completion marker: the auto path now types the
  command and its marker together in a single `send-keys` call, and the
  confirm path appends the marker onto the already-settled pending
  line. Removed the now-dead `ts_wait_pane_idle`/`ts_pane_shell_name`.

## [1.1.8] - 2026-09-15

### Security
- Auto-mode's read-only allowlist let `echo ${VAR:=word}` / `echo
  ${VAR=word}` and `printf -v VAR word` through as "safe": bash resolves
  the assignment as a side effect of expansion, so e.g. `echo
  ${PROMPT_COMMAND:=rm -rf /tmp/x}` set `PROMPT_COMMAND` and had it run
  unattended at the next shell prompt, fully bypassing confirmation.
  Both forms are now blocked; `printf -v` specifically is rejected,
  `history -w`/`-r` (arbitrary file write/read) also now rejected.
- `find` allowlist blocked `-fprintf` but not `-fprint`/`-fprint0`,
  which can also write matched paths to an arbitrary file. Blocked.
- The allowlist checked only the basename of the command, so
  `/tmp/evil/ls` or `./cat` ran as if they were the trusted system
  `ls`/`cat`. Now requires a bare, PATH-resolved command name.
- Removed `git log`/`diff`/`show` from the allowlist: any of the three
  can invoke a repo- or user-configured external pager, diff, or
  textconv filter.
- A literal CR or LF inside AI-generated output, typed into the pane
  before the confirm prompt is shown, could submit a partial command
  early (canonical tty line discipline ends a line on either). Both are
  now stripped before typing.
- The `rm`/`chmod` dangerous-command matcher missed absolute-path
  invocations (`/bin/rm -rf /`) and flags placed after the target
  (`rm -r / -f`); it now matches by basename and scans every token.

### Fixed
- `build-deb.sh`'s `DEBIAN/md5sums` generation used a sed pattern
  anchored to the start of the line, which never matched `md5sum`'s
  actual `hash  ./path` separator -- every recorded path kept a stray
  leading `./`. Fixed to match the real separator.
- The `terminal-system` binary's own `VERSION` string was hardcoded and
  had drifted to `1.1.3` while the package moved on to 1.1.7; `--version`
  and the startup banner showed the wrong version. `build-deb.sh` now
  syncs it from `DEBIAN/control` at build time.
- `mktemp` failure in `ts_call_engine`'s codex path was not checked.

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
- AI engine model is now overridable via `TS_CLAUDE_MODEL` /
  `TS_CODEX_MODEL` env vars (unset by default, same behavior as
  before).

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
