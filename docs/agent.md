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
