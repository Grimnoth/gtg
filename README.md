# gtg

> ## Read this before you read the code
>
> **This is a raw personal tool. Don't judge me on the code quality.**
>
> I vibed it together on my own Mac, for me, to solve my own problem. It's
> cobbled together. It is not production ready, it is not a product, and it
> isn't trying to become one. No support, no roadmap, no issues queue, and no
> promise it runs anywhere but my machine.
>
> It hardcodes my habits, my waking hours and my movements. It assumes macOS 26,
> Hammerspoon, and a Claude subscription. Plenty of it is held together with
> shell and hope. If you're reading this looking for a reference implementation
> of anything, you're in the wrong repo.
>
> So why put it up at all? Because the point isn't the code. The point is that
> you can build a rough thing that serves one real purpose in an afternoon, and
> it can start changing what you actually do long before it's anything you'd
> call finished. That's the whole idea. This one gets me doing pull-ups.
>
> Take the ideas. Don't take the code.

An hourly nudge to do a grease-the-groove set, and a one-word way to log it.

No server, no webhook, no running agent. macOS already ships the scheduler
(`launchd`) and the notifier (`osascript`); this is two short shell scripts and a
plist on top of them.

## Install

```sh
brew install ical-buddy     # optional, enables meeting detection
./install.sh                # run it while on your home network
gtg mic                     # pick a microphone before the first `gtg say`
```

`gtg say` needs `swiftc` (Xcode, or its command line tools) to compile the
recogniser at install time, and is skipped with a note when that is missing.
A binary you can read the source of and build yourself is worth more here than
one you would have to trust.

`install.sh` is idempotent. Re-run it after editing anything in `bin/`.

## Use

