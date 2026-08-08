"""Stage 10 PROMOTE: real temp git repos, no git mocking (SPEC tests/ policy)."""

import os
import tempfile
import unittest

from src.failures import Outcome
from src.llm import LlmClient
from src.pipeline import Pipeline, PipelineConfig, find_worktree_for_branch
from tests.helpers import (
    cleanup,
    clone_repo,
    commit_file,
    make_bare_origin,
    make_repo,
    run_git,
    write_file,
    write_flaky_hook,
)


def _make_pipeline(repo, promote=True, no_push=False, paths=None,
                   message="chore: promote test\n\nBody text here."):
    client = LlmClient(mode="live")  # never dispatched: message is always supplied here
    config = PipelineConfig(
        repo=repo,
        llm_client=client,
        no_sync=True,
        skip_deslop=True,
        skip_review=True,
        no_push=no_push,
        promote=promote,
        message=message,
        paths=paths,
        push_retry_delay_sec=0,
    )
    return Pipeline(config)


def _origin_ref(origin, branch):
    proc = run_git(origin, ["rev-parse", f"refs/heads/{branch}"], check=False)
    return proc.stdout.strip() if proc.returncode == 0 else None


def _make_cross_worktree_repo():
    origin = make_bare_origin()
    seed = make_repo()
    local_parent = tempfile.mkdtemp(prefix="cc-test-worktree-parent-")
    holder = os.path.join(local_parent, "holder")
    session = os.path.join(local_parent, "session")
    run_git(seed, ["remote", "add", "origin", origin])
    commit_file(seed, "base.txt", "base\n", "init")
    run_git(seed, ["push", "-u", "origin", "main"])
    run_git(seed, ["checkout", "-b", "develop"])
    run_git(seed, ["push", "-u", "origin", "develop"])
    run_git(seed, ["checkout", "-b", "feature"])
    run_git(seed, ["push", "-u", "origin", "feature"])

    clone_repo(origin, holder)
    run_git(holder, ["branch", "develop", "origin/develop"])
    run_git(holder, ["checkout", "develop"])
    run_git(holder, ["worktree", "add", "-b", "feature", session, "origin/feature"])
    return origin, seed, local_parent, holder, session


