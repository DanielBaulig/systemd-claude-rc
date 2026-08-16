# systemd-claude-rc

Run [Claude Code](https://claude.ai/code) Remote Control (`claude rc`) instances
as user-level systemd services, each in its own window of a shared `tmux`
session, started at boot and respawned when they die.

One instance per project, named after the project's directory under the
projects root (`~/projects` by default, configurable — see
[Paths](#paths)): `claude-rc@myproject` runs `claude rc` in
`<projects-dir>/myproject`. A separate, non-templated instance,
`claude-rc-general.service`, runs `claude rc` in the projects root itself,
for work that doesn't belong to any one project.

```
$ systemctl --user list-units 'claude-rc*'
claude-rc@myproject.service    loaded active exited   claude rc window for myproject
claude-rc@otherproject.service loaded active exited   claude rc window for otherproject
claude-rc-general.service      loaded active exited   claude rc window for the projects root
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
make enable NAME=<project>     # once per <projects-dir>/<project> you want running
make enable-general            # optional: one instance for the projects root itself
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
| `make enable NAME=<project>` | Enable + start an instance for `<projects-dir>/<project>` |
| `make disable NAME=<project>` | Stop + disable it |
| `make enable-general` | Enable + start the instance for the projects root itself |
| `make disable-general` | Stop + disable it |
| `make status` | The target, the timer, and every instance |
| `make check` | Preflight: tmux, projects dir, claude, linger |
| `make relink` | Refresh symlinks and `daemon-reload` (after a `git pull`) |
| `make uninstall` | Remove the symlinks |

Instances are tracked by systemd itself, in
`~/.config/systemd/user/claude-rc.target.wants/`. There is deliberately no list
of them in this repo: a second source of truth would drift, and the healthcheck
already reads that directory directly.

## How it works

`claude-rc@.service` is a `Type=oneshot` template with `RemainAfterExit=yes`.
`claude-rc-general.service` is the same shape but not templated — there's only
one projects root. Neither holds the process — they call three scripts:

- **`claude-rc-window <name>|--general`** (`ExecStart`/`ExecReload`)
  idempotently ensures the window exists: creates the `crc` session if needed,
  respawns the window in place if the pane died, does nothing if it's healthy.
  `--general` is the projects-root instance: window name `general`, working
  directory the projects root itself rather than a subfolder of it.
- **`claude-rc-window-stop <name>`** (`ExecStop`) sends `SIGTERM` to the pane's
  process and waits up to 5s. `claude rc` treats that as a clean-shutdown
  request and closes its own tmux window on the way out — unlike the `SIGHUP`
  from `tmux kill-window`, which just leaves a dead pane behind. Forced
  `kill-window` only as a fallback.
- **`claude-rc-healthcheck`** re-runs `claude-rc-window` for every enabled
  instance, including the general one if enabled, on a 5-minute timer.

The healthcheck exists because oneshot means systemd isn't supervising the
window: nothing would notice a crash, an OOM kill, or a `claude update`
restart. The session is created with `remain-on-exit on`, so a crashed window
stays visible instead of vanishing, and the healthcheck has a target to respawn
into.

Instances run with `--permission-mode auto` and `--no-create-session-in-dir`.

### Paths

The claude binary is looked up as `~/.claude/local/claude`, then
`~/.local/bin/claude` (the native installer's default), then `claude` on
`PATH`, with `CLAUDE_BIN` as an override for anything unusual.

That last fallback is unreliable in practice: `systemd --user` units run with
the manager's own minimal `PATH`, not your login shell's, so a `claude` that's
only reachable via a customized shell `PATH` (nvm, a nonstandard prefix, etc.)
resolves fine when you run `make check` interactively but still fails at
runtime. If neither hardcoded path applies to your setup, set `CLAUDE_BIN`
persistently for the user manager rather than relying on shell `PATH`:

```sh
mkdir -p ~/.config/environment.d
echo 'CLAUDE_BIN=/path/to/claude' > ~/.config/environment.d/claude-rc.conf
systemctl --user set-environment CLAUDE_BIN=/path/to/claude   # picks it up now, without a re-login
```

Project directories are assumed to live directly under a projects root,
`~/projects` by default — instance names map 1:1 to a single path segment
(`claude-rc@foo` → `<projects-dir>/foo`), and can't contain `/`: that's
disallowed in systemd unit names outright, not just a limitation of this tool.
If a project lives deeper (a monorepo checkout, say), symlink it into the
projects root under a flat name and enable that:

```sh
ln -s ~/projects/mycompany/monorepo ~/projects/mycompany-monorepo
make enable NAME=mycompany-monorepo
```

The projects root is `CLAUDE_RC_PROJECTS_DIR`, read by `bin/claude-rc-window`
and defaulting to `~/projects` if unset. Same caveat as `CLAUDE_BIN` above —
set it persistently for the user manager, not just your shell:

```sh
mkdir -p ~/.config/environment.d
echo 'CLAUDE_RC_PROJECTS_DIR=/path/to/projects' > ~/.config/environment.d/claude-rc.conf
systemctl --user set-environment CLAUDE_RC_PROJECTS_DIR=/path/to/projects   # picks it up now, without a re-login
```

`make enable`/`make check` read the same variable (falling back to the same
default) so the directory checks they do agree with what the instance will
actually use.

`general` is reserved as an instance name — `make enable NAME=general` is
rejected — because `claude-rc-general.service` already runs a window named
`general` for the projects root itself; see [above](#install).

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
this machine, or `<projects-dir>/<name>` not existing.

Re-running `claude-rc-window` by hand is safe at any time — that's the whole
design. `systemctl --user reload claude-rc@<name>.service` does the same thing
through systemd.