```
gtg            log today's first option as done
gtg 12         log 12 reps of that option
gtg "rows x10" log whatever you actually did
gtg "a; b; c"  log a whole round, ";" between movements
gtg @8am ...   log a set you did earlier (see below)
gtg when 8am   show how a time would be read, logging nothing
gtg say        press, speak, done
gtg mic        which microphone it listens on (gtg mic 3 to pick)
gtg options    list today's choices
gtg off        no more nudges today (gtg off sick, gtg off 2h, gtg off 3d)
gtg on         start them again
gtg status     where, the pick, today's sets, and whether it is off
gtg skip       record a miss
gtg nudges     the last 20 fires and what each one did
gtg fires      what became of every nudge in the last 14 days
gtg friction "X"  jot what got in the way, in the moment
gtg today      today's tally, and which waking hours got a set
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
  a question, not a guess -- the line comes back in a box to fix or confirm
  (see below).
- One dialog records a **whole round**: `pull-ups x5 and dead hang 30s`. The
  word "and", `;` and `|` separate sets, and the round is checked in full
  before a single row is written.
- **Snooze**, or letting it time out after 15 minutes, deliberately leaves the
  slot unconsumed, so the next fire retries rather than skipping the hour.

## Not today

Some days there is no set coming: sick, wrecked, travelling. Nine dialogs on
such a day are pure nuisance, and a reminder with no off switch is one you
learn to ignore, which costs every day after it too. So it takes "no" for an
answer.

```sh
gtg off             no more today; back tomorrow morning
gtg off sick        the same, with a reason kept in the log
gtg off 2h          just this stretch
gtg off 3d flu      today and two more days
gtg on              back on now
```

The menu bar says **Not today — stop the nudges**, one click, and reads
**Turn the nudges back on** while it is off. The title reads `🏋 off`, so a
quiet afternoon is never a mystery.

The same words work wherever there is a text field, which is the point: the
moment this is wanted is the moment a dialog is in the way. Type `off`,
`not today`, `no more today`, `stop`, or `sick` into the nudge's **Other…**
box or the menu bar's box and the nudges stop. A duration and a reason may
follow any of them.

**Every pause carries an end time**, and no argument means the rest of today:
the nudges come back by themselves at tomorrow's `WAKE_START`. The failure to
avoid is the opposite one, a tool switched off in February and noticed in May.
Nothing is scheduled to bring them back either. The expiry is read at the next
fire, and an expired pause file is deleted as it is read, so no timer has to
survive a reboot.

A word starting with a digit is read as a stretch of time, never as a reason.
`gtg off 2x` is refused rather than quietly meaning the rest of the day.

A day off is not a day of nudges ignored, so `gtg fires` counts them apart:
they land in the `skipped:` line as `turned off`, and never in the `no answer`
share. The pause also silences the menu bar's "Before you sat down?" box on
the next unlock. "Stop sending me these things" means that one too.

## Sets you did before you sat down

The nudge can only ever stamp the moment you answer it, so a round done in the
kitchen at seven had nowhere to go. A leading `@time` fixes that, and composes
with every other form.

And the menu bar **asks**. Most mornings hold two or three sets before the
first unlock, and the log showed almost none of them: by the time the computer
was open they were forgotten. So the first unlock after two hours away, or
after a night, opens a box titled "Before you sat down?". One box, the whole
morning in one line: `@7:15 pull-ups x5 and @7:40 ring dips x5 and dead hang
30s`. It used to ask again after every entry until you said that was all, and
that second box was the complaint. Every showing is stamped into the nudge
log, so `gtg fires` reports how much it catches.

```sh
gtg @8am 10 ring crunches
gtg @7:15 "pull-ups x5 and dead hang 30s"  # a whole round at once
gtg "@7:15 pull-ups x5; @7:40 dead hang 30s"  # two times, one line
gtg @7:15 "10x bulgarian split squats"    # count first is fine too
gtg @-90m push-ups x20                     # ninety minutes ago
gtg @yesterday 6pm ring dips x5             # multi-word times need no quotes
gtg @8am                                   # the day's first option, at 8
```

Times are read forgivingly: `8` `8am` `8:00` `08:00` `0800` `8:00am` `2pm`
`14:30` `-90m` `2h ago` `yesterday 7am` `2026-08-18 6:30`. A bare 1-12 with no
am/pm means the most recent one that has **already happened**, so at 2pm `@8`
is this morning and `@1` is an hour ago. Anything still landing in the future
drops back a day.

What makes a forgiving parser safe is that every backdated log **prints the
time it resolved to**, so a misreading is visible in the same breath rather
than discovered weeks later in the history page. `gtg when 8am` answers the
same question without writing anything.

The same `@time` prefix works in the nudge's **Other…** field and in the menu
bar, where there is one text field and no quoting -- so the time is allowed to
span words, and the **longest** leading run that parses wins. That rule is what
keeps it from getting greedy: in `@yesterday 7am 10 ring crunches` the
three-word candidate `yesterday 7am 10` is not a time and fails to parse, so
the count stays with the movement. A parser that guessed rather than failed
would have silently logged ten o'clock.

`;`, `|`, `&` and the word "and" separate movements in a round, because "and"
is how a round gets dictated. A **comma does not** -- the shipped option
`stairs, 2 flights` is one movement whose name contains one. A movement named
with "and" (`clean and press`) would be torn in two; no pool here has one, and
the ponytail on `record_batch` names the fix if one arrives. A round is
checked in full before a single row is written: it should not half-land
because the third movement was misspelled, leaving you to work out which half
made it.

A piece may carry its own `@time`. A morning done at two times is one line,
and a piece without a time follows the one before it, a second later.

### The log stays append-only

A backdated row is **appended**, not inserted in date order. Rewriting the only
copy of your history to serve a convenience is the exact shape of the bug
`gtg backfill` exists to avoid. Readers that care about order sort at read time
instead, and "the weight you last lifted" means latest by timestamp -- with file
order breaking a tie, since a whole round lands inside one second.

## Every set is also a calendar event

Set `CALENDAR=GTG` in `plan.txt` and every logged set is mirrored onto that
calendar as a zero-minute event at the set's own time, so a backdated 7:15
set lands at 7:15. The calendar lives in Google, synced into Calendar.app, so
the history is on the phone and in the calendar already being looked at. The
write goes through Calendar.app by AppleScript, in the background, and is
idempotent: the same set at the same minute is never written twice.

`gtg calendar-sync 30` writes the last 30 days. It is the one-time backfill,
and the repair if Calendar.app was not running for a while. Safe to re-run.

The first run of it put `dead hang xhome` on the calendar. Reading the log
with `IFS=$'\t' read` collapses a run of empty fields, so a timed set with no
rep count slid "home" into the reps column. That is the same trap the parser
comments describe, met a second time; the sync now re-emits rows with a unit
separator before splitting them, and the suite feeds it a timed set.

A failed write is named in the nudge log, never swallowed. Put the same name
in `IGNORE_CALENDARS` so the nudge does not read its own sets back as
meetings.

The first set logged from a real nudge reached the log and never the
calendar, and the nudge log said nothing. The write runs in the background
and outlives the nudge by seven seconds, and launchd kills every process left
in a job's group when the main one exits, by SIGKILL, which leaves no error
to record. `AbandonProcessGroup` in the plist is the fix, and it was
measured before it was trusted: two throwaway jobs, one with the key and one
without, and only one child survived. Re-run `install.sh` after pulling this
so the loaded job carries it.

## Say it

Press `⌃⌥⌘V`, say what you did, and stop talking. That is the whole thing.
No window to find, no field to focus, nothing typed. It stops by itself about
a second and a half after you stop speaking, so there is no second press to
remember either. A set remembered at the top of the stairs is a set logged.

```sh
gtg say     the same from a terminal
gtg mic     which microphone it listens on
```

The recogniser is the one macOS 26 ships, running **on this Mac**. No API key,
no account, no model to download by hand, and the audio never leaves the
machine. A microphone is the most invasive thing a small tool can ask for, and
the answer here is that nothing it hears is ever sent anywhere.

**Run `gtg mic` before the first use.** The system default input is very often
the wrong one and fails silently: on this Mac it is an audio interface with
nothing plugged into it, which records a flat -71 dB. Worse, that interface
has loopback channels, so the first thing this ever transcribed was the
podcast playing through it. `gtg mic 3` writes the choice into `plan.txt`.

When it hears nothing it says which of the two happened -- a room that stayed
quiet, or a device that is not connected to anything -- because only one of
those is worth going to fix.

What comes back is a sentence, and that is the point of the next section.
Speaking "ten ring dips and a thirty second back stretch with the kettlebell"
produced, word for word:

```
10 ring dips and a 32nd backstretch with a kettlebell.
```

## When it does not know the words

A closed set of movements and a strict grammar work beautifully while the
input is a **command**. They fall apart the moment it is a **sentence**, and
three rows in the log say so:

| typed or spoken | what landed |
| --- | --- |
| `30-second back stretch with kettlebell` | refused, then hand-fixed into a row saying **30 reps** of a movement that has been 30 **seconds** every other time |
| `7am Ring Dips x5` | a movement named `7am Ring Dips` |
| `ring dips weight + 34lb` | a movement named `Ring Dips Weight +` |

The first one is the clearest. `30-second` keeps its hyphen, so the duration
strip does not fire and the number stays welded to the name. And the words
left off are at the front **and** the back at once, which is exactly what
neither prefix nor substring matching can reach. That is not a bug in the
matcher. It is a sentence meeting a parser.

So a line the parser cannot read gets **one** more reader before it is
refused: `claude -p` on the subscription already being paid for, which
rewrites it into the syntax above.

```
30-second back stretch with kettlebell
  -> read as: kettlebell back stretch 30s
