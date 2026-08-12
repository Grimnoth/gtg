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
gtg            log today's prescribed set as done
gtg 12         log 12 reps of today's exercise
gtg skip       record a miss
gtg today      today's tally
gtg week       the last 7 days, one bar per day
gtg plan       print the current plan
gtg edit       open the plan in $EDITOR
```

The plan lives at `~/.config/gtg/plan.txt` and is re-read on every nudge, so
edits take effect immediately. No reload.

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

Moved or replaced your router? Re-run `install.sh` at home.

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

## It fails open, on purpose

No icalBuddy, a refused calendar grant, a bad calendar name, a broken query: all
of it still nudges. A stray banner during a meeting is a much cheaper failure
than a reminder system that quietly stops reminding and takes a week to notice.

## Files

| Path | |
| --- | --- |
| `~/.config/gtg/plan.txt` | Your plan and settings. Yours; never overwritten. |
| `~/.config/gtg/home-gateway-mac` | Written by `install.sh`. |
| `~/.local/state/gtg/log.tsv` | The log. `iso8601 · exercise · reps · home\|away` |
| `~/.local/state/gtg/nudge.log` | What the scheduled job did, and why it skipped. |
| `~/.local/state/gtg/last-nudge` | Debounce stamp. Delete it to re-arm now. |

## Uninstall

```sh
launchctl bootout "gui/$(id -u)/com.grimnoth.gtg"
rm -f ~/Library/LaunchAgents/com.grimnoth.gtg.plist ~/.local/bin/gtg
```
