# systemd-claude-rc

Run [Claude Code](https://claude.ai/code) Remote Control (`claude rc`) instances
as user-level systemd services, started at boot and restarted when they die.
systemd owns each server process directly, so `systemctl` reports the truth
about it and can restart it without help.

One instance per project, named after the project's directory under the
projects root (`~/projects` by default, configurable — see
[Paths](#paths)): `claude-rc@myproject` runs `claude rc` in
`<projects-dir>/myproject`. A separate, non-templated instance,
`claude-rc-general.service`, runs `claude rc` in the projects root itself,
for work that doesn't belong to any one project.

```
$ systemctl --user list-units 'claude-rc*'
claude-rc@myproject.service    loaded active running  claude rc server for myproject
claude-rc@otherproject.service loaded active running  claude rc server for otherproject
claude-rc-general.service      loaded active running  claude rc server for the projects root
claude-rc.slice                loaded active active   Resource limits shared by every instance
claude-rc.target               loaded active active   All claude rc instances

$ tail -n 4 ~/.claude/rc-logs/rc-myproject.out    # the server's own status line
```

## Install

Needs `claude` and a systemd user manager (any modern Linux).

Clone it wherever you keep checkouts — the install symlinks back to it, so
pick somewhere permanent.

```sh
git clone https://github.com/DanielBaulig/systemd-claude-rc
cd systemd-claude-rc
make install
make enable NAME=<project>     # once per <projects-dir>/<project> you want running
make enable-general            # optional: one instance for the projects root itself
```

`make install` symlinks the scripts, units and skills into place, enables
lingering, and starts the target and the node_modules reaper timer. It's
idempotent — re-run it after a `git pull`, or use `make relink` to just refresh
the symlinks and reload systemd.

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
| `make install` | Symlink everything, enable linger, start the target and timers |
| `make enable NAME=<project>` | Enable + start an instance for `<projects-dir>/<project>` |
| `make disable NAME=<project>` | Stop + disable it |
| `make enable-general` | Enable + start the instance for the projects root itself |
| `make disable-general` | Stop + disable it |
| `make status` | The target, the timer, and every instance |
| `make check` | Preflight: projects dir, claude, linger |
| `make relink` | Refresh symlinks and `daemon-reload` (after a `git pull`) |
| `make uninstall` | Remove the symlinks |

Instances are tracked by systemd itself, in
`~/.config/systemd/user/claude-rc.target.wants/`. There is deliberately no list
of them in this repo: a second source of truth would drift, and systemd
already reads that directory directly.

## How it works

`claude-rc@.service` is a `Type=exec` template; `claude-rc-general.service` is
the same shape but not templated, since there is only one projects root. Both
run one script:

- **`claude-rc-serve <name>|--general`** (`ExecStart`) resolves the directory
  and the `claude` binary, then `exec`s the server, replacing itself. Because
  it execs rather than spawns, the process systemd supervises *is* the server.
  `--general` is the projects-root instance: working directory the projects
  root itself rather than a subfolder of it.

`Type=exec` is the whole point. An earlier version of this repo used
`Type=oneshot` with `RemainAfterExit=yes` to launch each server into a `tmux`
window. tmux moves each pane into its own transient scope, outside the unit's
cgroup, so systemd had nothing to watch: units reported `active` for three days
after the server they started had been OOM-killed and replaced, with
`NRestarts=0`. A 5-minute timer polled for dead windows to make up for it.
Neither the timer nor tmux is needed once the unit holds the process, and both
are gone.

`Restart=on-failure` with `RestartSec=10s` replaces the healthcheck, bounded by
`StartLimitBurst=5` in 5 minutes so a server that cannot start ends up visibly
`failed` rather than looping.

`OOMPolicy=continue` is deliberate and load-bearing. systemd's default is
`stop`: when the kernel OOM-kills any process in a unit, systemd tears down the
*whole* unit. In August 2026 that turned one runaway agent into the loss of
every session its server was hosting. With `continue`, the kernel takes the one
process and the server keeps running.

`claude-rc.slice` caps what every instance can consume between them, and each
unit carries its own `MemoryHigh`/`MemoryMax` so a runaway instance is
contained before it reaches the slice ceiling, let alone the host. A server
with one live session measures around 300M.

Instances run with `--permission-mode auto`. They no longer pass
`--no-create-session-in-dir`: that flag is the documented opt-out from
resumability, so a server started with it archives its sessions on stop and
nothing survives a restart. Dropping it costs one pre-created session per
instance in the session list. Set `CLAUDE_RC_NO_SESSION_IN_DIR=1` to restore
the old behaviour.

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

The projects root is `CLAUDE_RC_PROJECTS_DIR`, read by `bin/claude-rc-serve`
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

The scripts are symlinked into `~/.local/bin`, the units into
`~/.config/systemd/user`, and `skills/` into `$CLAUDE_RC_PROJECTS_DIR/.claude/skills`
— all pointing back at this checkout, so `git pull` is the deploy and editing a
script here is editing the deployed one. Skills land in the projects root rather
than in any one repository so that the `general` instance, which serves that
root, picks them up as project scope. After changing a unit file, run
`make relink`.

## Troubleshooting

```sh
systemctl --user status claude-rc@<project>.service   # state, restarts, memory
journalctl --user -u claude-rc@<project>.service      # errors and restarts
tail -n 4 ~/.claude/rc-logs/rc-<project>.out          # the server's status line
```

An instance that dies instantly is almost always `claude` not being logged in
on this machine, or `<projects-dir>/<name>` not existing; both say so in the
journal.

The `.out` file holds the server's redrawn status line — connection state,
capacity, environment URL — which is why it isn't in the journal, where it
would bury everything else. It is truncated on each start.
