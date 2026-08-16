# CLAUDE.md

Guidance for Claude Code when working in this repository.

## 🚨 You may be running on this infrastructure

An agent working on this repo is very often a `claude rc` instance that this
same repo's systemd units are hosting — one window of the shared `crc` tmux
session. Killing or restarting the wrong thing doesn't just break the system
under test, it can pull the rug out from under the session you're running in.

- **Never run bare `tmux kill-server` (or `kill-session -t crc`).** If your
  shell is itself running inside a `claude rc` pane — likely, since that's
  what this repo runs — it already has `$TMUX` set to the *real* server's
  socket, and plain `tmux` commands honor `$TMUX` over `TMUX_TMPDIR`.
  Exporting `TMUX_TMPDIR` to an empty dir does **not** isolate you: it's only
  consulted when starting a *new* server, and a shell with `$TMUX` already
  set is by definition talking to an existing one. This is exactly how a
  previous agent killed its own session: it exported `TMUX_TMPDIR` intending
  an isolated smoke test, but every `tmux` call in that block — including the
  final `kill-server` — still resolved to the live `crc` session via
  inherited `$TMUX`, taking down its own pane along with the others. The only
  reliable isolation is `tmux -L <throwaway-name> ...` (or `-S <path>`) on
  *every* command, or `env -u TMUX tmux ...` to force a fresh server.
- **Restarting `claude-rc@<name>.service` for the instance you're running as
  will kill you mid-task.** Reloading is fine (`claude-rc-window` only
  respawns a *dead* window), but `systemctl --user stop/restart` on your own
  instance, or anything that forces `claude-rc-window-stop`, is not.
- When testing changes to `bin/claude-rc-window` or the units, prefer a fully
  isolated `HOME`/`TMUX_TMPDIR`/`CLAUDE_RC_PROJECTS_DIR` sandbox (all three,
  all in the same Bash call) over touching the real `~/.config/systemd/user`
  or the real `crc` session, even read-only-seeming checks.
