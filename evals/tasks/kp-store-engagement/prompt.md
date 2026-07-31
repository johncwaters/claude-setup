Of everyone who opened the store between 2026-07-12 and 2026-07-25 (inclusive), what
fraction went on to buy an Amber pack in that same window? And for the people who did
buy, what's the median number of `amber_earned` events they logged in that window?
Trying to get a read on whether store visits convert to real purchases, and whether
purchasers are also our most economically active players or a totally different group.

Write your numbers, plus the exact HogQL you ran, to `answer.json` in the workspace
root, as:

```json
{
  "window": {"start": "2026-07-12T00:00:00Z", "end": "2026-07-26T00:00:00Z"},
  "users_store_opened": <integer>,
  "users_purchased": <integer>,
  "purchase_rate": <number>,
  "median_amber_earned_events_per_purchaser": <number>,
  "hogql": "<the query text>"
}
```
