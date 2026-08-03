"""Trivial deterministic checks for the sample fixture task: exercises the dry-run and
replay paths end to end without depending on a real claude response.
"""


def run_checks(workspace, task, config):
    return {"passed": True, "reason_code": "pass", "detail": "fixture check always passes"}
