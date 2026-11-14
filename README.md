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
| `make enable-ff NAME=<project>` | Keep that project's main checkout fast-forwarded ([below](#keeping-main-checkouts-current)) |
| `make disable-ff NAME=<project>` | Stop doing that |
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

### Restarting an instance

Restarting a server does not lose its sessions. Verified 2026-09-27 on Claude
Code 2.1.280 with a throwaway instance — a clean `systemctl stop`, a `SIGKILL`
of server and workers together, a restart with a tool call in flight, and the
same again in worktree mode — and read off the binary:

- On SIGTERM the server stops each worker, marks their work stopped, and logs
  `Skipping archive+deregister to allow resume`: the environment (the row in
  claude.ai/code) is marked offline, not deregistered, and nothing is
  archived. This is the resumability that dropping
  `--no-create-session-in-dir` bought.
- On start it reads `bridge-pointer.json`, re-registers the *same* environment,
  and re-queues the pre-created session, whose worker is back within seconds.
  Every other session comes back on its next message or app interaction: the
  app shows "Can't reach <host>" until then, the message re-queues the session
  as work, and the server spawns its worker within a second, with the
  conversation intact. A worker that crashes on its own is re-served the same
  way (Claude Code 2.1.238+). A session that was mid-turn is told its turn was
  interrupted and carries on — observed: it restarted the killed command by
  itself and said so. The documented window is about four hours.
- In worktree mode the server removes the worktree of a *live* session only if
  it is clean and not ahead of its base; dirty or ahead ones are kept
  (`[bridge:worktree] kept … dirty=true` in the debug log). A removed one is
  recreated at the same path when the session resumes, so the session comes
  back in its own worktree either way and nothing on disk is lost.

What a restart does cost:

- The turn in flight. Its tool call is killed and the session is told, but
  subagents, workflows and background tasks inside that worker die with it.
  Restart when the instance is idle if you can: `claude-rc-restart` prints the
  live worker count first, and refuses the instance that serves the shell it
  was run from — that session would lose its turn with nobody left to send
  the next message.
- A gap of a few seconds for the pre-created session, and until the next
  message for the others.

The one case a restart cannot reach is a server that came up on a *different*
environment than its sessions are attached to — a deleted or wrong
`bridge-pointer.json`, or the backend declining reuse (`Bridge env reuse
mismatch` in the debug log). Those sessions are orphaned until something
adopts their environment, which a single-session server does:

```sh
systemd-run --user --unit=claude-rc-adopt-<id> -p Type=exec --working-directory=<the session's directory> \
  ~/.claude/local/claude remote-control --session-id <id>
```

Run it from the session's own worktree, or it comes back on the default
branch. A `claude-rc-recover` script used to wrap this; it was removed once
plain restarts were verified to cover everything else.

`claude update` replaces the binary on disk, and workers spawned after that
already run the new version — the server execs children by path. Only the
server process itself stays old until it is restarted:

```sh
claude update
claude-rc-restart --all      # every running instance except the one you are in
```

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

### Keeping main checkouts current

Sessions work in worktrees and merge through GitHub, so nothing ever pulls
into a project's main checkout. Anything that runs *from* that checkout — a
hook script, say — stays at whatever version was there when someone last
pulled by hand. In October 2026 gotaspot's SessionEnd worktree reaper ran from
a main checkout 99 commits behind, so fixes to the reaper merged on GitHub did
nothing on this host.

`claude-rc-ff-main@<name>.timer` runs `claude-rc-ff-main <name>` every 15
minutes: fetch the remote's default branch and `merge --ff-only` it, but only
when the checkout is on that branch with no commits of its own. It never
resets, stashes or checks anything out. A local change in the way makes the
merge refuse, which it logs, and the next run tries again. It's opt-in per
project, since it changes files under any session working directly in the main
checkout:

```sh
make enable-ff NAME=<project>
journalctl --user -u 'claude-rc-ff-main@<project>.service'   # one line per run that did something
```

## Grind

`claude-rc-grind`, which spends expiring quota on work items from a project's
`GRIND.md`, used to live here. It moved to its own repository,
`DanielBaulig/claude-rc-grind` (private), with its history. The commits
before the move are still in this repository's log.

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
