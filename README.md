# terminal-system

AI-assisted two-pane terminal for tmux. The left pane is a normal shell;
the right pane takes instructions in natural language, and an AI engine
(Claude Code or Codex, called non-interactively with no tool access of
its own) translates each instruction into shell command(s), which are
typed into the left pane in real time for you to review and confirm.

```
> list files larger than 100MB in this directory
-> ran: find . -maxdepth 1 -type f -size +100M -exec ls -lh {} \;
```

## How it works

- `terminal-system [claude|codex]` opens a tmux session with two panes.
- The right pane runs `ts-brain`, an instruction REPL. Each line you
  type is sent to the AI engine along with recent session history for
  context; the reply is parsed into one or more shell commands.
- Each command is typed into the left pane and, by default, waits for
  manual confirmation (Enter to run, `e` to edit, `n` to cancel).
- An opt-in auto-mode (`:auto on`) executes safe commands automatically.
  A fixed set of dangerous patterns — destructive `rm`, `mkfs`, `dd`
  onto a device, fork bombs, `chmod -R 777 /`, `shutdown`/`reboot`,
  `killall -9`, `userdel`/`groupdel` on root/sudo/admin accounts,
  `iptables -F`, writes onto common block devices under `/dev` — always
  forces manual confirmation regardless of auto-mode.
- When a command is likely to need input (`sudo`, `ssh`, `passwd`, an
  editor, a pager), focus moves to the left pane so prompts are answered
  in the shell that's actually running the command, then moves back.
- Session instructions and command history are kept in memory for the
  current tmux session only — nothing is written to disk.

Right-pane commands: `:cmd <command>` (run manually, skip the AI),
`:manual` (prompt for a manual command), `:auto on|off`, `:engine
claude|codex`, `:quit`. Full details in `man/terminal-system.1`.

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
sudo install -Dm644 build/usr/lib/terminal-system/lib.sh /usr/local/lib/terminal-system/lib.sh
```

`ts-brain` looks for `lib.sh` next to itself first (`../lib/terminal-system/lib.sh`
relative to its own path), falling back to `/usr/lib/terminal-system/lib.sh`
— adjust the paths above to match if you install outside `/usr/local`.

## Testing

```bash
bash tests/test_lib.sh
bash tests/test_tmux_helpers.sh
bash tests/test_launcher_smoke.sh
bash tests/test_ts_brain_e2e.sh
```

No live tmux display or network access required; the AI engines are
replaced by stubs under `tests/stubs/`.

## License

MIT — see [LICENSE](LICENSE).
