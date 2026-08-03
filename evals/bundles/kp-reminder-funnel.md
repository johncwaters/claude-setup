<!--
Purpose: funnel analysis in HogQL/PostHog for per-user sequential conversion across three custom events: windowing, distinct-count semantics, building this in SQL when the UI funnel insight isn't the target.
Sources: posthog.com/docs/product-analytics/funnels.md, /docs/sql.md, /docs/sql/expressions.md, /docs/sql/aggregations.md, /docs/api/queries.md
Fetched: 2026-07-30
-->

# Sequential conversion (funnel) across custom events in HogQL

## PostHog's funnel insight semantics (UI concept, informs correct SQL modeling)

A funnel step is a *user action to perform*, not merely a filter; if you add the same event as two steps, the user must trigger it **twice** to complete both. Default step order options:

- **Sequential** (default): step B must happen after step A, other events may occur in between.
- **Strict order**: step B must happen *immediately* after step A with nothing in between.
- **Any order**: steps can complete in any sequence.

Conversion rate has two framings: **overall** (each step vs. the first step) and **relative** (each step vs. the immediately preceding step); relative conversion is what highlights the single worst-friction step.

**First-ever occurrence vs. first occurrence matching filters** matters when replicating this in SQL: "first-ever" anchors on a user's literal first event of that type (if it doesn't match your step's filter, or falls outside the date range, that user is dropped from the funnel entirely, even if they later perform a matching event); "first occurrence matching filters" instead ignores earlier non-matching events of the same type and anchors on the first one that *does* match.

## HogQL: windowFunnel exists but is undocumented in examples

`windowFunnel` is listed in PostHog's supported ClickHouse aggregate functions (alongside `uniq`, `median`, `quantile`, etc.) as a HogQL-callable aggregate, but no fetched PostHog doc page shows a worked call signature or example query using it. Treat this as a doc gap: don't guess its arguments from ClickHouse general knowledge, since that would violate "every claim must come from a fetched page." The self-join pattern below relies only on documented HogQL (subqueries, `min()`, `dateDiff`, `uniqExact`) and is safe to build from what's fetched.

## Building 3-event sequential conversion via self-joins (documented primitives only)

Get each user's first timestamp per step event, restricted to the date range, then require step-2 timestamp after step-1 and step-3 after step-2 within a window:

```sql
WITH
  step1 AS (
    SELECT distinct_id, min(timestamp) AS t1
    FROM events
    WHERE event = 'checked_in' AND timestamp >= toDateTime('2026-07-01 00:00:00')
    GROUP BY distinct_id
  ),
  step2 AS (
    SELECT distinct_id, min(timestamp) AS t2
    FROM events
    WHERE event = 'logged_meal' AND timestamp >= toDateTime('2026-07-01 00:00:00')
    GROUP BY distinct_id
  ),
  step3 AS (
    SELECT distinct_id, min(timestamp) AS t3
    FROM events
    WHERE event = 'shared_progress' AND timestamp >= toDateTime('2026-07-01 00:00:00')
    GROUP BY distinct_id
  )
SELECT
  uniqExact(step1.distinct_id) AS started,
  uniqExact(step2.distinct_id) AS reached_step2,
  uniqExact(step3.distinct_id) AS reached_step3
FROM step1
LEFT JOIN step2 ON step1.distinct_id = step2.distinct_id AND step2.t2 > step1.t1
LEFT JOIN step3 ON step2.distinct_id = step3.distinct_id AND step3.t3 > step2.t2
```

This implements **sequential** semantics (any gap allowed between steps) using each user's *first* qualifying occurrence per step, i.e. the "first occurrence matching filters" mode, since the `WHERE event = ...` filter is applied before taking `min(timestamp)`.

To add a **conversion window** (e.g. must reach step 2 within 7 days of step 1), add to the join condition: `AND step2.t2 <= step1.t1 + interval 7 day` (uses the documented `interval` arithmetic operator).

To switch to **strict order** (nothing else in between), you'd need to additionally verify no *other* tracked event exists for that user between `t1` and `t2`, this requires a further anti-join or `NOT EXISTS`-style subquery against the full `events` table; no fetched doc page shows this pattern for HogQL specifically, note as a gap if the task needs strict-order semantics.

## Distinct-count semantics

- `uniqExact(distinct_id)`: exact distinct count, slower, correct.
- `uniq(distinct_id)`: approximate distinct count (HyperLogLog-style), faster, prefer at high volume when an approximation is acceptable.
- `count()`: counts rows, not users, don't use it in place of `uniqExact` for a funnel step's headcount or you'll double count users with multiple qualifying events.
- Conversion rate arithmetic: `reached_step3 / started` as a float; multiply by 100 for a percentage. `sumIf(1, cond) / sumIf(1, cond2)` is the documented general pattern for ratio metrics without a self-join, useful if a per-step ratio can be computed from flags instead of timestamps.

## Conversion rate bucketed over time (mirrors the UI's "historical trends" funnel view)

The funnel insight's **historical trends** graph type shows conversion rate for users who entered on a given date, useful for checking whether a change improved conversion. Reproduce the bucketing with `toStartOfWeek`/`toStartOfDay` on each cohort's entry timestamp:

```sql
SELECT
  toStartOfWeek(step1.t1) AS cohort_week,
  uniqExact(step1.distinct_id) AS started,
  uniqExact(step3.distinct_id) AS completed,
  uniqExact(step3.distinct_id) / uniqExact(step1.distinct_id) AS conversion_rate
FROM step1
LEFT JOIN step3 ON step1.distinct_id = step3.distinct_id AND step3.t3 > step1.t1
GROUP BY cohort_week
ORDER BY cohort_week
```

(`step1`/`step3` refer to the CTEs defined above.) The UI's "hide incomplete periods" option exists because a recent week's users may not have had time to convert yet and would otherwise drag the trend down; when reproducing this in raw SQL, apply the same judgment by excluding buckets too close to `now()` for whatever your conversion window is.

## Doc gap notes

1. No worked `windowFunnel()` HogQL example anywhere in fetched pages, its argument order/signature should not be asserted without checking further (e.g. a live PostHog SQL editor autocomplete/error message), only its existence as a supported aggregate is confirmed.
2. No fetched page shows a strict-order (no-events-in-between) HogQL pattern; the self-join approach above only covers sequential and would need an added anti-join subquery for strict order.
