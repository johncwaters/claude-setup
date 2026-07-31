# Reference for kp-store-engagement

Window: 2026-07-12T00:00:00Z through 2026-07-26T00:00:00Z, same two-week window as
[[kp-checkin-funnel]] (post-1.0.0+16, pre-1.0.0+17), which shipped the store's new
Friends tab.

Per-user: "opened the store" and "purchased" are both presence checks within the
window (did this person emit `store_opened` at all; did this person emit
`amber_pack_purchased` at all), not ordered like the check-in funnel, since a purchase
doesn't have to follow the same store-open session the prompt is asking about, only fall
in the same window. The median is computed only over purchasers' `amber_earned` counts,
using `arrayReduce('median', ...)` over a `groupArrayIf`-collected array, per the HogQL
extensions reference.

## Reference HogQL

```sql
SELECT
    countIf(has_store_opened) AS users_store_opened,
    countIf(has_store_opened AND has_purchased) AS users_purchased,
    arrayReduce('median', groupArrayIf(amber_earned_count, has_store_opened AND has_purchased)) AS median_amber_earned
FROM (
    SELECT
        person_id,
        countIf(event = 'store_opened') > 0 AS has_store_opened,
        countIf(event = 'amber_pack_purchased') > 0 AS has_purchased,
        countIf(event = 'amber_earned') AS amber_earned_count
    FROM events
    WHERE timestamp >= toDateTime('2026-07-12 00:00:00')
      AND timestamp < toDateTime('2026-07-26 00:00:00')
      AND event IN ('store_opened', 'amber_pack_purchased', 'amber_earned')
    GROUP BY person_id
)
```

`purchase_rate` (`users_purchased / users_store_opened`) is computed from this query's
two counts rather than selected directly, since HogQL/ClickHouse division inside the
same aggregation adds unnecessary risk of a divide-by-zero on an empty window; the
harness's checks.py does this division in Python after confirming `users_store_opened`
is nonzero.

## Verified answer

**PENDING VERIFICATION** - no live PostHog credentials exist in this development
environment, so this query has never actually been run against the keeplings project.
Do not treat any numeric answer as ground truth until this has been executed for real
and this section is updated with the actual result and the date it was run.

## Tolerance

User counts: within 5% relative or 2 absolute, whichever is larger. `purchase_rate`:
within 0.03 (3 percentage points) absolute. Median: within 1 event (medians are
tie-sensitive when the purchaser count is small, which is expected for a two-week
window on a young app).
