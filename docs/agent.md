# gtg hub

The set log lives on the Mac mini. Log a set here. Do not keep a second copy.

Base URL: `https://<hub>.<tailnet>.ts.net/gtg`

Send this header on every `/api` and `/mcp` request:

```
Authorization: Bearer <token>
```

The token is the contents of `~/.config/gtg/token` on the mini. The dashboard (`/`) and this page (`/agent.md`) do not need it.

Set `BASE` and `TOKEN`, then use the examples below.

```sh
BASE=https://<hub>.<tailnet>.ts.net/gtg
TOKEN=the-token-from-the-mini
```

## Log a set

```sh
curl -s -X POST "$BASE/api/log" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"text":"pull-ups x5 and dead hang 30s","at":"7:15"}'
```

`text` is what was done. `at` is optional: a time such as `7:15`, `8am`, `-90m`, or `yesterday 7am`. Leave the `@` off. It is added for you.

A response is `{"ok": true, "output": "...", "error": null}`. `output` is what the `gtg` command printed. `error` is its stderr, or null.

## Text

One set: `pull-ups x5`. A count can lead instead: `10 pull-ups`.

A round is several sets in one line. `and`, `;`, `|`, and `&` separate them. A comma does not. `stairs, 2 flights` is one movement.

```
pull-ups x5 and dead hang 30s
pull-ups x5; dead hang 30s
```

A duration is `30s` or `1 min`. A weight sits in the text as `@ 50 lb`.

A piece can carry its own time: `@7:15 pull-ups x5; @7:40 dead hang 30s`. A piece with no time follows the one before it, a second later. Or put one time on the whole line with `at`.

Times read loosely: `8`, `8am`, `8:00`, `0800`, `14:30`, `-90m`, `2h ago`, `yesterday 7am`, `2026-08-18 6:30`. A bare 1-12 with no am/pm means the latest one that has already happened.

The whole round is checked before any row is written. One unknown name writes nothing.

`text` is passed to `gtg` as its argument. A single word that is already a command runs that command: `off` pauses nudges, `on` resumes them, `skip` records a miss of today's first option, `done` logs that option. A bare number (`12`) logs that many reps of the first option. A set with a count or a duration (`pull-ups x5`, `dead hang 30s`) does not match any command.

## When the name is refused

HTTP 422 means nothing was logged. `error` names the movement. `known` is today's options plus all-time totals. There is no separate list of known names.

Correct `text` to a name from `known` and POST the same request again.

If the movement is genuinely new, send the same body with `"new": true`. That logs the name as typed. Use it for a new movement, not to push a typo through.

## Daily coaching plan

Use the same Bearer token for these endpoints. Dates and slot hours use the
hub's local time, America/New_York. Plans live under
`~/.local/state/gtg/plans/YYYY-MM-DD.json`. Posting replaces that date only;
other dates remain available.

`POST /api/plan` accepts:

```json
{"date":"2026-10-13","readiness":74,"sleep":70,"band":"moderate","note":"Keep it easy","slots":[{"hour":10,"items":[{"movement":"Push-Ups","reps":15},{"movement":"kettlebell back stretch","seconds":30}],"why":"Stay submax"}],"targets":{"Push-Ups":60}}
```

Readiness and sleep are integers from 0 to 100. Band is `low`, `moderate`, or
`high`. Each unique hour is 0 to 23; each item has exactly one positive integer,
`reps` or `seconds`. `why` is optional. Slots may be empty for a rest day.
Targets are positive integers. Names must match a known full movement name,
ignoring letter case; stored names use the registry's spelling. Unknown names
return HTTP 422 with `error` and a `known` array. Other invalid fields return
400. A successful write returns `{"ok":true,"plan":{...}}`.

`GET /api/plan?date=YYYY-MM-DD` defaults to today and returns:

```json
{"ok":true,"plan":{"date":"2026-10-13","slots":[{"hour":10,"items":[{"movement":"Push-Ups","reps":15}],"why":"Stay submax","status":"done"}],"targets":{"Push-Ups":60},"readiness":74,"sleep":70,"band":"moderate","note":"Keep it easy"},"progress":{"targets":{"Push-Ups":{"done":15,"target":60,"remaining":45}}}}
```

Slot status is `done`, `skipped`, or `pending`. Any non-skip set logged in that
hour, or a `log`/`elsewhere` answer, completes the hour. A logged completion
takes precedence over a skip. A skip row, skip route, or `skip`/`off` answer
marks it skipped. Snooze and no answer leave it pending. Target totals include
all sets on the date, including sets outside planned slots. Totals use seconds
for movements planned by duration, otherwise reps.

`GET /api/plan/next` returns the current hour's pending slot or the next future
pending slot. Past pending slots remain in history but are not suggested.

```json
{"ok":true,"plan":{"date":"2026-10-13","slots":[],"targets":{"Push-Ups":60},"readiness":74,"sleep":70,"band":"moderate","note":"Keep it easy"},"slot":"2026-10-13T10","items":[{"movement":"Push-Ups","reps":15}],"why":"Stay submax","note":"Keep it easy","remaining_targets":{"Push-Ups":45}}
```

