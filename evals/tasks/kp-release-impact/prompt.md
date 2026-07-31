Keeplings shipped release 1.0.0+16 on 2026-07-12. I want to know whether it actually
moved the needle on usage: compare daily event volume and average daily active users in
the 7 days before the rollout (2026-07-05 through 2026-07-11, inclusive) against the 7
days starting the day of rollout (2026-07-12 through 2026-07-18, inclusive), using the
`$app_version` super property to confirm which build events came from, where useful.

Write your numbers, plus the exact HogQL you ran to get them, to `answer.json` in the
workspace root, as:

```json
{
  "before_window": {"start": "2026-07-05T00:00:00Z", "end": "2026-07-12T00:00:00Z"},
  "after_window": {"start": "2026-07-12T00:00:00Z", "end": "2026-07-19T00:00:00Z"},
  "before_event_count": <integer>,
  "after_event_count": <integer>,
  "before_dau_avg": <number>,
  "after_dau_avg": <number>,
  "hogql": "<the query text>"
}
```

`before_dau_avg`/`after_dau_avg` are the average of the daily unique-user counts across
each window: divide the sum of daily unique-user counts by the 7 calendar days of the
window, counting days with no events as zero (not a single window-wide unique count, and
not an average over only the days that had events).
