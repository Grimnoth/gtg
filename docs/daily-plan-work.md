# Daily plan implementation

1. Add failing HTTP tests for authenticated writes/reads, validation, date overwrite/history, live slot status and target totals. Add picker tests for plan presentation, API logging and fallback.
2. Persist validated daily plans atomically under state/plans/YYYY-MM-DD.json. Reuse the shell movement registry. Calculate progress from log.tsv and slots.tsv under the hub write lock. Return the current or next future pending slot and remaining targets.
3. Fetch suggestions with a bounded authenticated GET before the desktop dialog. Display the whole round and coaching note; send accepted plan rounds through /api/log. Keep the existing no-plan/unreachable fallback and pause guards. Attach the same suggestion to phone/handoff webhook payloads.
4. Run scratch-only suites, review the final diff, document endpoint contracts, deploy the hub and laptop, and verify authenticated live reads without adding a fictitious workout or coaching plan.

Slot completion follows the router's hourly contract: any non-skip set in that hour, or answered log/elsewhere, completes the slot. Explicit skip/off or a skip route skips it; snooze stays pending. Completed logs take precedence over skips. Past unanswered slots remain pending in history but are not suggested for a new hour. Targets sum reps, or seconds for a duration-only movement, over the plan date. No plan returns HTTP 200 with plan:null; an exhausted plan returns slot:null.