```

### The model never writes to the log

It rewrites the line, and the rewritten line goes straight back through
`record_batch`, which checks it exactly as it checks anything typed. So:

- a movement it already understands **never goes near a model**, and is logged
  by the parser as before;
- an invented movement gets the same **New movement** box a typo gets;
- a reader that is off, slow, or broken lands on the same refusal, word for
  word, that this tool gave before any of it existed.

The model gets to rephrase the question. It never gets to answer it.

**Every interpreted line prints `read as:` in the same breath.** That is the
same rule the time parser follows, for the same reason: a forgiving reader is
safe only because it says out loud what it read, rather than leaving a
misreading to be found weeks later in the history page.

### What it is told

Not just the names. `gtg` knows the shape of every movement from the log, and
that is what makes the difference between a lookup and a guess:

```
ring dips               - counted, usually x5 (16 sets)
kettlebell back stretch - timed, usually 30s (10 sets)
farmer walk             - timed, usually 1 min, at 100 lb (5 sets)
7am Ring Dips           - counted, usually x5 (1 set)
```

Given only the names, sonnet read `32nd backstretch` as **32 reps**. Given
that line, it reads 30 seconds. "Usually" is the value seen **most often**,
never the last one: the last one is precisely where a single mistyped entry
lives, and one bad row must not redefine a movement. The set count is there
so a one-off can be seen for what it is. Two of the entries above are parses
that went wrong, and nobody has ever done either of them twice.

### It has to look like an answer

`claude -p` with no usable credential prints `Not logged in - Please run
/login` **on stdout, and exits 0**. A sanitiser that only checked for letters
passed that straight through, and a spoken set offered to add a movement
called "Not logged in - Please run /login" to the pool.

A logged-out session is a thing that will happen. So an answer is believed
only when every piece of it carries a count, or a duration, or names a
movement that already exists. Prose has none of the three. A refused answer is
written into the nudge log by name rather than swallowed, because a reader
that quietly stops reading is the same shape as a reminder that quietly stops
reminding.

### Settings

```
INTERPRET=claude    Claude Code, sonnet. The default. Measured 7.0s.
INTERPRET=codex     the Codex CLI. Measured 8.0s, and it read the syntax
                    template as literal text on the first try.
