# gtg

An hourly nudge to do a grease-the-groove set, and a one-word way to log it.

No server, no webhook, no running agent. macOS already ships the scheduler
(`launchd`) and the notifier (`osascript`); this is two short shell scripts and a
plist on top of them.

## Install

```sh
brew install ical-buddy     # optional, enables meeting detection
./install.sh                # run it while on your home network
```

`install.sh` is idempotent. Re-run it after editing anything in `bin/`.

## Use

```
gtg            log today's first option as done
gtg 12         log 12 reps of that option
gtg "rows x10" log whatever you actually did
gtg options    list today's choices
gtg skip       record a miss
gtg today      today's tally
gtg week       the last 7 days, one bar per day
gtg history    the last 30 days (gtg history 90 for more)
gtg stats      totals by exercise, all time
gtg page       open the visual history in a browser
gtg plan       print the current plan
gtg edit       open the plan in $EDITOR
```

The plan lives at `~/.config/gtg/plan.txt` and is re-read on every nudge, so
edits take effect immediately. No reload.

## The nudge itself

A modal picker listing the day's options, first one preselected, plus
**Other...** and **Skip this one**. Buttons are **Log it** and **Snooze**.

- Pick an option and **Log it** records it.
- **Other...** opens a text field for whatever you actually did instead. What
  you type is looked up against the movements you already have, so a prefix is
  enough: `kett x15` logs 15 kettlebell swings. A movement it does not know is
  a question, not a guess -- it offers to add it (see below).
- One dialog records **one set**. Report two movements and it will not know
  the combination, and will ask rather than split it apart on your behalf.
- **Snooze**, or letting it time out after 15 minutes, deliberately leaves the
  slot unconsumed, so the next fire retries rather than skipping the hour.

## The order rotates itself

The list is not fixed. It reorders on every nudge so the movement you have
neglected longest sits on top, already selected:

1. Fewest sets **today** wins, so nothing gets hammered while something else
   goes untouched.
2. Ties break by whichever went longest since it was last done.
3. Anything never done sorts to the front.

So a set of pull-ups pushes pull-ups to the back, and the pool round-robins
without a schedule. The point is that the preselected item is nearly always
the right answer, which keeps a nudge at one click instead of a menu to
deliberate over. Every other option is still right there when you want it.

Matching ignores the rep count, the weight and the duration, and normalizes
the spelling, so `ring dips x5` in the plan and `5 ring dips` typed into
**Other...** are the same movement, and `pushups`, `push-ups` and `Push Ups`
all count as one. Changing any of the numbers does not make a movement look
untouched.

## The movements are a set you extend, not text it guesses at

`plan.txt` **is** the list of movements. Anything in a pool there, plus
anything already in the log, is what the tool knows -- there is no second
registry to drift out of step with the plan you actually read.

```sh
gtg add "kettlebell swings x10 @ 50 lb"        # the every-day pool
gtg add "farmer walk 2 min @ 100 lb" wed       # a named pool
gtg add "stairs, 2 flights" away
```

A weight written into the entry is used from the moment you add it, so a new
movement is usable immediately rather than only after you have logged it once
with the weight spelled out. Adding a movement that is already there is
refused rather than duplicated; to change an entry, log it once with the new
weight or run `gtg edit`.

Typing something it does not know gets you an offer to add it -- one button in
the dialog, or the exact `gtg add` line on the command line. Nothing is
recorded until you say yes.

### Why it asks instead of guessing

It used to guess, in two ways, and both quietly corrupted the log.

It **snapped near-miss spellings** to the closest known movement within an
edit distance of one, or two for longer names. That turns `10 puships` into
`Pushups`, which is lovely, and it also turns `Incline Press` into `Decline
Press` -- distance 2, both long, exactly the threshold -- merging two real
movements with nothing in the log to say it happened.

It **split on separators**, so one report could become several entries. That
turns `10 air squats and 10 pushups` into two sets, which is also lovely, and
it tears `clean and press x5` in half, and breaks the `stairs, 2 flights`
option shipped in this file's own away pool.

