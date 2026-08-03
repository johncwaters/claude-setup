<!--
Purpose: HogQL cohort-style analysis: fraction of users who did event A and later also did event B, and medians/percentiles of per-user event counts.
Sources: posthog.com/docs/sql.md, /docs/sql/expressions.md, /docs/sql/aggregations.md, /docs/data-warehouse/sql/useful-functions.md, /docs/data/cohorts.md
Fetched: 2026-07-30
-->

# HogQL: fraction doing A-then-B, and per-user distribution stats

## Doc gap up front

PostHog's cohort docs (`/docs/data/cohorts.md`) cover "did event A then event B" only as a **UI concept** (dynamic cohort "Behavioral" criteria, configured via clicks in the cohorts page), not as HogQL. No fetched page shows a HogQL query computing "fraction of users doing A who later did B." The query below is built only from documented HogQL primitives (subqueries, `min()`, `uniqExact`, arithmetic), not copied from a worked example, because none exists in the fetched docs.

## Fraction of users doing event A who later did event B

```sql
WITH
  did_a AS (
    SELECT distinct_id, min(timestamp) AS t_a
    FROM events
    WHERE event = 'viewed_product'
    GROUP BY distinct_id
  ),
  did_b_after AS (
    SELECT did_a.distinct_id
    FROM did_a
    INNER JOIN (
      SELECT distinct_id, timestamp FROM events WHERE event = 'completed_purchase'
    ) AS b ON b.distinct_id = did_a.distinct_id AND b.timestamp > did_a.t_a
  )
SELECT
  uniqExact(did_a.distinct_id) AS users_did_a,
  uniqExact(did_b_after.distinct_id) AS users_did_a_then_b,
  uniqExact(did_b_after.distinct_id) / uniqExact(did_a.distinct_id) AS fraction
FROM did_a
LEFT JOIN did_b_after ON did_a.distinct_id = did_b_after.distinct_id
```

Notes on this construction (all from documented primitives):
- `min(timestamp)` per `distinct_id` gives each user's first occurrence of event A, matching the documented "first occurrence" subquery idiom (`(distinct_id, timestamp) IN (SELECT distinct_id, min(timestamp) ... GROUP BY distinct_id)` shown in the general SQL docs).
- The `INNER JOIN ... ON b.timestamp > did_a.t_a` requires at least one B event strictly after the user's A timestamp, this is standard SQL join semantics, not a HogQL-specific function.
- Divide two `uniqExact()` aggregates for the fraction; this is the same pattern the docs show for percentage metrics (`sumIf(...) / sumIf(...)`), just with `uniqExact` swapped in since we're counting users, not summing a numeric column.
- Restrict to a date range by adding `AND timestamp >= toDateTime(...)` inside each CTE's `WHERE`.

## Median / percentile of per-user event counts

Two-step shape: aggregate per user first, then aggregate the per-user aggregate.

```sql
SELECT
  median(events_per_user) AS median_events,
  quantile(0.90)(events_per_user) AS p90_events,
  quantile(0.99)(events_per_user) AS p99_events
FROM (
  SELECT distinct_id, count() AS events_per_user
  FROM events
  WHERE event = 'viewed_product'
  GROUP BY distinct_id
)
```

- `median` computes an approximate middle (50th percentile) value.
- `quantile(p)(column)` is the general percentile function, `p` is a float in `[0, 1]`; the docs also list `quantiles` (plural, likely returns multiple percentiles at once) and several ClickHouse-specific median variants (`medianExact`, `medianTDigest`, `medianDeterministic`, etc.) without documenting the differences between them beyond the name, treat the exact/approximate tradeoff (like `uniq` vs `uniqExact`) as the likely distinction but this is not spelled out in the fetched docs, a genuine gap.
- `avg(events_per_user)` for the mean, alongside the median/percentiles, to show skew.

## Distinct-count semantics reminder

`uniqExact` (exact, slower) vs `uniq` (approximate/HyperLogLog, faster); prefer `uniqExact` for a headline "fraction of users" metric where correctness matters more than query latency, matching the general guidance in the supported-aggregations docs.

## Breaking the fraction down by a person/group property

`person.properties.<key>` is accessible in the same query, so the A-then-B fraction can be computed per segment (e.g. per store, plan, or region) in one pass instead of one query per segment value:

```sql
WITH
  did_a AS (
    SELECT distinct_id, person.properties.store_id AS store_id, min(timestamp) AS t_a
    FROM events
    WHERE event = 'viewed_product'
    GROUP BY distinct_id, store_id
  ),
  did_b_after AS (
    SELECT did_a.distinct_id, did_a.store_id
    FROM did_a
    INNER JOIN (
      SELECT distinct_id, timestamp FROM events WHERE event = 'completed_purchase'
    ) AS b ON b.distinct_id = did_a.distinct_id AND b.timestamp > did_a.t_a
  )
SELECT
  did_a.store_id,
  uniqExact(did_a.distinct_id) AS users_did_a,
  uniqExact(did_b_after.distinct_id) AS users_did_a_then_b,
  uniqExact(did_b_after.distinct_id) / uniqExact(did_a.distinct_id) AS fraction
FROM did_a
LEFT JOIN did_b_after ON did_a.distinct_id = did_b_after.distinct_id AND did_a.store_id = did_b_after.store_id
GROUP BY did_a.store_id
```

Grouping by a property pulled from `person.properties` (rather than `properties`, the event-level bag) assumes the segment is a stable attribute of the person, not something that varies event-to-event, use `properties.<key>` instead if the segment can differ between the A event and the B event for the same user.

## Doc gaps summary

1. No HogQL "did A then B" worked example in any fetched page, cohorts docs only describe the equivalent as a clickable UI behavioral filter.
2. No documented distinction between the many `median*`/`quantile*` ClickHouse aggregate variants beyond their names being listed in the supported-aggregations page, only `median` and `quantile(p)(column)` have any usage context (from the SQL expressions "common functions" table).
