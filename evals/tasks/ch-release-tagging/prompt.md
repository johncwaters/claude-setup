Every PostHog event and autocaptured exception from Card Harbor today carries no
indication of which release it came from. Tag every captured event (and every captured
exception) with the running app's version and build as PostHog super properties, so when
something spikes in error tracking I can tell whether it's a regression in what I just
shipped or noise from someone still on an old build.

The version has to come from the actual packaged app (Electron knows its own version at
runtime) rather than a string typed in by hand somewhere in the source, since a
hand-typed value will drift the first time I forget to update it after a version bump.

Should typecheck clean (`npm run typecheck`) and shouldn't change anything for a build
that has no PostHog token configured.