INTERPRET=off       no reader; an unfamiliar line is refused, as before.
MIC=Logitech BRIO   which microphone `gtg say` listens on; a prefix is enough.
```

Both readers run on a subscription, and neither takes an API key. The answer
is cached by what was said, so a phrase repeated tomorrow costs nothing.
Measured from a real LaunchAgent, not only from a terminal: the nudge fires
from launchd, and a process outside the GUI login session cannot reach the
Keychain where the credential lives.

## The menu bar

A 🏋 item showing today's count and spread, `🏋 3 · 2/5h` meaning three sets
and two of the five waking hours so far got one, from `~/.hammerspoon/gtg.lua`:

```
5 sets today  ·  home
Did ring dips x5              <- the rotation's pick, one click
Say a set…   ⌃⌥⌘V          <- speak it; nothing to type, nothing to find
Log something else…
Log what I did before sitting down…   <- one box, the whole morning in one line
Not today — stop the nudges   <- off until tomorrow morning, one click
Something got in the way…     <- a friction note, stamped with the context
Today  >                      <- every set, with times
History page…
Refresh
```

### The click does no work

The menu used to run three `gtg` commands while the click waited: `today`,
`where` and `options`, measured at 153ms, 145ms and 634ms on this Mac.
`hs.menubar` builds its menu synchronously, so that was most of a second spent
on Hammerspoon's main thread with the pointer already down, every single time.
It felt like a menu that sometimes does not open.

Now the menu is drawn from the last snapshot and nothing else, which measures
under a millisecond. Opening it also starts a fresh snapshot in the
background, through `hs.task` rather than `hs.execute`, and the next open and
the five minute timer pick that up. One `gtg status` call replaced the three,
because the menu needs one process, not three.

The cost of the trade is a count that can be a few minutes stale. The actions
never read it -- `gtg` recomputes the pick when it runs -- so the worst case is
a stale label, never a wrong set logged.

Hammerspoon rather than a menu bar app of its own: it was already installed and
running here, and this is a face for the `gtg` CLI, not a second implementation
-- the log format, the rotation and the time parser stay in one place, so the
menu and the terminal cannot disagree.

It lives in its own file, loaded from `init.lua` inside a `pcall`. That config
has broken itself once before (`init.lua.broken-2026-08-12`), and a fault in a
fitness reminder must not be able to take the rest of it down.

**`hs.menubar` methods do not return when driven from the `hs` command line.**
They are fine in normal operation -- the item builds at load, and the timer
repaints it -- but `hs -c 'gtgBar.start()'` hangs, which is why `start()` reuses
its existing item instead of deleting and rebuilding one. Test the menu with
`hs -c 'return #gtgBar.menu()'`, which does return.

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

Typing something it does not know is now read once more before it is refused,
by a model, as a sentence -- see **When it does not know the words** above.
What that cannot resolve either gets you a box with your line in it, holding
whatever the reading was. Fix the spelling and it resolves. **Log it** records it under the name as typed,
and from then on the log is what makes it known. **Add to pool** does that and
offers it every day. Nothing is recorded until you press one of them. On the
command line the same two answers are `gtg --new "..."` and
`gtg --offer "..."`, and the menu bar asks the same question with the same
box (its version has **Log it** only; `gtg add` is how it gets offered).

Before this, the menu bar path showed a terminal command in a dialog and
stopped, and the nudge asked yes-or-no with nothing to edit: a misspelling
had to be declined and retyped from the start.

The nudge's question did not exist at all for its first three weeks. The
script that built the "Add it?" box had its quote marks mangled on the way to osascript, which
rejected it and printed nothing, and nothing was recorded as "declined". Fifteen
declines in the log, none of them a person. The test suite now compiles every
dialog script with `osacompile`, and a prompt that fails to display logs as
exactly that rather than as a choice you made.

The count can come first. `20x push ups`, `8 x ring dips` and `push ups x20`
are one shape, because the first is how it actually gets typed: twelve of the
first twenty-three refused entries were that and nothing else. A trailing
period is dropped for the same reason.

### Why it asks instead of guessing

It used to guess, in two ways, and both quietly corrupted the log.

It **snapped near-miss spellings** to the closest known movement within an
edit distance of one, or two for longer names. That turns `10 puships` into
`Pushups`, which is lovely, and it also turns `Incline Press` into `Decline
Press` -- distance 2, both long, exactly the threshold -- merging two real
movements with nothing in the log to say it happened.

It **split on every separator**, so one report could become several entries.
That turns `10 air squats and 10 pushups` into two sets, which is also lovely,
and it tore `clean and press x5` in half, and broke the `stairs, 2 flights`
option shipped in this file's own away pool.

Both were heuristics guessing at intent, and every fix for one made the other
worse. A closed set you extend deliberately needs no guessing: an exact or
unambiguous-prefix match is decidable, and explainable when it is wrong.

"and" came back as a separator on 2026-09-08, deliberately and with the
trade-off written down: no pool names a movement with it, and it is the word
a round gets dictated with. The comma stays unsplit.

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

**The count is remembered the same way.** A pool entry with no count, such as
`bulgarian split squats`, was offered bare, and **Did it** logged a set with
no reps. Now it reads `bulgarian split squats x5` once you have logged five,
and a new count overrides it from then on. A timed movement never gets one.

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

`gtg backfill` re-parses those rows and **writes nothing**. It leaves a
candidate at `log.tsv.migrated`, prints a before/after diff, and tells you the
`mv` to run if you like what you see.

It began as an in-place rewrite, and every round of review found another way
for that to lose data: an output redirect that truncated the log before the
conversion ran, a failed backup reported as success, a nudge answered
mid-migration vanishing between the snapshot and the rename. Those were not
three bugs but one design -- destructively rewriting the only copy of your
history, to serve a migration you run once. Handing you a file to inspect
removes the whole class rather than guarding each way through it.

It also only touches a row when something **unambiguous** came out of the
name: an explicit `xN`, a leading count, a weight, or a duration. A trailing
bare number stays put, so `Zone 2` keeps both its words instead of becoming
movement `Zone` with 2 reps.

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

`INTERPRET=` and `MIC=` live here too, and are covered above.

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

At **:50 and :20** past every hour, inside the waking window.

`WAKE_START` is inclusive, `WAKE_END` is **not**. The shipped `9` and `21` mean
"nothing before 9am, nothing at or after 9pm", so the first possible fire is
**9:20** and the last is **20:50**. Read inclusively, `21` would have permitted
21:20 and 21:50, an hour past what the number looks like. Both sides of that
boundary are tested.

:50 is the real slot. It sits just before the top of the hour, which is where
most meetings start, so the nudge naturally lands before them rather than during.

:20 is the recovery slot. A 40 minute debounce swallows it during an ordinary
free hour, so nothing ever double-fires. It earns its keep when a meeting eats
both of an hour's slots: the next :20 catches you as soon as you are free,
instead of idling until :50. After such a recovery the cadence may settle on the
:20 slot for the rest of the day, which is fine. The target is "roughly hourly".

## Every fire says what it did

`gtg nudges` reads back the last 20, and what each one decided:

```
  2026-08-19 12:21  logged: Farmer Walk 1 min @ 100 lb
  2026-08-19 12:51  skip: debounced, 30 min since the last nudge (needs 40); next due 13:00

  last answered:  Wed 12:20
  next possible:  Wed 13:00  (then the first of :20 / :50 after it)
