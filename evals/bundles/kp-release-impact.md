<!--
Purpose: HogQL for before/after release comparisons: querying events by $app_version, daily active users and event volume aggregations, date range handling, HogQL syntax essentials.
Sources: posthog.com/docs/sql.md, /docs/sql/expressions.md, /docs/sql/clickhouse-functions.md, /docs/data-warehouse/sql/useful-functions.md, /docs/data-warehouse/sql/variables.md, /docs/sql/aggregations.md
Fetched: 2026-07-30
-->

# HogQL for release before/after comparisons

## What HogQL is

PostHog's SQL flavor ("HogQL" is the internal name for SQL access) wraps ClickHouse SQL with simplified property access, null handling, and viz integration. Query it via the SQL editor UI, or the API:

```bash
curl -X POST "<ph_app_host>/api/projects/:project_id/query" \
  -H "Content-Type: application/json" -H "Authorization: Bearer <personal_api_key>" \
  -d '{"query": {"kind": "HogQLQuery", "query": "SELECT event, COUNT() FROM events GROUP BY event ORDER BY COUNT() DESC"}, "name": "..."}'
```

Response shape: `{ query, results: any[][], types, columns, hogql, clickhouse }`.

## Accessing properties

- Event properties: `properties.$app_version` or `properties['$app_version']` (bracket form for dynamic/JSON-nested keys).
- Person properties: `person.properties.<key>`.
- Core columns always available: `event`, `timestamp`, `distinct_id`, `person_id`, `elements_chain`.
- Custom property keys have no `$` prefix; PostHog's own properties always do.
- Property identifiers must be known at query time (static in the query text); for dynamic access use `JSONExtract*` on the raw `properties` field.

## Filtering by app_version

```sql
SELECT event, COUNT() AS n
FROM events
WHERE properties.$app_version = '2.4.0'
  AND timestamp >= toDateTime('2026-07-01 00:00:00')
  AND timestamp < toDateTime('2026-07-15 00:00:00')
GROUP BY event
ORDER BY n DESC
```

Before/after comparison pattern: run the same query twice with two `[start, end)` windows (pre-release, post-release), or compute both in one query with conditional aggregation:

```sql
SELECT
  sumIf(1, properties.$app_version = '2.3.0') AS before_count,
  sumIf(1, properties.$app_version = '2.4.0') AS after_count
FROM events
WHERE event = 'checkout_completed'
```

`sumIf(column, cond)` / `countIf(cond)` are the general "conditional aggregate" pattern for computing multiple cohort-style numbers in a single pass instead of separate queries.

## Date range handling

Functions: `now()`, `today()`, `yesterday()`, `toDate`, `toDateTime`, `toDateTime64`, `dateDiff('unit', start, end)`, `interval` (e.g. `timestamp + interval 30 day`), `toStartOfDay`, `toStartOfWeek`, `toStartOfMonth`, `toStartOfInterval`, `toDayOfWeek`, `toHour`, `formatDateTime(ts, '%a %b %T')` (MySQL-style format string), `parseDateTimeBestEffort('4-Dec-2023')`.

```sql
WHERE timestamp > now() - interval 1 day
```

**Timezone gotcha (verified against live docs):** date literals like `toDateTime('2026-07-17 06:42:00')` parse in the **project's timezone, not UTC**. Pasting a UTC timestamp directly into a literal can silently shift it by hours, a recency filter built this way can return zero rows and look like missing data rather than a bug. For relative windows prefer `now() - interval N unit`; for an absolute instant pass the timezone explicitly: `toDateTime('2026-07-17 06:42:00', 'UTC')`.

Dashboard/insight-driven date ranges: if the query is parameterized by a dashboard's date picker rather than hardcoded, use the variables `filters.dateRange.from` / `filters.dateRange.to`:

```sql
SELECT * FROM events
WHERE event = {variables.event_names} AND timestamp >= {filters.dateRange.from} AND timestamp < {filters.dateRange.to}
```

Custom SQL variables (List, string, etc.) are created in the SQL editor's Variables toolbar and referenced as `{variables.<name>}`.

