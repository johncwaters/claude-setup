# Reference for kp-release-impact

Window: 7 days before release 1.0.0+16 (2026-07-05T00:00:00Z through 2026-07-12T00:00:00Z)
versus 7 days starting the day of rollout (2026-07-12T00:00:00Z through
2026-07-19T00:00:00Z). Release 1.0.0+16 merged to `master` on 2026-07-12 (commit
`33b9b0daeb65937c3d66151a93b949ce81e4ab54`, keeplings repo); splitting at the calendar
date rather than the exact merge timestamp mixes a few hours of
pre-rollout traffic into the "after" bucket on day one, which is judged acceptable noise
for a week-over-week directional comparison and is called out here rather than hidden.
The window stays entirely inside 1.0.0+16's own lifetime (1.0.0+17 didn't ship until
2026-07-30), so it isn't contaminated by the next release.

## Reference HogQL

```sql
SELECT
    sumIf(event_count, day_start < toDateTime('2026-07-12 00:00:00')) AS before_event_count,
    sumIf(event_count, day_start >= toDateTime('2026-07-12 00:00:00')) AS after_event_count,
    sumIf(daily_users, day_start < toDateTime('2026-07-12 00:00:00')) / 7 AS before_dau_avg,
    sumIf(daily_users, day_start >= toDateTime('2026-07-12 00:00:00')) / 7 AS after_dau_avg
FROM (
    SELECT
        toStartOfDay(timestamp) AS day_start,
        count() AS event_count,
        uniq(person_id) AS daily_users
    FROM events
    WHERE timestamp >= toDateTime('2026-07-05 00:00:00')
      AND timestamp < toDateTime('2026-07-19 00:00:00')
    GROUP BY day_start
)
```

`daily_users` uses `uniq(person_id)`, not `distinct_id`, per the querying skill's
guidance (one person can carry multiple distinct_ids, which would overcount). The
`$app_version` super property mentioned in the prompt is a nice-to-have cross-check
(confirms which build each event's release-tagged rows came from) but is not required
in the reference query itself, since the window split already isolates before/after
without needing the property.

The DAU average divides by a fixed `7` (the calendar days in each window) rather than
`count(day_start)` over the grouped subquery, because a day with zero events never
produces a `day_start` row at all: dividing by the row count silently drops empty days
from the denominator instead of counting them as zero, inflating the average.

## Verified answer

Verified 2026-07-31 by executing the query above against the private project this task
was captured from. Exact values are withheld from the public repo and live in
`evals/verified-answers.local.json` (gitignored); checks.py does not read them, it
re-executes this reference query at scoring time and compares against whatever
production returns then.

The verified window does exercise the fixed-denominator choice above: not every calendar
day in the before window produced a `day_start` row, so averaging over days-with-events
instead of the fixed 7 gives a materially different (wrong) answer. That is why this
reference and the prompt guard against it explicitly rather than treating it as a
hypothetical.

## Tolerance

Event counts: within 5% relative or 2 absolute, whichever is larger (ingestion can lag a
few events across a day boundary). DAU averages: within 5% relative or 0.5 absolute,
whichever is larger.
