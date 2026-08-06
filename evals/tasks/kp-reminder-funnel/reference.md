# Reference for kp-reminder-funnel

Window: 2026-07-12T00:00:00Z through 2026-07-26T00:00:00Z, two weeks starting the day
1.0.0+16 (home-screen widget, reminders) shipped, ending before 1.0.0+17 rolled out on
2026-07-30.

Retired from the original design: this task was originally kp-checkin-funnel, tracking
`checkin_nudge_armed` / `checkin_nudge_fired_inferred` / `checkin_nudge_opened`. Those
events are not exercised by this eval: nudge instrumentation didn't ship until release
1.0.0+17 on 2026-07-30, after this task's own window ends. The original checkin-nudge
funnel should return as a freshly captured task once its window has data behind it. This
directory (and the blinded bundle it uses, renamed not rewritten) now covers a real,
same-shaped per-user sequential funnel: `reminder_created` then `habit_confirmed`.

Per-user, sequential: a person counts as "created" only if their earliest
`reminder_created` falls in the window, and as "confirmed after" only if their earliest
`habit_confirmed` in the window is at or after that first creation. This intentionally
undercounts a person who confirmed before creating a reminder and never confirmed again;
that matches the original checkin-nudge semantics, which also only counted a
later-in-sequence event as qualifying.

## Reference HogQL

```sql
SELECT
    countIf(has_created) AS users_created_reminder,
    countIf(has_created AND has_confirmed_after) AS users_confirmed_after
FROM (
    SELECT
        person_id,
        minIf(timestamp, event = 'reminder_created') AS first_created,
        minIf(timestamp, event = 'habit_confirmed') AS first_confirmed,
        first_created != toDateTime(0) AS has_created,
        (first_confirmed != toDateTime(0) AND first_confirmed >= first_created) AS has_confirmed_after
    FROM events
    WHERE timestamp >= toDateTime('2026-07-12 00:00:00')
      AND timestamp < toDateTime('2026-07-26 00:00:00')
      AND event IN ('reminder_created', 'habit_confirmed')
    GROUP BY person_id
)
```

`minIf` over no matching rows returns the type's zero value for a `DateTime` column
(1970-01-01), so `!= toDateTime(0)` is the standard idiom for "this person has no such
event"; there's no ambiguity with a real 2026 event ever landing at the epoch. With only
`reminder_created`/`habit_confirmed` in the event filter, "first `reminder_created` in
window" means within-window first, which is what the prompt asks.

## Verified answer

Verified 2026-07-31 by executing the query above against the private project this task
was captured from. Exact values (`users_created_reminder`, `users_confirmed_after`,
`conversion_rate`) are withheld from the public repo and live in
`evals/verified-answers.local.json` (gitignored); checks.py does not read them, it
re-executes this reference query at scoring time and compares against whatever
production returns then.

## Tolerance

User counts (`users_created_reminder`/`users_confirmed_after`): within 2 absolute.
Conversion rate: within 0.03 (3 percentage points) absolute.
