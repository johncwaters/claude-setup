# Reference for kp-store-engagement

Window: 2026-07-12T00:00:00Z through 2026-07-26T00:00:00Z, same two-week window as
[[kp-reminder-funnel]] (post-1.0.0+16, pre-1.0.0+17), which shipped the store's new
Friends tab.

Retired from the original design: this task originally asked about `amber_pack_purchased`
conversion, but that event has zero occurrences ever in keeplings production as of
2026-07-31, confirmed 2026-07-31 (no purchase instrumentation has shipped). The purchase
funnel version of this task should return once monetization events actually exist in
production; until then this re-grounds on amber-earning engagement, which does have data.

Per-user: "opened the store" and "engaged" are both presence checks within the window
(did this person emit `store_opened` at all; did this person emit `amber_earned` at
all), not ordered, since earning amber doesn't have to follow the same store-open
session the prompt is asking about, only fall in the same window. The median is computed
only over engaged users' `amber_earned` counts, using `arrayReduce('median', ...)` over
a `groupArrayIf`-collected array, per the HogQL extensions reference.

## Reference HogQL

```sql
SELECT
    countIf(has_store_opened) AS users_store_opened,
    countIf(has_store_opened AND amber_earned_count > 0) AS users_engaged,
    arrayReduce('median', groupArrayIf(amber_earned_count, has_store_opened AND amber_earned_count > 0)) AS median_amber_earned
FROM (
    SELECT
        person_id,
        countIf(event = 'store_opened') > 0 AS has_store_opened,
        countIf(event = 'amber_earned') AS amber_earned_count
    FROM events
    WHERE timestamp >= toDateTime('2026-07-12 00:00:00')
      AND timestamp < toDateTime('2026-07-26 00:00:00')
      AND event IN ('store_opened', 'amber_earned')
    GROUP BY person_id
)
```

`engagement_rate` (`users_engaged / users_store_opened`) is computed from this query's
two counts rather than selected directly, since HogQL/ClickHouse division inside the
same aggregation adds unnecessary risk of a divide-by-zero on an empty window; the
harness's checks.py does this division in Python after confirming `users_store_opened`
is nonzero.

## Verified answer

Executed 2026-07-31 against keeplings production: `users_store_opened=6`,
`users_engaged=6`, `engagement_rate=1.0`, `median_amber_earned=10.5`.

## Tolerance

User counts: within 5% relative or 2 absolute, whichever is larger. `engagement_rate`:
within 0.03 (3 percentage points) absolute. Median: within 1 event (medians are
tie-sensitive when the engaged-user count is small, which is expected for a two-week
window on a young app).
