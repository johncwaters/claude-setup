@AGENTS.md

<routing>
Main session loop only; subagents skip per `<scope>`. This section overrides the `<routing>` section in AGENTS.md per its precedence rule: apply that section as written, amended for a work machine as follows.
- Claude models only. Never dispatch to external model CLIs (Codex, Grok, Gemini, or any non-Claude tool), even if guidance merged from another profile mentions them. Decision order rules 0, 1, 1a, 1b, and 1c do not apply; every delegated task starts at rule 2. The pre-rule question (does this need a model at all?) and rule 5 (eval-backed changes) still apply.
- The enforce-spawn-model PreToolUse hook denies any spawn with a missing or fable model.
</routing>

<org_workflow>
Work never promotes: the commit runner stops at the feature branch push; changes reach develop via pull request and reach master via /org-release. The /org-* commands come from an org-internal Claude Code plugin (the `example-org-plugin@example-org` entry in settings.overlay.json); swap the plugin id and command names for your own org's, or drop this section if your org has none.
- Create pull requests with the /org-pull-request skill, not by calling the tracker's create-pull-request tool directly and not via raw git plus manual PR creation; the skill applies the org's PR standards (correct target branch, linked work items, compliant title and description formatting). Pushing the branch with git first is fine.
- The same applies to the other work-item-tracker workflows when a matching plugin skill exists: /org-user-story for epics and stories, /org-bug for bugs, /org-pr-review for reviewing PRs, /org-release for releases. /org-help lists them.
- When verifying claims against code (RCA, PR review, postmortem checks), always `git fetch` and confirm findings on the freshly fetched remote mainline branch (the PR target, such as origin/develop or origin/master) before reporting; local checkouts are often on stale feature branches. Use `git show 'origin/<branch>:<path>'` to inspect without switching branches. Some files may be UTF-16LE; pipe through `iconv -f UTF-16LE -t UTF-8` before grep.
</org_workflow>

<worktree>
Prefer working in a dedicated git worktree; if the session did not start in one, move to one before making changes. Once in a worktree, stay there: do not switch to another worktree or change the working directory out of it mid-task.
</worktree>