Both were heuristics guessing at intent, and every fix for one made the other
worse. A closed set you extend deliberately needs no guessing: an exact or
unambiguous-prefix match is decidable, and explainable when it is wrong. The
cost is that logging two movements at once takes two entries.

## A movement is a name, not a sentence

A set has up to four separable facts, and only the first is the movement:

| | |
| --- | --- |
| **name** | `Farmer Walk` |
| **reps** | `x10` |
| **duration** | `1 min`, `30s` -- stored as seconds, so `1 minute` and `60s` agree |
| **weight** | `100 lbs`, `24kg`, `@ 50` -- a bare `@ 50` assumes pounds |

Minutes must be spelled `min`, never a bare `m`. In exercise text `400m` is
metres far more often than minutes, and reading it the other way logged a
sprint as a 6.7 hour effort. A bare `s` is kept, since `30s` has no such rival.

They can arrive in any order and any shape. `Farmer Walk 1 minute - 100 lbs
total`, `50 lb kettlebell swings x10` and `kettlebell swings x10 @ 50 lb` all
pull apart correctly. Whatever is left after the numbers are lifted out is the
name.

This matters because the name is the identity. Leave a weight or a duration
inside it and every change of either founds a brand new exercise: a 1 minute
carry and a 2 minute carry stop being the same movement, `gtg stats` splits
them, and the rotation offers you one while thinking you have neglected the
other.

### The weight is remembered

You swing a 50 lb kettlebell. You should not have to say so every time.

A set logged without a weight inherits **the weight that movement carried last
time**, and the picker says so up front -- the preselected option reads
`kettlebell swings x10 @ 50 lb`, so one click logs the weight with nothing
typed. Naming a different weight overrides it, and from then on the new one is
what gets remembered.

**Duration is deliberately not inherited.** Duration is the thing you vary, so
assuming last time's would quietly log a set you did not do. Weight is a
property of the equipment; duration is a property of the effort.

One limit worth knowing: `100 lbs total` on a farmer walk means 50 per hand,
and the tool stores the number you typed without knowing which convention you
meant. Mix "total" and "per hand" for the same movement and the memory will be
confidently wrong. Pick one and stay with it.

### Entries written before this existed

Older rows have the weight and duration stranded inside the name. Every reader
strips them at read time, so nothing looks broken, but the weight in such a row
cannot be remembered -- it is still just text.

`gtg backfill` re-parses those rows into the real columns. It is opt-in and
never runs on its own, because it rewrites your data. It copies the log to
`log.tsv.bak`, builds the new version in a temporary file, refuses to continue
if the row count changes, and only then replaces the log with an atomic rename.
Any failure leaves the original untouched.

## Tests

```sh
./test/run.sh
```

Everything runs under `GTG_STATE_DIR` and `GTG_CONF_DIR` against a throwaway
directory, and the suite asserts at the end that the real log was never
touched. That override exists because it was once missing: a "dry run" of
`backfill` silently rewrote the live log instead.

## The plan file

`every:` is the core pool, offered daily. Weekday lines only add extras on top,
and duplicates collapse:

```
every: ring dips x5 | pull-ups x5 | push-ups x20 | ring crunches x12
wed:   farmer walk 1 min
```

Keep the pool short. Grease-the-groove works by hitting the same few movements
often and well short of failure.

One dialog at a time. A lock file stops a second nudge from stacking a second
window on top of an unanswered one, and the 15 minute ceiling stops an ignored
dialog from holding that lock forever and muting everything after it.

## Only one dialog, ever

The nudge is a modal alert that dismisses itself after 15 minutes. That number
is not arbitrary: fires are 30 minutes apart, so a dialog is always gone well
before the next is due, and two can never share the screen.

Three guards, in order:

- A **lock** holding the PID of the running nudge. A second fire while a dialog
  is open logs `skip: a dialog is already open` and exits.
- A **reaper** that kills any dialog stranded by an earlier run, so a stale
  window showing a stale recommendation gets replaced rather than added to.
- **`with timeout of`** wrapping every dialog. See below.

### The bug that made them stack

