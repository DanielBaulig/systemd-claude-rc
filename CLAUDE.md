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
- **`tmux display-message -p` does not tell you which window *you* are in.**
  Without `-t` it resolves against the session's *active* window — whatever a
  human last looked at — not the calling pane. So an agent using it to answer
  "which window must I not kill?" gets a confidently wrong answer. Observed:
  the bare form reported `crc:copa-alert` from a shell whose pane was in fact
  `crc:esplink`. Use `$TMUX_PANE`, which every process in a pane inherits:

  ```sh
  tmux display-message -p -t "$TMUX_PANE" '#{session_name}:#{window_name}'
  ```

  Before killing or respawning a window, guard on it explicitly:

  ```sh
  [ "$(tmux list-panes -t "crc:$name" -F '#{pane_id}')" = "$TMUX_PANE" ] \
    && { echo "that's my own pane, refusing" >&2; exit 1; }
  ```
- **Restarting `claude-rc@<name>.service` for the instance you're running as
  will kill you mid-task.** Reloading is fine (`claude-rc-window` only
  respawns a *dead* window), but `systemctl --user stop/restart` on your own
  instance, or anything that forces `claude-rc-window-stop`, is not.
- When testing changes to `bin/claude-rc-window` or the units, prefer a
  sandbox — a throwaway `HOME` and `CLAUDE_RC_PROJECTS_DIR`, plus
  `tmux -L <name>` on every tmux call — over touching the real
  `~/.config/systemd/user` or the real `crc` session. Note that
  `CLAUDE_RC_PROJECTS_DIR` and `HOME` *do* isolate; `TMUX_TMPDIR` does not,
  per the first bullet. To simulate a crash without disturbing anything else,
  `kill -9` one window's `#{pane_pid}` — `remain-on-exit on` leaves the dead
  pane in place, which is exactly the state the healthcheck looks for.