def _write_drifting_main_pre_receive_hook(origin):
    hook_path = os.path.join(origin, "hooks", "pre-receive")
    with open(hook_path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(
            "#!/bin/sh\n"
            "while read old new ref_name; do\n"
            "  if [ \"$ref_name\" != \"refs/heads/main\" ]; then\n"
            "    continue\n"
            "  fi\n"
            "  count_file=\"hooks/main-drift-count\"\n"
            "  count=0\n"
            "  [ -f \"$count_file\" ] && count=$(cat \"$count_file\")\n"
            "  count=$((count + 1))\n"
            "  printf \"%s\" \"$count\" > \"$count_file\"\n"
            "  if [ \"$count\" -gt 1 ]; then\n"
            "    continue\n"
            "  fi\n"
            "  tree=$(git rev-parse main^{tree})\n"
            "  new_commit=$(GIT_AUTHOR_NAME=\"Test User\" GIT_AUTHOR_EMAIL=\"test@example.com\" "
            "GIT_COMMITTER_NAME=\"Test User\" GIT_COMMITTER_EMAIL=\"test@example.com\" "
            "git commit-tree \"$tree\" -p \"$(git rev-parse main)\" -m \"origin drift\")\n"
            "  git update-ref refs/heads/main \"$new_commit\"\n"
            "  echo \"rejected: retry after fetch\" >&2\n"
            "  exit 1\n"
            "done\n"
            "exit 0\n"
        )
    os.chmod(hook_path, 0o755)


class PromoteTests(unittest.TestCase):
    def test_find_worktree_for_branch_skips_detached_and_bare_blocks(self):
        porcelain = "\n".join(
            [
                "worktree C:/repo/main",
                "HEAD abc123",
                "branch refs/heads/develop",
                "",
                "worktree C:/repo/detached",
                "HEAD def456",
                "detached",
                "",
                "worktree C:/repo/bare",
                "bare",
                "",
            ]
        )

        self.assertEqual(find_worktree_for_branch(porcelain, "develop"), "C:/repo/main")
        self.assertIsNone(find_worktree_for_branch(porcelain, "feature"))

    def test_full_chain_feature_to_develop_to_main(self):
        origin = make_bare_origin()
        seed = make_repo()
        local_parent = tempfile.mkdtemp(prefix="cc-test-local-parent-")
        local = os.path.join(local_parent, "local")
        try:
            run_git(seed, ["remote", "add", "origin", origin])
            commit_file(seed, "base.txt", "base\n", "init")
            run_git(seed, ["push", "-u", "origin", "main"])
            run_git(seed, ["checkout", "-b", "develop"])
            run_git(seed, ["push", "-u", "origin", "develop"])
            run_git(seed, ["checkout", "-b", "feature"])
            run_git(seed, ["push", "-u", "origin", "feature"])

            clone_repo(origin, local)
            run_git(local, ["branch", "develop", "origin/develop"])
            run_git(local, ["checkout", "-b", "feature", "origin/feature"])
            write_file(local, "base.txt", "base\nfeature change\n")

            result = _make_pipeline(local).run()

            self.assertEqual(result.outcome, Outcome.COMMITTED)
            self.assertEqual(result.promoted, ["develop", "main"])
            self.assertEqual(self.current_branch(local), "feature")
            self.assertEqual(_origin_ref(origin, "develop"), result.commit_hash)
            self.assertEqual(_origin_ref(origin, "main"), result.commit_hash)
        finally:
            cleanup(origin, seed, local_parent)

    def test_develop_missing_is_created_and_pushed(self):
        origin = make_bare_origin()
        seed = make_repo()
        local_parent = tempfile.mkdtemp(prefix="cc-test-local-parent-")
        local = os.path.join(local_parent, "local")
        try:
            run_git(seed, ["remote", "add", "origin", origin])
            commit_file(seed, "base.txt", "base\n", "init")
            run_git(seed, ["push", "-u", "origin", "main"])
            run_git(seed, ["checkout", "-b", "feature"])
            run_git(seed, ["push", "-u", "origin", "feature"])

            clone_repo(origin, local)
            run_git(local, ["checkout", "-b", "feature", "origin/feature"])
            write_file(local, "base.txt", "base\nfeature change\n")

            result = _make_pipeline(local).run()

            self.assertEqual(result.outcome, Outcome.COMMITTED)
            self.assertEqual(result.promoted, ["develop", "main"])
            self.assertIsNotNone(_origin_ref(origin, "develop"))
            self.assertEqual(_origin_ref(origin, "develop"), result.commit_hash)
            self.assertTrue(any("develop branch did not exist" in w for w in result.warnings))
        finally:
            cleanup(origin, seed, local_parent)

    def test_commit_on_develop_promotes_only_mainline(self):
        origin = make_bare_origin()
        seed = make_repo()
        local_parent = tempfile.mkdtemp(prefix="cc-test-local-parent-")
        local = os.path.join(local_parent, "local")
        try:
            run_git(seed, ["remote", "add", "origin", origin])
            commit_file(seed, "base.txt", "base\n", "init")
            run_git(seed, ["push", "-u", "origin", "main"])
            run_git(seed, ["checkout", "-b", "develop"])
            run_git(seed, ["push", "-u", "origin", "develop"])

            clone_repo(origin, local)
            run_git(local, ["checkout", "-b", "develop", "origin/develop"])
            write_file(local, "base.txt", "base\ndevelop change\n")

            result = _make_pipeline(local).run()

            self.assertEqual(result.outcome, Outcome.COMMITTED)
            self.assertEqual(result.promoted, ["main"])
            self.assertEqual(self.current_branch(local), "develop")
            self.assertEqual(_origin_ref(origin, "main"), result.commit_hash)
        finally:
            cleanup(origin, seed, local_parent)

    def test_commit_on_mainline_skips_promotion(self):
        repo = make_repo()
        try:
            commit_file(repo, "base.txt", "base\n", "init")
            run_git(repo, ["branch", "develop"])
            develop_before = run_git(repo, ["rev-parse", "develop"]).stdout.strip()
            write_file(repo, "base.txt", "base\nmain change\n")

            result = _make_pipeline(repo, no_push=True).run()

            self.assertEqual(result.outcome, Outcome.COMMITTED)
            self.assertEqual(result.promoted, [])
            self.assertIn("PROMOTE(skipped)", result.stages_run)
            self.assertTrue(any("directly on main" in w for w in result.warnings))
            develop_after = run_git(repo, ["rev-parse", "develop"]).stdout.strip()
            self.assertEqual(develop_before, develop_after)
        finally:
            cleanup(repo)

    def test_non_ff_conflict_aborts_and_restores_branch(self):
        repo = make_repo()
        try:
            commit_file(repo, "shared.txt", "one\ntwo\nthree\n", "init")
            run_git(repo, ["checkout", "-b", "develop"])
            write_file(repo, "shared.txt", "one\nDEVELOP\nthree\n")
            run_git(repo, ["commit", "-q", "-am", "develop change"])
            run_git(repo, ["checkout", "main"])
            run_git(repo, ["checkout", "-b", "feature"])
            write_file(repo, "shared.txt", "one\nFEATURE\nthree\n")

            result = _make_pipeline(repo, no_push=True).run()

            self.assertEqual(result.outcome, Outcome.PROMOTE_CONFLICT)
            self.assertTrue(result.commit_hash)
            self.assertEqual(self.current_branch(repo), "feature")
            merge_head = run_git(repo, ["rev-parse", "-q", "--verify", "MERGE_HEAD"], check=False)
            self.assertNotEqual(merge_head.returncode, 0)
            self.assertTrue(any("shared.txt" in w for w in result.warnings))
        finally:
            cleanup(repo)

    def test_non_ff_clean_merge_creates_merge_commit(self):
        origin = make_bare_origin()
        seed = make_repo()
        local_parent = tempfile.mkdtemp(prefix="cc-test-local-parent-")
        local = os.path.join(local_parent, "local")
        try:
            run_git(seed, ["remote", "add", "origin", origin])
            commit_file(seed, "a.txt", "a\n", "init")
            run_git(seed, ["push", "-u", "origin", "main"])
            run_git(seed, ["checkout", "-b", "feature"])
            run_git(seed, ["push", "-u", "origin", "feature"])

            clone_repo(origin, local)
            run_git(local, ["checkout", "-b", "feature", "origin/feature"])
            run_git(local, ["branch", "develop", "origin/main"])
            run_git(local, ["checkout", "develop"])
            commit_file(local, "other.txt", "other\n", "develop only")
            run_git(local, ["checkout", "feature"])
            write_file(local, "a.txt", "a\nfeature change\n")

            result = _make_pipeline(local).run()

            self.assertEqual(result.outcome, Outcome.COMMITTED)
            self.assertEqual(self.current_branch(local), "feature")
            second_parent = run_git(local, ["rev-parse", "-q", "--verify", "develop^2"], check=False)
            self.assertEqual(second_parent.returncode, 0)
            self.assertIn("develop", result.promoted)
            self.assertIn("main", result.promoted)
            self.assertIsNotNone(_origin_ref(origin, "develop"))
        finally:
            cleanup(origin, seed, local_parent)

    def test_checked_out_holder_clean_fast_forwards_in_holder_worktree(self):
        origin, seed, local_parent, holder, session = _make_cross_worktree_repo()
        try:
            write_file(session, "base.txt", "base\nfeature change\n")

            result = _make_pipeline(session).run()

            self.assertEqual(result.outcome, Outcome.COMMITTED)
            self.assertEqual(result.promoted, ["develop", "main"])
            self.assertEqual(_origin_ref(origin, "develop"), result.commit_hash)
            self.assertEqual(_origin_ref(origin, "main"), result.commit_hash)
            self.assertEqual(run_git(holder, ["rev-parse", "develop"]).stdout.strip(), result.commit_hash)
            self.assertEqual(run_git(holder, ["rev-parse", "HEAD"]).stdout.strip(), result.commit_hash)
            with open(os.path.join(holder, "base.txt"), encoding="utf-8") as handle:
                self.assertEqual(handle.read(), "base\nfeature change\n")
            self.assertTrue(any("fast-forwarded in its holding worktree" in w for w in result.warnings))
        finally:
            cleanup(origin, seed, local_parent)

    def test_checked_out_holder_dirty_stops_without_advancing_develop(self):
        origin, seed, local_parent, holder, session = _make_cross_worktree_repo()
        try:
            write_file(session, "base.txt", "base\nfeature change\n")
            develop_before = run_git(holder, ["rev-parse", "develop"]).stdout.strip()
            write_file(holder, "base.txt", "base\nholder dirty\n")

            result = _make_pipeline(session).run()

            self.assertEqual(result.outcome, Outcome.PROMOTE_FAILED)
            self.assertTrue(any("uncommitted changes" in w for w in result.warnings))
            self.assertEqual(run_git(holder, ["rev-parse", "develop"]).stdout.strip(), develop_before)
            self.assertEqual(_origin_ref(origin, "develop"), develop_before)
        finally:
            cleanup(origin, seed, local_parent)

    def test_checked_out_holder_diverged_stops_without_merge_commit(self):
        origin, seed, local_parent, holder, session = _make_cross_worktree_repo()
        try:
            write_file(holder, "holder_only.txt", "holder\n")
            run_git(holder, ["add", "--", "holder_only.txt"])
            run_git(holder, ["commit", "-q", "-m", "holder develop"])
            develop_before = run_git(holder, ["rev-parse", "develop"]).stdout.strip()
            write_file(session, "base.txt", "base\nfeature change\n")

            result = _make_pipeline(session).run()

            self.assertEqual(result.outcome, Outcome.PROMOTE_FAILED)
            self.assertTrue(any("could not fast-forward develop" in w for w in result.warnings))
            self.assertEqual(run_git(holder, ["rev-parse", "develop"]).stdout.strip(), develop_before)
            second_parent = run_git(holder, ["rev-parse", "-q", "--verify", "develop^2"], check=False)
            self.assertNotEqual(second_parent.returncode, 0)
            self.assertEqual(run_git(holder, ["rev-list", "--count", "develop"]).stdout.strip(), "2")
        finally:
            cleanup(origin, seed, local_parent)

    def test_no_origin_promotes_locally_with_warning(self):
        repo = make_repo()
        try:
            commit_file(repo, "base.txt", "base\n", "init")
            run_git(repo, ["branch", "develop"])
            run_git(repo, ["checkout", "-b", "feature"])
            write_file(repo, "base.txt", "base\nfeature change\n")

            result = _make_pipeline(repo).run()

            self.assertEqual(result.outcome, Outcome.COMMITTED)
            self.assertEqual(result.promoted, ["develop", "main"])
            self.assertTrue(any("no origin remote" in w for w in result.warnings))
            self.assertEqual(run_git(repo, ["rev-parse", "develop"]).stdout.strip(), result.commit_hash)
            self.assertEqual(run_git(repo, ["rev-parse", "main"]).stdout.strip(), result.commit_hash)
        finally:
            cleanup(repo)

    def test_dirty_unrelated_file_survives_ff_promotion(self):
        repo = make_repo()
        try:
            commit_file(repo, "in_scope.txt", "one\n", "init")
            commit_file(repo, "out_of_scope.txt", "one\n", "init")
            run_git(repo, ["branch", "develop"])
            run_git(repo, ["checkout", "-b", "feature"])
            write_file(repo, "in_scope.txt", "one\ntwo\n")
            write_file(repo, "out_of_scope.txt", "one\ndirty\n")

            result = _make_pipeline(repo, paths=["in_scope.txt"]).run()

            self.assertEqual(result.outcome, Outcome.COMMITTED)
            self.assertEqual(result.promoted, ["develop", "main"])
            self.assertEqual(self.current_branch(repo), "feature")
            status = run_git(repo, ["status", "--short"]).stdout
            self.assertTrue(any("out_of_scope.txt" in line for line in status.splitlines()))
        finally:
            cleanup(repo)

    def test_master_only_repo_resolves_mainline_to_master(self):
        origin = make_bare_origin()
        seed = make_repo()
        local_parent = tempfile.mkdtemp(prefix="cc-test-local-parent-")
        local = os.path.join(local_parent, "local")
        try:
            run_git(seed, ["remote", "add", "origin", origin])
            commit_file(seed, "base.txt", "base\n", "init")
            run_git(seed, ["branch", "-m", "master"])
            run_git(seed, ["push", "-u", "origin", "master"])
            run_git(seed, ["checkout", "-b", "feature"])
            run_git(seed, ["push", "-u", "origin", "feature"])

            clone_repo(origin, local)
            run_git(local, ["checkout", "-b", "feature", "origin/feature"])
            write_file(local, "base.txt", "base\nfeature change\n")

            result = _make_pipeline(local).run()

            self.assertEqual(result.outcome, Outcome.COMMITTED)
            self.assertEqual(result.promoted, ["develop", "master"])
            self.assertEqual(_origin_ref(origin, "master"), result.commit_hash)
            self.assertIsNotNone(_origin_ref(origin, "develop"))
        finally:
            cleanup(origin, seed, local_parent)

    def test_flaky_promote_push_retries_and_completes(self):
        origin = make_bare_origin()
        seed = make_repo()
        local_parent = tempfile.mkdtemp(prefix="cc-test-local-parent-")
        local = os.path.join(local_parent, "local")
        try:
            run_git(seed, ["remote", "add", "origin", origin])
            commit_file(seed, "base.txt", "base\n", "init")
            run_git(seed, ["push", "-u", "origin", "main"])
            run_git(seed, ["checkout", "-b", "develop"])
            run_git(seed, ["push", "-u", "origin", "develop"])
            run_git(seed, ["checkout", "-b", "feature"])
            run_git(seed, ["push", "-u", "origin", "feature"])

            clone_repo(origin, local)
            run_git(local, ["branch", "develop", "origin/develop"])
            run_git(local, ["checkout", "-b", "feature", "origin/feature"])
            write_file(local, "base.txt", "base\nfeature change\n")
            write_flaky_hook(
                os.path.join(origin, "hooks"),
                "pre-receive",
                "hooks/pre-receive-count",
                failing_attempts=1,
                label="flaky pre-receive",
            )

            result = _make_pipeline(local, no_push=True).run()

            self.assertEqual(result.outcome, Outcome.COMMITTED)
            self.assertEqual(result.promoted, ["develop", "main"])
            retry_warnings = [w for w in result.warnings if "promote push develop attempt" in w]
            self.assertEqual(len(retry_warnings), 1)
            self.assertIn("attempt 1/3", retry_warnings[0])
            self.assertIn("flaky pre-receive attempt 1", retry_warnings[0])
            self.assertEqual(_origin_ref(origin, "develop"), result.commit_hash)
            self.assertEqual(_origin_ref(origin, "main"), result.commit_hash)
        finally:
            cleanup(origin, seed, local_parent)

    def test_promote_push_rejection_resyncs_diverged_main_before_retry(self):
        origin = make_bare_origin()
        seed = make_repo()
        local_parent = tempfile.mkdtemp(prefix="cc-test-local-parent-")
        local = os.path.join(local_parent, "local")
        try:
            run_git(seed, ["remote", "add", "origin", origin])
            commit_file(seed, "base.txt", "base\n", "init")
            run_git(seed, ["push", "-u", "origin", "main"])
            run_git(seed, ["checkout", "-b", "develop"])
            run_git(seed, ["push", "-u", "origin", "develop"])
            run_git(seed, ["checkout", "-b", "feature"])
            run_git(seed, ["push", "-u", "origin", "feature"])

            clone_repo(origin, local)
            run_git(local, ["branch", "develop", "origin/develop"])
            run_git(local, ["checkout", "-b", "feature", "origin/feature"])
            write_file(local, "base.txt", "base\nfeature change\n")
            _write_drifting_main_pre_receive_hook(origin)

            result = _make_pipeline(local, no_push=True).run()

            self.assertEqual(result.outcome, Outcome.COMMITTED)
            self.assertIn("main", result.promoted)
            self.assertEqual(_origin_ref(origin, "main"), run_git(local, ["rev-parse", "main"]).stdout.strip())
            self.assertTrue(
                any("promote push main attempt 1/3" in w for w in result.warnings)
            )
            self.assertTrue(
                any("local main diverged from origin/main" in w for w in result.warnings)
            )
        finally:
            cleanup(origin, seed, local_parent)

    def test_local_mainline_diverged_from_origin_merges_cleanly(self):
        origin = make_bare_origin()
        seed = make_repo()
        local_parent = tempfile.mkdtemp(prefix="cc-test-local-parent-")
        local = os.path.join(local_parent, "local")
        try:
            run_git(seed, ["remote", "add", "origin", origin])
            commit_file(seed, "base.txt", "base\n", "init")
            run_git(seed, ["push", "-u", "origin", "main"])

            clone_repo(origin, local)
            run_git(local, ["checkout", "-b", "main", "origin/main"])
            run_git(local, ["branch", "develop", "origin/main"])
            commit_file(local, "local-main.txt", "local main\n", "local main")
            commit_file(seed, "origin-main.txt", "origin main\n", "origin main")
            run_git(seed, ["push", "origin", "main"])
            run_git(local, ["checkout", "develop"])

            result = _make_pipeline(local).run()

            self.assertEqual(result.outcome, Outcome.NOTHING_TO_COMMIT)
            self.assertEqual(result.promoted, ["main"])
            self.assertEqual(self.current_branch(local), "develop")
            self.assertTrue(
                any("local main diverged from origin/main" in w for w in result.warnings)
            )
            main_second_parent = run_git(local, ["rev-parse", "-q", "--verify", "main^2"], check=False)
            self.assertEqual(main_second_parent.returncode, 0)
            self.assertEqual(_origin_ref(origin, "main"), run_git(local, ["rev-parse", "main"]).stdout.strip())
        finally:
            cleanup(origin, seed, local_parent)

    def test_local_mainline_diverged_from_origin_conflict_aborts_and_restores_branch(self):
        origin = make_bare_origin()
        seed = make_repo()
        local_parent = tempfile.mkdtemp(prefix="cc-test-local-parent-")
        local = os.path.join(local_parent, "local")
        try:
            run_git(seed, ["remote", "add", "origin", origin])
            commit_file(seed, "shared.txt", "one\ntwo\nthree\n", "init")
            run_git(seed, ["push", "-u", "origin", "main"])

            clone_repo(origin, local)
            run_git(local, ["checkout", "-b", "main", "origin/main"])
            run_git(local, ["branch", "develop", "origin/main"])
            write_file(local, "shared.txt", "one\nLOCAL\nthree\n")
            run_git(local, ["commit", "-q", "-am", "local main"])
            write_file(seed, "shared.txt", "one\nORIGIN\nthree\n")
            run_git(seed, ["commit", "-q", "-am", "origin main"])
            run_git(seed, ["push", "origin", "main"])
            run_git(local, ["checkout", "develop"])

            result = _make_pipeline(local).run()

            self.assertEqual(result.outcome, Outcome.PROMOTE_CONFLICT)
            self.assertEqual(self.current_branch(local), "develop")
            merge_head = run_git(local, ["rev-parse", "-q", "--verify", "MERGE_HEAD"], check=False)
            self.assertNotEqual(merge_head.returncode, 0)
            self.assertTrue(any("origin/main into main" in w for w in result.warnings))
            self.assertTrue(any("shared.txt" in w for w in result.warnings))
        finally:
            cleanup(origin, seed, local_parent)

    def test_clean_tree_promote_repairs_sync_without_committing(self):
        origin = make_bare_origin()
        seed = make_repo()
        local_parent = tempfile.mkdtemp(prefix="cc-test-local-parent-")
        local = os.path.join(local_parent, "local")
        try:
            run_git(seed, ["remote", "add", "origin", origin])
            commit_file(seed, "base.txt", "base\n", "init")
            run_git(seed, ["push", "-u", "origin", "main"])
            run_git(seed, ["checkout", "-b", "develop"])
            commit_file(seed, "develop_only.txt", "develop advance\n", "develop advance")
            run_git(seed, ["push", "-u", "origin", "develop"])

            clone_repo(origin, local)
            run_git(local, ["checkout", "-b", "develop", "origin/develop"])

            result = _make_pipeline(local).run()

            self.assertEqual(result.outcome, Outcome.NOTHING_TO_COMMIT)
            self.assertEqual(result.promoted, ["main"])
            self.assertIn("PROMOTE", result.stages_run)
            self.assertIsNone(result.commit_hash)
            develop_tip = run_git(local, ["rev-parse", "develop"]).stdout.strip()
            self.assertEqual(run_git(local, ["rev-parse", "main"]).stdout.strip(), develop_tip)
            self.assertEqual(_origin_ref(origin, "main"), develop_tip)
        finally:
            cleanup(origin, seed, local_parent)

    def test_merge_fallback_checkout_blocked_by_untracked_file(self):
        repo = make_repo()
        try:
            commit_file(repo, "base.txt", "base\n", "init")
            run_git(repo, ["checkout", "-b", "develop"])
            commit_file(repo, "blocker.txt", "develop version\n", "add blocker on develop")
            run_git(repo, ["checkout", "main"])
            run_git(repo, ["checkout", "-b", "feature"])
            write_file(repo, "base.txt", "base\nfeature change\n")
            write_file(repo, "blocker.txt", "feature version\n")

            develop_before = run_git(repo, ["rev-parse", "develop"]).stdout.strip()
            result = _make_pipeline(repo, no_push=True, paths=["base.txt"]).run()

            self.assertEqual(result.outcome, Outcome.PROMOTE_FAILED)
            self.assertNotIn("develop", result.promoted)
            self.assertEqual(run_git(repo, ["rev-parse", "develop"]).stdout.strip(), develop_before)
            self.assertEqual(self.current_branch(repo), "feature")
            blocker_path = os.path.join(repo, "blocker.txt")
            self.assertTrue(os.path.exists(blocker_path))
            with open(blocker_path, encoding="utf-8") as handle:
                self.assertEqual(handle.read(), "feature version\n")
            self.assertTrue(
                any("could not check out develop for merge" in w for w in result.warnings)
            )
        finally:
            cleanup(repo)

    def current_branch(self, repo):
        return run_git(repo, ["rev-parse", "--abbrev-ref", "HEAD"]).stdout.strip()


if __name__ == "__main__":
    unittest.main()