```

The skip lines matter more than the logged ones. The debounce and the waking
window used to exit **silently**, so "did I miss a nudge five minutes ago?" had
no answer: an absent line meant either *suppressed on purpose* or *the job
never ran*, and nothing distinguished them. That is the same ambiguity that
once hid twelve broken dialogs for two days. A skip is a decision, not an
absence of one, so it is recorded like one and the tests hold it there.

Roughly 48 lines a day, most of them overnight.

### What becomes of them

`gtg fires` reads the same log back as a table, because the question that
matters is not "did it fire" but "what did I do when it did":

```
last 21 days: 387 nudges shown
  logged        69   18%
  snoozed       96   25%
  no answer    200   52%
  refused       18    5%
  skipped: 357 outside hours, 39 debounced, 0 in a meeting
  catch-up: 0 shown, 0 sets logged

  hour     09 10 11 12 13 14 15 16 17 18 19 20
  shown    26 35 28 34 30 31 29 36 32 26 35 36
  logged    7 11  7  9  8  5  5  2  5  4  3  3
```

That is the real baseline, 2026-09-03. Half of all dialogs sat for fifteen
minutes and dismissed themselves. Mornings log one fire in four, evenings one
in nine. Zero meeting skips in three weeks means the work calendar is not
synced into macOS Calendar, not that there were no meetings. Each change to
this tool from here is judged against this table, and `gtg friction` is where
the reasons behind the numbers get written down while they are fresh.

## What suppresses a nudge

| Condition | Behavior |
| --- | --- |
| Nudged under 40 min ago | Logged, with how long since and when the next is due. Stops the burst launchd fires on wake. |
| Outside the waking window | Logged, with the window it used. |
| A meeting is in progress | Logged, **and the slot is not consumed**, so the next fire retries. |
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

## The calendar is the wrong signal, so a better one is on probation

The calendar check never fired once in its first three weeks. The work calendar
was never synced into macOS Calendar, and it belongs to an employer, so a signal
built on it expires with the job. The microphone is no better on this Mac:
Wispr Flow holds it open whenever a sentence is dictated.

What the machine actually knows is its window list. Zoom names a live call
`Zoom Meeting`, a Google Meet tab is titled `Meet – ...`, Slack names a
huddle. `gtgBar.meetingWindow()` in the Hammerspoon file returns the first
such title, and every fire writes what it saw:

```
  2026-09-04 10:20  seen: Google Chrome: Meet – abc-defg-hij
  2026-09-04 10:20  snoozed
```

It suppresses **nothing yet**. `gtg fires` counts the sightings against what
happened next, as `with a call window open: N shown, M logged`. A week of that
says whether the signal is honest, and only then does it earn the right to
mute a nudge. A Meet in a background tab is invisible to it, since a browser
window carries its active tab's title, and the same week will show whether
that matters.

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
| `~/.local/state/gtg/log.tsv.migrated` | A `gtg backfill` proposal. Yours to inspect and move, or delete. |
| `test/run.sh` | The test suite. Runs against a scratch dir; cannot touch your log. |
| `~/.local/state/gtg/nudge.log` | What the scheduled job did, and why it skipped. |
| `~/.local/state/gtg/last-nudge` | Debounce stamp. Delete it to re-arm now. |
| `~/.local/state/gtg/nudge.lock` | Held while a dialog is open. |

## Uninstall

```sh
launchctl bootout "gui/$(id -u)/com.grimnoth.gtg"
rm -f ~/Library/LaunchAgents/com.grimnoth.gtg.plist ~/.local/bin/gtg
```
