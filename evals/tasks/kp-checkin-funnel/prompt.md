Since 1.0.0+16 shipped the home-screen widget and the gentle check-in nudges, I want to
know how the nudge ladder is actually converting: of the nudges that got armed, how many
went on to fire (inferred), and of those, how many got opened, over 2026-07-12 through
2026-07-25 (inclusive).

Do this per-user, not per-event: a rung can arm/fire/open more than once for the same
person over two weeks, and I don't want one engaged user's repeat cycles inflating the
funnel. A person counts as having reached a stage only if that stage's event happened at
or after their earliest event in the previous stage.

Write your numbers, plus the exact HogQL you ran, to `answer.json` in the workspace
root, as:

```json
{
  "window": {"start": "2026-07-12T00:00:00Z", "end": "2026-07-26T00:00:00Z"},
  "users_armed": <integer>,
  "users_fired": <integer>,
  "users_opened": <integer>,
  "armed_to_fired_rate": <number>,
  "fired_to_opened_rate": <number>,
  "hogql": "<the query text>"
}
```
