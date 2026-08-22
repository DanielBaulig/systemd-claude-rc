---
name: claude-rc-recovery
description: Use when asked to revive, recover, restore or bring back a Claude Code Remote Control session on this host, or when one has gone offline, shows "Can't reach your computer" / computer_unreachable in claude.ai/code, or a `claude rc` server crashed and dropped its sessions. Session titles are derived from their first prompt, so a request naming what sounds like a feature or topic -- "revive parallel worktree support", "bring back the design system one" -- is naming a session, not asking for a code change. Identify the session and recover it with claude-rc-recover. Not for starting new sessions or changing worktree configuration.
---

# Recovering a crashed Remote Control session

A `claude rc` server hands each session to a child `claude.exe`. When one of
those children dies uncleanly — OOM kill, `kill -9`, a crash — the session
goes offline and **no restart of the server brings it back**. Restarting
reclaims sessions only from a *clean* shutdown, and it does so lazily, when a
message arrives. A hard-killed session is never reclaimed that way.

`claude remote-control --session-id <id>` does reclaim it. That is the whole
recovery mechanism; everything below is about aiming it correctly.

## Identify the session

**Start here, before investigating anything else.** A request to revive
something is a request about a *session*, even when the words sound like a
feature: session titles come from the first prompt, so "parallel agent worktree
support" is a title, not a subsystem. Map the name to an id first, and only
treat it as a code question if no session matches.

If exactly one session matches, recover it. Ask the user only when the name is
genuinely ambiguous between two sessions, or when nothing matches. Only they
can see the session list, which is the authoritative record of what is offline
— nothing on this host records whether a session was archived deliberately.

To turn a name like "Phase 2" into an id, read the first user prompt of each
transcript; the title is derived from it:

```bash
for d in ~/.claude/projects/*bridge-cse-*; do
  id=$(basename "$d" | sed 's/.*bridge-cse-/cse_/')
  first=$(grep -m1 '"type":"user"' "$d"/*.jsonl 2>/dev/null | head -c 400)
  echo "$id  ${first:0:160}"
done
```

To list sessions that were never archived, look for surviving worktrees.
**Archiving a session removes its worktree and branch outright**, so a
`bridge-cse_*` directory that still exists belongs to a session that was never
archived — usually one that crashed:

```bash
ls -d ~/projects/*/.claude/worktrees/bridge-cse_* 2>/dev/null
```

Check whether one is already being served before doing anything:

```bash
pgrep -af -- "--session-id cse_XXXX"
```

Two further signals, both weak on their own:

- **A transcript ending mid-turn** — a `user` entry with no `assistant` reply
  after it — means the session died while working. A session killed while
  *idle* ends on a completed turn and looks identical to a healthy one, so
  absence of this proves nothing.
- **`Session failed: Process exited with error <cse_id>`** in the server's
  output names the session that died, but only for deaths since that server
  started.

## Recover it

Run it. Identifying the session is not the deliverable; the user asked for it
back. Confirm the resolved directory with `--dry-run`, then recover:

```bash
claude-rc-recover --dry-run cse_XXXX   # check the directory it resolved
claude-rc-recover cse_XXXX
```

It resolves the session's own directory, copies the transcript aside, and
starts a transient systemd unit `claude-rc-recover-<id>.service` running a
dedicated single-session server there.

**Then tell the user to send the session a message.** Reconnection is lazy —
the server claims the session when traffic arrives, not at startup. Checking
the session list right after starting the unit will look like failure.

## Verify

```bash
systemctl --user status claude-rc-recover-cse_XXXX.service
tail -n 20 ~/.claude/rc-logs/claude-rc-recover-cse_XXXX.out
```

A recovered session should come back on **its own branch in its own worktree**.
If it returns on the repository's default branch with a fresh transcript, the
server was started in the wrong directory — stop the unit and rerun, checking
`--dry-run` output first.

## What to know before promising anything

- **Run one server per session.** Two `claude remote-control` processes in the
  same directory interfere; the second will not reclaim what the first holds.
  `claude-rc-recover` refuses if the session is already served, but it cannot
  see a *different* server squatting the same directory. Check for one.
- **Recovery compacts the transcript, destructively.** One observed session
  went from 32MB to 7.4MB, losing ~30 hours of history, with no backup kept.
  `claude-rc-recover` copies it to `~/.claude/rc-logs/pre-recover-*.jsonl`
  first. If the user wants the *history* rather than the live session, read
  that copy instead of recovering.
- **The documented window is about four hours** after the server stopped.
  Recovery has been observed working at five, so attempt it regardless and
  report what happens rather than refusing on the clock.
- **The unit exits when the session ends.** Archiving the session from the UI
  stops the server, removes the worktree and branch if clean, and the transient
  unit disappears on its own. Nothing needs cleaning up by hand.
- If recovery genuinely fails, the work is not lost: the worktree, its branch
  and the transcript are all still on disk. Offer to continue the work in the
  worktree as a new session instead.
