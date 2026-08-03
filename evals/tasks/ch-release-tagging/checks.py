"""Programmatic checks for ch-release-tagging.

Verifies every PostHog event/exception is tagged with the app's real version/build as
super properties (posthog-js `register`), sourced from the packaged app rather than a
hardcoded string, without a hallucinated SDK call and without regressing typecheck.

run_checks(workspace, task, config) -> dict with keys:
  passed: bool
  reason_code: one of "pass", "wrong-answer", "build-fail", "wrong-api", "missing-events", "check-infra"
  detail: str, human-readable explanation

Check order: wrong-api (hallucinated posthog-js method) first, build gate second, static
acceptance last. As in the other two ch- tasks, "missing-events" covers every way the
static acceptance scan can come back unsatisfied: no `register` call for the release
properties at all, or one that exists but is fed a hardcoded semver literal instead of
the packaged app's real version (which fails the task's explicit "not a hardcoded
string" requirement just as surely as not registering anything).
"""

import os
import re
import subprocess

REGISTER_CALL_RE = re.compile(r"\bregister\s*\(")
APP_VERSION_KEY_RE = re.compile(r"\$app_version|app_version", re.IGNORECASE)
APP_BUILD_KEY_RE = re.compile(r"\$app_build|app_build", re.IGNORECASE)
HARDCODED_SEMVER_RE = re.compile(r"""['"]\d+\.\d+\.\d+(?:\+\d+)?['"]""")
GET_VERSION_RE = re.compile(r"getVersion\s*\(|getAppVersion")
IDENTIFIER_RE = re.compile(r"[A-Za-z_$][A-Za-z0-9_$]*")
# the generic group cannot span nested angle brackets (function f<T extends Map<K, V>>)
FUNCTION_DECLARATION_RE_TEMPLATE = (
    r"\b(?:export\s+)?(?:default\s+)?(?:async\s+)?function\s+{name}\s*(?:<[^>]*>)?\s*\("
)
VALUE_DECLARATION_RE_TEMPLATE = r"\b(?:export\s+)?(?:default\s+)?(?:const|let|var)\s+{name}\b"
ASSIGNMENT_EQUALS_RE = re.compile(r"(?<![=!<>])=(?![=>])")
ASYNC_KEYWORD_RE = re.compile(r"async\s+")
TEST_PATH_SEGMENT_RE = re.compile(r"(?:^|/)(?:__tests__|test|tests)(?:/|$)")
TEST_FILENAME_RE = re.compile(r"\.(?:test|spec)\.[^/.]+$")


def _fail(reason_code, detail):
    return {"passed": False, "reason_code": reason_code, "detail": detail}


def _pass(detail):
    return {"passed": True, "reason_code": "pass", "detail": detail}


def _infra(detail):
    return {"passed": False, "reason_code": "check-infra", "detail": detail}


def _run(cmd, cwd, timeout=180):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout, shell=True)


def _read_text(path):
    if not os.path.isfile(path):
        return ""
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        return handle.read()


def _split_import_names(group_text):
    names = []
    for token in group_text.split(","):
        token = token.strip()
        if not token or token.startswith("type "):
            continue
        names.append(token.split(" as ")[0].strip())
    return names


def _collect_posthog_js_methods(repo_root):
    path = os.path.join(repo_root, "node_modules", "posthog-js", "dist", "module.d.ts")
    text = _read_text(path)
    methods = set()
    for match in re.finditer(r"^\s{4,8}(\w+)\(", text, re.MULTILINE):
        methods.add(match.group(1))
    return methods


def _changed_files(workspace, pinned_commit):
    # untracked new files never show up in a plain `git diff`; intent-to-add stages
    # them as empty blobs so they appear in the diff without actually adding content
    _run("git add -N -- src", workspace)
    proc = _run(f"git diff --name-only {pinned_commit} -- src", workspace)
    if proc.returncode != 0:
        return None
    return [line.strip() for line in proc.stdout.splitlines() if line.strip()]


def _added_lines_by_file(workspace, pinned_commit, files):
    added = {}
    for file_path in files:
        proc = _run(f'git diff {pinned_commit} -- "{file_path}"', workspace)
        if proc.returncode != 0:
            continue
        lines = [
            line[1:] for line in proc.stdout.splitlines()
            if line.startswith("+") and not line.startswith("+++")
        ]
        added[file_path] = "\n".join(lines)
    return added


def _check_wrong_api(repo_root, added_lines_by_file):
    posthog_js_methods = _collect_posthog_js_methods(repo_root)
    offenders = []
    call_re = re.compile(r"\bposthog\??\.(\w+)\(")
    for file_path, text in added_lines_by_file.items():
        for match in call_re.finditer(text):
            name = match.group(1)
            if posthog_js_methods and name not in posthog_js_methods:
                offenders.append(f"{file_path}: `posthog.{name}(...)` is not a method on the installed posthog-js client")
    return offenders


