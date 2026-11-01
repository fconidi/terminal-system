# terminal-system

AI-assisted two-panel terminal for tmux. The left panel is a normal shell;
the right panel takes instructions in natural language, and an AI engine
(Claude Code or Codex, called non-interactively with no tool access of
its own) translates each instruction into shell command(s), which are
typed into the left panel in real time for you to review and confirm.

```
> list files larger than 100MB in this directory
-> ran: find . -maxdepth 1 -type f -size +100M -exec ls -lh {} \;
```

## How it works

- `terminal-system [claude|codex]` opens a tmux session with two panels.
- The right panel runs `ts-brain`, an instruction REPL. Each line you
  type is sent to the AI engine along with recent session history for
  context; the reply is parsed into one or more shell commands.
- Each command is typed into the left panel and, by default, waits for
  manual confirmation (Enter to run, `e` to edit, `?` to explain, `n` to cancel).
- An opt-in auto-mode (`:auto readonly`) executes a command without
  asking only if it passes two checks: its first word is a known
  read-only program (`ls`, `cat`, `grep`, `ps`, `git status/log/diff`,
  `systemctl status`, `journalctl`, `dpkg -l`, `apt list/search/show`,
  and similar), and it contains none of the shell metacharacters that
  could turn a read-only command into something else (redirects,
  pipes, backticks, `$()`, `;`, `&`). A fixed set of always-dangerous
  patterns — destructive `rm`, `mkfs`, `dd` onto a device, fork bombs,
  any recursive `chmod` on `/`, `shutdown`/`reboot`, `killall -9`,
  `userdel`/`groupdel` on root/sudo/admin accounts, `iptables -F`,
  writes onto common block devices under `/dev` — is checked as a
  second layer. Anything not explicitly recognized as safe always
  stops for confirmation, even in auto-mode.
- When a command is likely to need input (`sudo`, `ssh`, `passwd`, an
  editor, a pager), focus moves to the left panel so prompts are answered
  in the shell that's actually running the command, then moves back.
- Session instructions and command history are kept in memory only if
  `:context on` is used (off by default); recent left-panel output is
  scanned for common secret patterns before being stored, on a
  best-effort basis. Nothing is written to disk either way.
- terminal-system runs on its own dedicated tmux server (`tmux -L`),
  separate from any other tmux session you have open, so its
  mouse/copy-paste key bindings don't leak into your other sessions.
- Every instruction is sent together with a short description of the
  left panel: distribution, user, working directory, git branch, shell,
  and the foreground program if it is not a plain shell (e.g. `ssh`).
  This lets the AI pick the right package manager and paths. It never
  includes terminal output.
- After each command, its exit status is shown. When a command fails,
  `:fix` sends the command, its exit status and the last 30 lines of
  the left panel (secrets redacted, best effort) to the AI, which
  prints the likely cause and proposes a fix. The fix always asks for
  confirmation, even in auto-mode. `:fix on` does this automatically
  after every failure; it is off by default, so nothing is sent unless
  you ask.
- `:follow <goal>` runs a closed loop: the AI proposes a step, it runs
  in the left panel as usual (confirmation, or the read-only auto-mode),
  the output (secrets redacted) goes back to the AI and the next step is
  proposed. It stops on `DONE`, when you cancel a step, when the same
  step comes back twice, or after 5 steps.
- `:watch on` opens a small observer panel under the instruction panel.
  When the left panel's output settles (2 s quiet, at most one request
  every 10 s) and looks like an error, the recent output (secrets
  redacted) is sent to the AI and the advice is printed there. It never
  types anything. `:watch all` asks after every change instead of only
  on errors; `:watch off` closes it. Off by default.
- The AI answers in a structured form: each command comes with a
  one-line explanation and a risk level (low / medium / high). Both are
  shown in the confirmation step, `?` there asks the AI to explain the
  command in more detail, and a command the AI rates `high` always asks
  for confirmation, even in auto-mode. Long commands are no longer
  rejected by a word limit. Without `python3`, or if the reply is plain
  text, the previous line-per-command handling is used.
- If a command stops at a prompt in the left panel (a yes/no question,
  a password or passphrase, "Continue?", a pager), focus moves there so
  you can answer it, and returns to the instruction panel afterwards.
  This is detected from what is on screen, not from the command name.
- Long commands no longer stop the batch after 120 s: the instruction
  panel prints a "still running" line now and then, rings the bell and
  shows a tmux message when a command that ran 15 s or more finishes,
  and Ctrl-C there stops waiting (the command keeps running).
- `:watch` asks for a one-time acknowledgement before it first sends
  output to the AI provider. F9 (or `:watch pause`) stops it from
  reading anything; F10 (or `:watch resume`) continues. Output produced
  while paused is never sent afterwards.
- The AI model used for translation can be overridden with
  `TS_CLAUDE_MODEL` / `TS_CODEX_MODEL` (unset by default, which uses
  each CLI's own default model).

Right-panel commands: `:cmd <command>` (run manually, skip the AI),
`:manual` (prompt for a manual command), `:auto readonly|off`,
`:context on|off|show|clear`, `:fix [on|off]`, `:follow <goal>`, `:watch on|all|off|pause|resume`, `:engine claude|codex`, `:quit`. Full
details in `man/terminal-system.1`.

## Requirements

- `bash`, `tmux`, `xclip` (clipboard support for mouse-drag copy)
- The `claude` and/or `codex` CLI, installed and already authenticated.
  Neither is a hard package dependency since neither ships as a `.deb`
  on Debian/Ubuntu.

## Install

### Debian / Ubuntu — build the .deb

```bash
git clone https://github.com/fconidi/terminal-system.git
cd terminal-system
bash build-deb.sh
sudo apt install ./terminal-system_*_all.deb
```

### SysLinuxOS

Already packaged in the SysLinuxOS APT repo:

```bash
echo "deb https://fconidi.github.io/SysLinuxOS-Tools tirreno main" | sudo tee /etc/apt/sources.list.d/syslinuxos-tools.list
wget -qO- https://fconidi.github.io/SysLinuxOS-Tools/syslinuxos-archive-keyring.asc | sudo tee /usr/share/keyrings/syslinuxos-archive-keyring.asc > /dev/null
sudo apt update && sudo apt install terminal-system
```

### Any other Linux — manual install

```bash
sudo install -Dm755 build/usr/bin/terminal-system /usr/local/bin/terminal-system
sudo install -Dm755 build/usr/bin/ts-brain /usr/local/bin/ts-brain
sudo install -Dm755 build/usr/bin/ts-watch /usr/local/bin/ts-watch
sudo install -Dm644 build/usr/lib/terminal-system/lib.sh /usr/local/lib/terminal-system/lib.sh
```

`ts-brain` looks for `lib.sh` next to itself first (`../lib/terminal-system/lib.sh`
relative to its own path), falling back to `/usr/lib/terminal-system/lib.sh`
— adjust the paths above to match if you install outside `/usr/local`.

## License

MIT — see [LICENSE](LICENSE).
