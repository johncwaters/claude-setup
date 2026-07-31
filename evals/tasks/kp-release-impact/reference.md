# Reference for kp-release-impact

Window: 7 days before release 1.0.0+16 (2026-07-05T00:00:00Z through 2026-07-12T00:00:00Z)
versus 7 days starting the day of rollout (2026-07-12T00:00:00Z through
2026-07-19T00:00:00Z). Release 1.0.0+16 merged to `master` on 2026-07-12 (commit
`33b9b0daeb65937c3d66151a93b949ce81e4ab54`, keeplings repo); splitting at the calendar
date rather than the exact merge timestamp (11:03 America/Denver) mixes a few hours of
pre-rollout traffic into the "after" bucket on day one, which is judged acceptable noise
for a week-over-week directional comparison and is called out here rather than hidden.
The window stays entirely inside 1.0.0+16's own lifetime (1.0.0+17 didn't ship until
2026-07-30), so it isn't contaminated by the next release.

## Reference HogQL

```sql
SELECT
    sumIf(event_count, day_start < toDateTime('2026-07-12 00:00:00')) AS before_event_count,
    sumIf(event_count, day_start >= toDateTime('2026-07-12 00:00:00')) AS after_event_count,
    avgIf(daily_users, day_start < toDateTime('2026-07-12 00:00:00')) AS before_dau_avg,
    avgIf(daily_users, day_start >= toDateTime('2026-07-12 00:00:00')) AS after_dau_avg
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

## Verified answer

**PENDING VERIFICATION** - no live PostHog credentials exist in this development
environment, so this query has never actually been run against the keeplings project.
The numbers above are the query design only, not a checked result. Do not treat any
numeric answer as ground truth until this has been executed for real and this section
is updated with the actual result and the date it was run.

## Tolerance

Event counts: within 5% relative or 2 absolute, whichever is larger (ingestion can lag a
few events across a day boundary). DAU averages: within 5% relative or 0.5 absolute,
whichever is larger.