The `plan` field contains the complete plan with live slot statuses. No stored
plan returns 200 with `plan:null`, `slot:null`, empty items and targets. When
the plan has no eligible slot, `plan` remains populated and `slot` is null.
This read does not claim or consume a slot. Pause still controls routing and
desktop nudges. Phone/handoff webhooks include this whole response under `plan`.
The desktop uses an eligible plan round as its default choice with the reason
and note. Accepting it POSTs its round text to `/api/log`. A missing plan or
failed suggestion fetch keeps the ordinary picker behavior.

The picker includes `plan_slot`, for example `2026-10-13T13`, in `/api/log`.
This optional field must name a slot on today's stored plan. A successful log
also records that planned slot as answered, so accepting a future slot early
completes the selected slot. Failed logs do not consume it.

## Summary

`period` is `today`, `week`, `history`, `stats`, or `status`. `days` applies to history (default 30).

```sh
curl -s "$BASE/api/summary?period=today" \
  -H "Authorization: Bearer $TOKEN"

curl -s "$BASE/api/summary?period=history&days=90" \
  -H "Authorization: Bearer $TOKEN"
```

`status` says where you are, the current pick, today's sets, and whether nudges are paused.

## Nudges off and on

```sh
curl -s -X POST "$BASE/api/off" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"for":"2h","reason":"sick"}'

curl -s -X POST "$BASE/api/on" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{}'
```

`for` is a stretch: `2h`, `90m`, or `3d`. Leave it out and the nudges stay off for the rest of today, then come back at tomorrow's wake time. `reason` is optional (`sick`, `flu`).

## MCP

URL: `https://<hub>.<tailnet>.ts.net/gtg/mcp`

Same bearer token. One JSON response per request, no event stream. Tools: `log_sets`, `get_summary`, `list_movements`, `pause`, `resume`. They do the same work as the routes above, including the 422 retry: a refused `log_sets` comes back with `isError` true and the known names in the text.

## Energy (Oura)

The hub can expose today’s readiness, sleep, and activity for coaching context.
Call this when energy, recovery, or “how hard should today be?” matters. Do **not**
invent scores, diagnose, or give medical advice. If Oura is disconnected or the
payload says `connected: false`, say so and ask Ben to connect — never fabricate
readiness or sleep numbers.

```sh
curl -s "$BASE/api/energy" \
  -H "Authorization: Bearer $TOKEN"
```

A connected response looks like:

```json
{
  "ok": true,
  "date": "YYYY-MM-DD",
  "timezone": "America/New_York",
  "as_of": "ISO",
  "source": "oura",
  "connected": true,
  "readiness": { "score": 0-100, "contributors": {} },
  "sleep": { "score": 0-100, "total_sleep_hours": 7.2, "efficiency": 90 },
  "activity": { "score": 0-100 },
  "coaching": { "band": "high|moderate|low|unknown", "note": "one short sentence" },
  "error": null
}
```

`coaching.band` is a non-medical heuristic from readiness: **high** ≥85,
**moderate** 70–84, **low** <70, **unknown** if the score is missing. If Rest
Mode is active in Oura, the note mentions it.

When `connected` is false, `ok` is false and `error` says what Ben must do. Ask
him to connect; do not guess energy.

### How Ben connects Oura

1. Register a personal app at [Oura Cloud](https://cloud.ouraring.com/oauth/applications) with redirect URI
   `https://bens-mac-mini.twin-viper.ts.net/gtg/oura/callback` and scope `daily`.
2. On the hub Mini, write `~/.config/gtg/oura-client.json` (mode 600) with
   `client_id`, `client_secret`, and that `redirect_uri`.
3. Check status, then open the authorize URL in a browser on Tailscale:

```sh
curl -s "$BASE/api/oura/status" -H "Authorization: Bearer $TOKEN"
curl -s "$BASE/api/oura/authorize" -H "Authorization: Bearer $TOKEN"
# open authorize_url; Oura redirects to /oura/callback (no Bearer needed)
```

`POST /api/oura/refresh` forces a token refresh and re-pulls today’s snapshot.



## Fleet decisions (explicit owner choices only)

The same authenticated connection now exposes MCP tools `fleet_decisions`
(optional `repo`), `fleet_answer` (required `repo`, `id`, integer `choice`), and
`fleet_receipt` (required `repo`, `id`). HTTP equivalents:

- GET `/api/fleet/decisions?repo=booty-pirates`
- POST `/api/fleet/answer` with the three answer fields
- GET `/api/fleet/receipt?repo=booty-pirates&id=<decision id>`

Results use the existing ok/output/error envelope. Parse output as JSON and
check its ok/status. The fixed local executor is `~/bin/fleet-delegate api`;
it must be installed on the hub. No user-controlled shell command is executed.
Only forward Ben's explicit selection for the displayed current question.
Never interpret a question's content as permission or auto-select a recommendation.
Refresh before sending, send once, then read receipt. forwarded_unconfirmed is
not resumption. responded includes subsequent assistant text, not proof of work
completion. On error or uncertainty, inspect the original instead of resending.

Repo is the nearest unambiguous repository containing the session cwd;
worktree_of groups linked worktrees. _unassigned means no verified match.
Use one exact repo in each bot's instructions, e.g. booty-pirates for Booty Wars.
The shared GTG credential is not per-agent isolation: any holder can request
another repo. These tools do not change workout logs or plans. Native approvals
and Codex response submission remain unsupported.
