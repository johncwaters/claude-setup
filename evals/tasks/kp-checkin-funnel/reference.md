# Reference for kp-checkin-funnel

Window: 2026-07-12T00:00:00Z through 2026-07-26T00:00:00Z, two weeks starting the day
1.0.0+16 (home-screen widget, gentle nudges) shipped, ending before 1.0.0+17 rolled out
on 2026-07-30.

Per-user, sequential: a person counts as "fired" only if their earliest
`checkin_nudge_fired_inferred` is at or after their earliest `checkin_nudge_armed`, and
as "opened" only if their earliest `checkin_nudge_opened` is at or after that qualifying
fired timestamp. This intentionally undercounts a person who armed, fired, cleared,
re-armed, and only then opened; see `checkInNudgeCleared`/`re_armed` in
`analytics_service.dart` for why re-arming exists at all. A stricter same-rung,
same-cycle join would need to key on the rung's `kind`/`ladder` pairing per cycle, which
this reference intentionally does not attempt (documented limitation, not an oversight).

## Reference HogQL

```sql
SELECT
    countIf(has_armed) AS users_armed,
    countIf(has_armed AND has_fired) AS users_fired,
    countIf(has_armed AND has_fired AND has_opened) AS users_opened
FROM (
    SELECT
        person_id,
        minIf(timestamp, event = 'checkin_nudge_armed') AS first_armed,
        minIf(timestamp, event = 'checkin_nudge_fired_inferred') AS first_fired,
        minIf(timestamp, event = 'checkin_nudge_opened') AS first_opened,
        first_armed != toDateTime(0) AS has_armed,
        (first_fired != toDateTime(0) AND first_fired >= first_armed) AS has_fired,
        (first_opened != toDateTime(0) AND (first_fired != toDateTime(0) AND first_fired >= first_armed)
            AND first_opened >= first_fired) AS has_opened
    FROM events
    WHERE timestamp >= toDateTime('2026-07-12 00:00:00')
      AND timestamp < toDateTime('2026-07-26 00:00:00')
      AND event IN ('checkin_nudge_armed', 'checkin_nudge_fired_inferred', 'checkin_nudge_opened')
    GROUP BY person_id
)
```

`minIf` over no matching rows returns the type's zero value for a `DateTime` column
(1970-01-01), so `!= toDateTime(0)` is the standard idiom for "this person has no such
event"; there's no ambiguity with a real 2026 event ever landing at the epoch.

## Verified answer

**PENDING VERIFICATION** - no live PostHog credentials exist in this development
environment, so this query has never actually been run against the keeplings project.
Do not treat any numeric answer as ground truth until this has been executed for real
and this section is updated with the actual result and the date it was run.

## Tolerance

User counts (`users_armed`/`users_fired`/`users_opened`): within 5% relative or 2
absolute, whichever is larger. Conversion rates: within 0.03 (3 percentage points)
absolute.