def _index_after_balanced_parens(text, open_paren_index):
    """Index just past the ')' that closes the '(' at open_paren_index, or None if the
    diff's added lines cut off before it closes."""
    depth = 0
    for index in range(open_paren_index, len(text)):
        char = text[index]
        if char == "(":
            depth += 1
            continue
        if char == ")":
            depth -= 1
            if depth == 0:
                return index + 1
    return None


def _extract_balanced_call_args(text, open_paren_index):
    """Return the text between a call's parens, given the index of its opening '('."""
    close_index = _index_after_balanced_parens(text, open_paren_index)
    if close_index is None:
        return text[open_paren_index + 1:]
    return text[open_paren_index + 1:close_index - 1]


def _extract_value_or_block(text, start_index):
    """From just after a declaration's name (and, for a function, its parameter list),
    capture the value that follows: a balanced {...} block if one starts before a
    top-level ';', else the bare expression up to that ';'.
    """
    index = start_index
    while index < len(text) and text[index] not in "{;":
        index += 1
    if index >= len(text):
        return text[start_index:]
    if text[index] == ";":
        return text[start_index:index]
    depth = 0
    block_start = index
    for i in range(index, len(text)):
        char = text[i]
        if char == "{":
            depth += 1
            continue
        if char == "}":
            depth -= 1
            if depth == 0:
                return text[block_start:i + 1]
    return text[block_start:]


def _skip_whitespace(text, index):
    return index + len(text[index:]) - len(text[index:].lstrip())


def _extract_arrow_function_body(text, expression_start_index):
    """If the expression at expression_start_index is an arrow function
    (`(...) => ...`, `({ destructured }) => ...`, or `identifier => ...`), return the
    text after its `=>`. Returns None for anything else, so the caller falls back to
    treating the expression as a plain value.
    """
    index = _skip_whitespace(text, expression_start_index)
    async_match = ASYNC_KEYWORD_RE.match(text, index)
    if async_match:
        index = async_match.end()
    if index < len(text) and text[index] == "(":
        close_index = _index_after_balanced_parens(text, index)
        if close_index is None:
            return None
        index = close_index
    else:
        identifier_match = IDENTIFIER_RE.match(text, index)
        if not identifier_match:
            return None
        index = identifier_match.end()

    index = _skip_whitespace(text, index)
    if not text.startswith("=>", index):
        return None
    return _extract_value_or_block(text, index + 2)


def _index_after_assignment_equals(text, start_index):
    """Bounded at the declaration's own statement: a `let x;` with the real assignment
    in a later statement must not match some other statement's '='.
    """
    statement_end_index = text.find(";", start_index)
    if statement_end_index == -1:
        statement_end_index = len(text)
    match = ASSIGNMENT_EQUALS_RE.search(text, start_index, statement_end_index)
    return match.end() if match else None


def _extract_declaration_block(text, symbol):
    """The body of a `function <symbol>(...) { ... }` (generics and TS overload
    signatures tolerated), or the initializer of a `const/let/var <symbol> = ...`
    declaration (arrow functions included) for `symbol`. Scoped to just that
    declaration's own body/value so a release key appearing elsewhere in the same file
    (an unrelated capture call, say, or the symbol's own parameter names) can't
    false-positive a symbol whose real body doesn't carry it.
    """
    for function_match in re.finditer(FUNCTION_DECLARATION_RE_TEMPLATE.format(name=re.escape(symbol)), text):
        params_close_index = _index_after_balanced_parens(text, function_match.end() - 1)
        if params_close_index is None:
            continue
        # a TS overload signature ends in ';' with no body; skip it for a later match
        # that has a real '{' implementation instead of stopping at the first hit
        extracted = _extract_value_or_block(text, params_close_index)
        if extracted.startswith("{"):
            return extracted

    value_match = re.search(VALUE_DECLARATION_RE_TEMPLATE.format(name=re.escape(symbol)), text)
    if value_match:
        equals_end_index = _index_after_assignment_equals(text, value_match.end())
        if equals_end_index is None:
            return _extract_value_or_block(text, value_match.end())
        arrow_body = _extract_arrow_function_body(text, equals_end_index)
        if arrow_body is not None:
            return arrow_body
        return _extract_value_or_block(text, equals_end_index)

    return None


def _register_call_arg_symbol(text, register_match):
    """Leading identifier of a register(...) call's first argument, when it isn't an
    object literal (e.g. `register(releaseSuperProperties)` or `register(toAppIdentity())`).
    """
    args_text = _extract_balanced_call_args(text, register_match.end() - 1).strip()
    args_text = re.sub(r"^await\s+", "", args_text)
    if not args_text or args_text.startswith("{"):
        return None
    identifier_match = IDENTIFIER_RE.match(args_text)
    return identifier_match.group(0) if identifier_match else None


def _symbol_definition_covers_release_properties(symbol, added_lines_by_file):
    for text in added_lines_by_file.values():
        declaration_block = _extract_declaration_block(text, symbol)
        if declaration_block is None:
            continue
        if APP_VERSION_KEY_RE.search(declaration_block) or APP_BUILD_KEY_RE.search(declaration_block):
            return True
    return False