## DAU and event volume aggregations

```sql
SELECT
  toStartOfDay(timestamp) AS day,
  uniqExact(distinct_id) AS daily_active_users,
  count() AS event_volume
FROM events
WHERE event = '$pageview'
  AND timestamp >= toDateTime('2026-07-01 00:00:00')
GROUP BY day
ORDER BY day
```

`uniqExact` gives an exact distinct count (slower, correct); `uniq` gives an approximate distinct count (faster, use when a close approximation is acceptable at higher volume). `count()` counts rows; `count(distinct)` is sugar for `uniqExact`. Person-level DAU should generally use `person_id` instead of `distinct_id` if a user can have multiple distinct IDs (e.g. anonymous-then-identified); the fetched docs show `distinct_id` in examples but note `person_id` is available on the same table.

## Other useful aggregations for release comparisons

`avg`, `sum`, `min`, `max`, `median`/`medianExact`, `quantile`/`quantiles` (percentiles), all support an `If` suffix (`avgIf`, `sumIf`, ...) for conditional aggregation without a subquery or self-join.

## First-occurrence-per-user pattern (useful for "first time after release" style questions)

```sql
SELECT properties.$current_url AS current_url, count() AS url_count
FROM events
WHERE event = '$pageview'
  AND (distinct_id, timestamp) IN (
    SELECT distinct_id, min(timestamp) FROM events WHERE event = '$pageview' GROUP BY distinct_id
  )
GROUP BY current_url
ORDER BY url_count DESC
```

The `(distinct_id, timestamp) IN (SELECT distinct_id, min(timestamp) ... GROUP BY distinct_id)` idiom is the documented way to restrict a query to each user's first matching event; swap `min` for `max` to get each user's most recent matching event instead.

## Query API mechanics (running these programmatically)

Top-level request fields: `query` (required, must set `kind`), `name` (strongly recommended for `query_log` debugging), `client_query_id`, `refresh` (caching/execution mode), `filters_override`, `variables_override`.

`refresh` controls sync vs. async execution and caching: `blocking` (default: sync unless cache is fresh), `async`, `force_blocking`, `force_async`, `force_cache` (never recompute), `lazy_async` (extended cache period), `async_except_on_cache_miss`. Async responses return `{"query_status": {"id": ..., "complete": false}}` immediately; poll `GET /api/projects/:project_id/query/:query_id/` until `complete: true`. Cancel a running query with `DELETE` on that same endpoint.

Query kinds beyond `HogQLQuery`: `EventsQuery`, `TrendsQuery`, `FunnelsQuery`, `RetentionQuery`, `PathsQuery`, these mainly power PostHog's own UI, `HogQLQuery` is the one meant for custom programmatic queries.

Rate limits (project-level): 2400 requests/hour, 240/minute, 3 concurrent queries, 60 threads/query, 10s max execution time (execution time, not HTTP duration). Exceeding concurrency queues the query for up to 30s before it executes, is canceled, or times out.

## Performance tips for large event-table scans (directly relevant to before/after release scans)

1. **Always bound by time range**, prefer `now() - INTERVAL N DAY` over unbounded scans; the shorter the range the cheaper the query.
2. **Don't scan `events` more than once per query.** Two CTEs each independently filtering the raw `events` table (e.g. one per app_version window) doubles the I/O; if the same base rows are reused across steps, materialize them once first (`/docs/data-warehouse/views/materialize.md`) and query the materialized view for each subsequent step instead of re-hitting `events`.
3. **Name every query** via the `name` parameter (e.g. `"release_2_4_0_dau_comparison"`) for `query_log` debugging and performance tracking, avoid generic names like `query1`.
4. **`OFFSET` pagination is rejected (HTTP 400)** for personal-API-key `/query` requests. Use keyset pagination instead: `WHERE timestamp > '<last_seen_timestamp>' ORDER BY timestamp LIMIT N`. If the goal is bulk export rather than paging through results in an app, use batch exports instead of `/query` entirely.

