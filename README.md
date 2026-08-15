# systemd-claude-rc

Run [Claude Code](https://claude.ai/code) Remote Control (`claude rc`) instances
as user-level systemd services, each in its own window of a shared `tmux`
session, started at boot and respawned when they die.

One instance per project, named after the project's directory under
`~/projects`: `claude-rc@myproject` runs `claude rc` in `~/projects/myproject`.

```
$ systemctl --user list-units 'claude-rc*'
claude-rc@myproject.service    loaded active exited   claude rc window for myproject
claude-rc@otherproject.service loaded active exited   claude rc window for otherproject
claude-rc.target               loaded active active   All claude rc instances
claude-rc-healthcheck.timer    loaded active waiting  Periodically respawn dead windows

$ tmux attach -t crc
```

## Install

Needs `tmux`, `claude`, and a systemd user manager (any modern Linux).

Clone it wherever you keep checkouts — the install symlinks back to it, so
pick somewhere permanent.

```sh
git clone https://github.com/DanielBaulig/systemd-claude-rc
cd systemd-claude-rc
make install
make enable NAME=<project>     # once per ~/projects/<project> you want running
```

`make install` symlinks the scripts and units into place, enables lingering,
and starts the target and the healthcheck timer. It's idempotent — re-run it
after a `git pull`, or use `make relink` to just refresh the symlinks and
reload systemd.

Two things it can't do for you:

- **`claude` must be logged in.** Credentials are per-machine; run `claude`
  once interactively before enabling any instance.
- **Lingering may need root.** `loginctl enable-linger` goes through polkit,
  which has nothing to prompt on over a plain ssh session. If `make install`
  says so, run `sudo loginctl enable-linger $USER`. Without lingering, nothing
  starts until you log in.

## Commands

| | |
|---|---|
| `make install` | Symlink everything, enable linger, start the target |
| `make enable NAME=<project>` | Enable + start an instance for `~/projects/<project>` |
| `make disable NAME=<project>` | Stop + disable it |
| `make status` | The target, the timer, and every instance |
| `make check` | Preflight: tmux, claude, linger |
| `make relink` | Refresh symlinks and `daemon-reload` (after a `git pull`) |
| `make uninstall` | Remove the symlinks |

Instances are tracked by systemd itself, in
`~/.config/systemd/user/claude-rc.target.wants/`. There is deliberately no list
of them in this repo: a second source of truth would drift, and the healthcheck
already reads that directory directly.

## How it works

`claude-rc@.service` is a `Type=oneshot` template with `RemainAfterExit=yes`.
It doesn't hold the process — it calls three scripts:

- **`claude-rc-window <name>`** (`ExecStart`/`ExecReload`) idempotently ensures
  the window exists: creates the `crc` session if needed, respawns the window
  in place if the pane died, does nothing if it's healthy.
- **`claude-rc-window-stop <name>`** (`ExecStop`) sends `SIGTERM` to the pane's
  process and waits up to 5s. `claude rc` treats that as a clean-shutdown
  request and closes its own tmux window on the way out — unlike the `SIGHUP`
  from `tmux kill-window`, which just leaves a dead pane behind. Forced
  `kill-window` only as a fallback.
- **`claude-rc-healthcheck`** re-runs `claude-rc-window` for every enabled
  instance, on a 5-minute timer.

The healthcheck exists because oneshot means systemd isn't supervising the
window: nothing would notice a crash, an OOM kill, or a `claude update`
restart. The session is created with `remain-on-exit on`, so a crashed window
stays visible instead of vanishing, and the healthcheck has a target to respawn
into.

Instances run with `--permission-mode auto` and `--no-create-session-in-dir`.

### Paths

The claude binary is looked up as `~/.claude/local/claude`, then `claude` on
`PATH`, with `CLAUDE_BIN` as an override for anything unusual.

Project directories are assumed to live under `~/projects`. That's a single
hardcoded line at the top of `bin/claude-rc-window` if your layout differs.

The scripts are symlinked into `~/.local/bin` and the units into
`~/.config/systemd/user`, both pointing back at this checkout — so `git pull`
is the deploy, and editing a script here is editing the deployed one. After
changing a unit file, run `make relink`.

## Troubleshooting

```sh
systemctl --user status claude-rc@<project>.service   # what systemd thinks
journalctl --user -u claude-rc@<project>.service      # script output
tmux attach -t crc                                    # what actually happened
```

A window that dies instantly is almost always `claude` not being logged in on
this machine, or `~/projects/<name>` not existing.

Re-running `claude-rc-window` by hand is safe at any time — that's the whole
design. `systemctl --user reload claude-rc@<name>.service` does the same thing
through systemd.