An Apple Event carries a default **120 second** ceiling. Asking for
`giving up after 900` means osascript gives up at two minutes and exits, while
the application keeps the window on screen forever with nothing left to
dismiss it. The script then logged `no answer (timed out)`, released the lock,
and 30 minutes later opened another on top.

Measured 2026-08-14, unattended, both shapes asking for a 150 second dialog:

| | returns after | exit | stdout | window left |
|---|---|---|---|---|
| no `with timeout of` | **121s** | 1 (`-1712 AppleEvent timed out`) | *empty* | **yes** |
| `with timeout of 210` | **150s** | 0 | `__TIMEOUT__` | no |

And the real `gtg-nudge`, run end to end with `DIALOG_TIMEOUT=140` (past that
121s ceiling): exited 0 after exactly 140s, logged
`no answer (dismissed itself after 140s)`, left zero windows, no orphan
process, lock released, `dialog.pid` cleaned.

It cost two days of nudges before it was caught, because the log and the screen
disagreed and only the log was being read: twelve lines claiming a clean
timeout, five live windows stacked up behind them. Wrapping each dialog in
`with timeout of` raises the ceiling above the dialog's own lifetime, so the
script now outlives its window rather than the reverse.

An empty result from osascript is therefore no longer folded into "timed out".
It means the dialog **failed to display**, which is a different failure and now
says so in the log.

### Why System Events

Dialogs are addressed to System Events, a proper background agent, rather than
to whatever application happens to be frontmost. An arbitrary app renders the
event however it likes -- iTerm2 produced a window with no text field and a
stranded Cancel button -- and System Events also measured 1s against 5s.

## Why a window and not a notification

`osascript`'s `display notification` posts under a bundle that has **no entry**
in `~/Library/Preferences/com.apple.ncprefs` on this Mac. macOS accepts the
notification and discards it. The job fires, exits 0, writes a success line to
its log, and nothing ever appears on screen. That was measured here, not
assumed, and it is the worst failure shape available: a reminder system that
reports success nine times a day while reminding you of nothing.

A modal window is an ordinary window. No notification permission, no Focus
suppression, no auto-dismiss after five seconds. `STYLE=banner` still exists in
the plan file for reference, but expect it to show nothing.

## The history page

`gtg page` renders `log.tsv` to `~/.local/state/gtg/history.html` and opens it:
a 26 week heatmap, streaks, today's sets, and breakdowns by exercise, by hour
of day, and home versus away.

Regenerated from the live log on every run, so it is never stale. It is a local
file on purpose rather than a hosted page: the log changes hourly, so anything
published would be a snapshot that silently goes out of date, and this is a
personal record with no reason to leave the machine.

The by-hour breakdown is the one worth watching. Grease-the-groove lives or
dies on spread, and it will show you plainly if every set is really landing in
one clump after lunch.

## When it fires

At **:50 and :20** past every hour, inside `WAKE_START`..`WAKE_END`.

:50 is the real slot. It sits just before the top of the hour, which is where
most meetings start, so the nudge naturally lands before them rather than during.

:20 is the recovery slot. A 40 minute debounce swallows it during an ordinary
free hour, so nothing ever double-fires. It earns its keep when a meeting eats
both of an hour's slots: the next :20 catches you as soon as you are free,
instead of idling until :50. After such a recovery the cadence may settle on the
:20 slot for the rest of the day, which is fine. The target is "roughly hourly".

## What suppresses a nudge

| Condition | Behavior |
| --- | --- |
| Nudged under 40 min ago | Silent. Stops the burst launchd fires on wake. |
| Outside the waking window | Silent. |
| A meeting is in progress | Silent, **and the slot is not consumed**, so the next fire retries. |
| A macOS Focus is on | macOS drops the banner itself. Nothing we control. |

A meeting *starting* within 12 minutes does not suppress anything. It changes
the wording to "squeeze it in now".

## Home vs away

The away plan fires when you are off your home network. Detection compares the
MAC address of the current default gateway against the one recorded at install.

This is deliberately **not** a wifi SSID check. Reading the SSID needs a Location
Services grant on macOS 14+, and it returns nothing at all over ethernet, which
is how this machine is usually docked. The gateway MAC is unique per router,
needs no permission, and behaves identically on wifi and ethernet.

