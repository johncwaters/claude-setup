Since 1.0.0+16 shipped the home-screen widget and reminders, I want to know how the
reminder-to-confirmation flow is actually converting: of the users who created a
reminder, how many went on to confirm the habit it was for, over 2026-07-12 through
2026-07-25 (inclusive).

Do this per-user, not per-event: a person can create and confirm more than once over two
weeks, and I don't want one engaged user's repeat cycles inflating the funnel. Look at
users whose first `reminder_created` falls in the window, and ask whether they have a
`habit_confirmed` at or after that first creation (within the window).

Write your numbers, plus the exact HogQL you ran, to `answer.json` in the workspace
root, as:

```json
{
  "window": {"start": "2026-07-12T00:00:00Z", "end": "2026-07-26T00:00:00Z"},
  "users_created_reminder": <integer>,
  "users_confirmed_after": <integer>,
  "conversion_rate": <number>,
  "hogql": "<the query text>"
}
```