def _register_call_covers_release_properties(added_lines_by_file):
    """A register(...) call tagging $app_version/$app_build, inline or one hop away.

    Most implementations pass an object literal straight into register(...) in the same
    file. Some extract the super-properties object into its own module (an appIdentity.ts
    exporting a builder function, or a telemetryRelease.ts exporting a constant) and
    register the imported symbol instead; that symbol's definition can land in any changed
    file, so a single indirection hop is resolved across the whole diff before failing.
    """
    referenced_symbols = []
    for text in added_lines_by_file.values():
        register_matches = list(REGISTER_CALL_RE.finditer(text))
        if not register_matches:
            continue
        if APP_VERSION_KEY_RE.search(text) or APP_BUILD_KEY_RE.search(text):
            return True
        for register_match in register_matches:
            symbol = _register_call_arg_symbol(text, register_match)
            if symbol:
                referenced_symbols.append(symbol)

    return any(
        _symbol_definition_covers_release_properties(symbol, added_lines_by_file)
        for symbol in referenced_symbols
    )


def _is_test_file(file_path):
    normalized = file_path.replace("\\", "/")
    return bool(TEST_PATH_SEGMENT_RE.search(normalized) or TEST_FILENAME_RE.search(normalized))


def _version_source_is_dynamic(workspace, changed_files):
    """No hardcoded semver literal near a version property, and some real version lookup exists.

    Both checked across the full post-edit file contents (not just the diff) since the
    lookup and the register call may land in different files (main process reads
    app.getVersion(), bridges it over IPC, renderer registers it). Test files are excluded
    from both scans: a unit test asserting `register` was called with a literal fixture
    version (e.g. `{ $app_version: '0.9.7' }`) is not the hardcoded string the task's
    "not typed in by hand" requirement is guarding against, since it doesn't feed the
    real registration.
    """
    has_dynamic_lookup = False
    has_hardcoded_literal_near_version_key = False
    for file_path in changed_files:
        if _is_test_file(file_path):
            continue
        text = _read_text(os.path.join(workspace, file_path))
        if GET_VERSION_RE.search(text):
            has_dynamic_lookup = True
        for line in text.splitlines():
            if APP_VERSION_KEY_RE.search(line) and HARDCODED_SEMVER_RE.search(line):
                has_hardcoded_literal_near_version_key = True
    return has_dynamic_lookup and not has_hardcoded_literal_near_version_key


def _ensure_node_modules_linked(workspace, repo_root):
    target = os.path.normpath(os.path.join(workspace, "node_modules"))
    if os.path.isdir(target) or os.path.islink(target):
        return True
    source = os.path.normpath(os.path.join(repo_root, "node_modules"))
    if not os.path.isdir(source):
        return False
    try:
        os.symlink(source, target, target_is_directory=True)
        return True
    except OSError:
        pass
    # cmd.exe's mklink parses a forward-slash path as switches (e.g. "/Users" reads as a
    # switch), so both paths must be backslash-normalized before this call, not just the
    # os.symlink attempt above (which tolerates either separator).
    proc = subprocess.run(["cmd", "/c", "mklink", "/J", target, source], capture_output=True, text=True)
    return proc.returncode == 0


def _run_typecheck(workspace):
    proc = _run("npm run typecheck", workspace, timeout=180)
    return proc.returncode, (proc.stdout + "\n" + proc.stderr)[-4000:]


def run_checks(workspace, task, config):
    pinned_commit = task.get("pinned_commit")
    repo_root = task.get("repo") or workspace
    if not pinned_commit:
        return _infra("task.yml has no pinned_commit; cannot diff against a baseline")

    changed_files = _changed_files(workspace, pinned_commit)
    if changed_files is None:
        return _infra("git diff against pinned_commit failed; workspace may not be a valid worktree")

    added_lines_by_file = _added_lines_by_file(workspace, pinned_commit, changed_files)

    wrong_api_offenders = _check_wrong_api(repo_root, added_lines_by_file)
    if wrong_api_offenders:
        return _fail("wrong-api", "hallucinated PostHog SDK usage: " + "; ".join(wrong_api_offenders))

    if not _ensure_node_modules_linked(workspace, repo_root):
        return _infra("could not link node_modules into the worktree for typecheck")
    try:
        exit_code, tail = _run_typecheck(workspace)
    except subprocess.TimeoutExpired:
        return _infra("npm run typecheck timed out")
    if exit_code != 0:
        return _fail("build-fail", f"npm run typecheck failed (exit {exit_code}): {tail}")

    if not _register_call_covers_release_properties(added_lines_by_file):
        return _fail(
            "missing-events",
            "no posthog `register(...)` call found tagging $app_version/$app_build super properties; "
            f"changed files: {changed_files}",
        )
    if not _version_source_is_dynamic(workspace, changed_files):
        return _fail(
            "missing-events",
            "version registered as a super property is either hardcoded or has no traceable "
            "app.getVersion()-style lookup; the task requires the real packaged version",
        )

    return _pass("typecheck clean, release super properties registered from a dynamic version lookup")
