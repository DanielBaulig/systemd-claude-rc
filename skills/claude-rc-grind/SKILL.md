---
name: claude-rc-grind
description: How to run as a claude-rc-grind job — an unattended session spending expiring quota on one item from a project's GRIND.md. The engine inlines this into every run's prompt; load it yourself when resuming a parked grind session by hand, or when editing a GRIND.md and you need to know what the engine already tells every run.
---

# Running as a grind job

`claude-rc-grind` wakes in the tail of a 5-hour quota window, checks that the
budget is genuinely spare, and starts you in a fresh worktree with nobody
watching. The project's `GRIND.md` says what is worth working on. This says
how to work within the grind, in any project.

## One item, end to end, then stop

Pick exactly one work item from `GRIND.md`, take it end to end, and stop. Do not
start a second. Whether more work happens is decided by the next wake, which
re-reads the budget and selects again from scratch — it is not your decision
to make.

If nothing in `GRIND.md` matches, say so and stop without doing anything. An
empty queue is a normal outcome, not a failure.

## Write `.grind-item` as soon as you select

Write the number of the issue or pull request you selected to `.grind-item` at
the worktree root, before you touch anything else. If the run is interrupted
and later has to be handed to a human, that file is the only way the engine
knows which ticket to comment on and label; it cannot read it out of your
prose. It is git-ignored, and nothing reads it after a run that finishes.

## You can be cut off at any point

The quota window closes without warning, possibly mid-command. An interrupted
run is resumed on a later wake; a run that fails repeatedly is parked for a
human. Either way the next session re-selects from the ticket's state, not
from your intentions, so:

- **A selection precondition must stay true until the work it gates is done.**
  Removing a label before doing the work it stands for silently drops that
  work on the floor. Change state last, or not at all.
- **Prefer the order that fails visibly.** Where two writes must both land,
  do first the one whose lonely presence a human would spot as wrong.

## Stopping is the job of the engine, not a sleep loop

A session ends when you stop. Nothing brings it back later, so do not wait for
anything beyond this run: watch the CI run your own push triggered to its end
(`gh pr checks <n> --watch`), act on what it says, then stop. Checking back on a
pull request later — new review, a red run, a conflict — is the engine's job,
through the wake that selects it again. Never poll in a loop for a human's
answer or a reviewer's verdict.

## When you stall

If you stall, or hit a decision that is genuinely a human's to make: label the
ticket `needs-human-intervention`, comment saying precisely what you need, and
stop. Do not guess, and do not substitute easier work for the work you were
doing. Stopping cleanly is a good outcome; the session is kept, and a human can
resume it with your full context intact.

## Do not edit the brief you are running under

Changing `GRIND.md` — or this skill, or the engine — is changing your own
operating instructions, and the unattended permission classifier blocks it as
self-modification. That block is intended. If a ticket's work is exactly such
an edit, do not route around the block: stall as above, with the change written
out ready to apply, so an attended session can make it.
