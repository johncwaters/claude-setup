# Third-party content

Most of this repo is original work. The paths below are vendored from upstream
projects and remain under their upstream licenses, not this repo's.

| Path | Upstream | License |
|---|---|---|
| `skills/impeccable/` | [pbakaus/impeccable](https://github.com/pbakaus/impeccable), `skill/` | Apache-2.0 |
| `skills/posthog-querying/` | [PostHog/posthog](https://github.com/PostHog/posthog), `products/posthog_ai/skills/querying-posthog-data/` | MIT |
| `skills/ai-slop-cleaner/` | [Yeachan-Heo/oh-my-claudecode](https://github.com/Yeachan-Heo/oh-my-claudecode), `skills/ai-slop-cleaner/` | MIT |
| `evals/bundles/snapshots/llms-txt.md` | [posthog.com/llms.txt](https://posthog.com/llms.txt), generated from [PostHog/posthog.com](https://github.com/PostHog/posthog.com) `contents/` | MIT |
| `setup/fonts/` | [CommitMono](https://commitmono.com) | SIL Open Font License 1.1 |

All five permit redistribution with attribution. Required notices follow.

## skills/impeccable/ (Apache-2.0)

Vendored from https://github.com/pbakaus/impeccable (`skill/`). This is a modified
snapshot: some upstream reference files are absent, some local reference files have
no upstream counterpart, and retained files diverge from current upstream text.

```
Copyright 2025 Paul Bakaus

Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed
under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
CONDITIONS OF ANY KIND, either express or implied. See the License for the
specific language governing permissions and limitations under the License.
```

Attribution carried forward from the upstream `NOTICE.md`: upstream's
`skill/reference/ios.md` and `skill/reference/android.md` are distilled from
[ehmo/platform-design-skills](https://github.com/ehmo/platform-design-skills)
(MIT, author ehmo). Neither file is vendored here, so this notice is
informational rather than an obligation attaching to the vendored subset.

Apache-2.0 section 4(a) requires recipients of a redistribution to receive a
copy of the License; the verbatim Apache-2.0 text ships at
`skills/impeccable/LICENSE` (byte-identical to upstream's LICENSE file).

## skills/posthog-querying/ (MIT)

Vendored from https://github.com/PostHog/posthog at
`products/posthog_ai/skills/querying-posthog-data/`, renamed and snapshotted at an
earlier upstream revision. PostHog's root `LICENSE` places everything outside `ee/`
under the MIT Expat license; `products/` is outside `ee/`.

`skills/posthog-error-triage/` is original to this repo. It is not vendored. It
names PostHog MCP tools and PostHog skill slugs so it interoperates with them, and
no upstream copy of it exists.

## evals/bundles/snapshots/llms-txt.md (MIT)

A pinned snapshot of https://posthog.com/llms.txt, fetched 2026-07. That file is
generated at build time from the docs pages under `contents/` in
https://github.com/PostHog/posthog.com. The posthog.com `LICENSE` splits the repo:
content outside `contents/` is not licensed for reuse, and content inside
`contents/` carries the MIT grant reproduced below. This snapshot derives from the
`contents/` side.

## skills/ai-slop-cleaner/ (MIT)

Derived from https://github.com/Yeachan-Heo/oh-my-claudecode at
`skills/ai-slop-cleaner/`. Substantially reworded here (upstream's OMC-specific and
Ralph-workflow material removed), but the same workflow and structure.

## MIT notice

Applies to `skills/posthog-querying/`, `evals/bundles/snapshots/llms-txt.md`, and
`skills/ai-slop-cleaner/`, under the copyrights listed below.

```
Copyright (c) 2020-2026 PostHog Inc.      (skills/posthog-querying/)
Copyright (c) 2020-2025 PostHog Inc.      (evals/bundles/snapshots/llms-txt.md)
Copyright (c) 2025 Yeachan Heo            (skills/ai-slop-cleaner/)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

Everything else (compiled-commit, hooks, hud, setup scripts, agents, commands,
posthog-error-triage, code-review and release skills) is original to this repo.
