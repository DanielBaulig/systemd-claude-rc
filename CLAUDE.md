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
  kills your current turn.** The session itself comes back — the server keeps
  its environment on SIGTERM and re-serves the session on its next message
  (README, "Restarting an instance") — but the tool call you are in the middle
  of, and any subagents or background tasks, die with the worker, and nobody
  is left to send that next message. `claude-rc-restart` refuses this case;
  `systemctl --user stop/restart` does not. `make relink` (daemon-reload) is
  fine: it restarts nothing.
- To find out which instance that is, walk your own ancestry: the unit whose
  `MainPID` is an ancestor of `$$` is the one serving you. Nothing in the
  environment names it, and the `.out` files list every instance's sessions.
- When testing the units or a server's behaviour, use a throwaway instance
  rather than a production one: a scratch git repository outside the projects
  root, a trust entry for it in `~/.claude.json` (`claude remote-control`
  refuses an untrusted directory and cannot prompt), and a transient unit —
  `systemd-run --user --unit=claude-rc-lab-<what> -p Type=exec
  --working-directory=<dir> ~/.claude/local/claude remote-control
  --name lab-<what> --verbose --debug-file <log>`. It registers its own
  environment, so it cannot collide with a production one, and the debug file
  is where the `[bridge:*]` lines that say what the server did end up. To
  simulate a crash, `systemctl --user kill -s SIGKILL` that unit. App-side
  steps (opening a session, sending it a message) need the user; ask with the
  exact prompt to send. The tmux bullets above predate `Type=exec` — the
  servers no longer run in tmux — but the lesson about identifying your own
  process before killing anything stands.