`~/.config/gtg/home-gateway-mac` holds **one MAC per line**, so a second house,
an office, or a replaced router can all count as home. On a new network:

```sh
gtg where     # home or away, and which gateways are known
gtg home      # count the network you are on right now as home
```

## Meeting detection needs Google Calendar synced into macOS

`icalBuddy` reads macOS Calendar, not Google directly. If Google Calendar is not
synced into Calendar.app, **macOS sees an empty calendar and every meeting check
passes**, so nudges will fire straight through your meetings.

Fix, once:

> System Settings > General > Internet Accounts > pick the Gmail account >
> switch **Calendars** on.

Confirm it worked:

```sh
icalBuddy -nc -nrd -ea eventsToday      # should list today's real meetings
```

Empty output on a day you know has meetings means the sync is still off.

All-day events are excluded (`-ea`) and that matters more than it looks: one
"PTO" entry, a birthday, or a subscribed holiday calendar would otherwise read
as an all-day meeting and silently mute the whole day.

### Not every calendar entry is a meeting

A calendar used for life structure rather than scheduling is a wall of blocks
that are not commitments: `Sleep`, `Dinner`, `Morning Duties`, `Be in Bed`,
and time-tracking calendars that log where the day went. Honored literally,
those mute most of the day. Two knobs, both in `plan.txt`:

- `IGNORE_CALENDARS` drops whole calendars (time-tracking ones belong here).
- `IGNORE_TITLES` is a case-insensitive regex for routine blocks that live on a
  calendar you otherwise want honored.

Surviving both filters is necessary but not sufficient: what is left still has
to have somebody else on it, per the next section. `nudge.log` names the event
that caused each skip, so an over-broad filter is visible rather than
mysterious.

### A work block is not a meeting

Enumerating titles never keeps up, because the blocks that mute a day are the
ones you invent as you go: `Work on Booty Wars graphics`, `General Admin`,
`Pay Capital One CC`. The general rule is on the invite, not the title.

**Only an event with somebody other than you on it suppresses a nudge.** Set
`ME` in `plan.txt` to every form your own name takes in an attendee list, then
the test is arithmetic: strip yourself out, and if nobody is left it is a block
you chose rather than an appointment you owe. Deep work absorbs a 30 second
set; another person's calendar does not.

See what yours actually reports:

```sh
icalBuddy -nc -nrd -ea -b "" -iep "title,attendees" eventsToday
```

Two cases worth knowing. An event with **no** `attendees` line at all is solo,
so a real meeting you typed yourself and invited nobody to will get a banner --
the same fail-open trade the rest of this file makes. And `ME` matters most for
the events where you are the *only* invitee: a webinar, a class, a restaurant
reservation. Get `ME` wrong and those mute the hour.

## It fails open, on purpose

No icalBuddy, a refused calendar grant, a bad calendar name, a broken query: all
of it still nudges. A stray banner during a meeting is a much cheaper failure
than a reminder system that quietly stops reminding and takes a week to notice.

## Files

| Path | |
| --- | --- |
| `~/.config/gtg/plan.txt` | Your plan and settings. Yours; never overwritten. |
| `~/.config/gtg/home-gateway-mac` | Written by `install.sh`. |
| `~/.local/state/gtg/log.tsv` | The log. `iso8601 · exercise · reps · home\|away · weight · seconds` |
| `~/.local/state/gtg/log.tsv.bak` | Written by `gtg backfill` before it rewrites anything. |
| `test/run.sh` | The test suite. Runs against a scratch dir; cannot touch your log. |
| `~/.local/state/gtg/nudge.log` | What the scheduled job did, and why it skipped. |
| `~/.local/state/gtg/last-nudge` | Debounce stamp. Delete it to re-arm now. |
| `~/.local/state/gtg/nudge.lock` | Held while a dialog is open. |

## Uninstall

```sh
launchctl bootout "gui/$(id -u)/com.grimnoth.gtg"
rm -f ~/Library/LaunchAgents/com.grimnoth.gtg.plist ~/.local/bin/gtg
```
