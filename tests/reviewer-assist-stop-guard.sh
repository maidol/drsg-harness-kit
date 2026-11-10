#!/usr/bin/env bash
# Contract tests for the reviewer-assistance Stop guard.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
GUARD="${REVIEWER_ASSIST_GUARD:-$REPO/tools/reviewer-assist-stop-guard.py}"

python3 - "$GUARD" "$0" <<'PY'
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time

hook, test_script = sys.argv[1:3]
if not os.path.isfile(hook):
    print("FAIL block-contract: reviewer-assist-stop-guard.py is missing")
    print("MUTATION CHECK DID NOT RUN")
    raise SystemExit(1)

failures = []
checks = 0
mutation_results = []
expected_mutants = 16
only = os.environ.get("ONLY", "")


def check(name, ok, detail=""):
    global checks
    if only and only != name:
        return
    checks += 1
    if ok:
        print("PASS " + name)
    else:
        failures.append("%s%s" % (name, ": " + detail if detail else ""))


def user(content="synthetic user input"):
    return {"type": "user", "message": {"content": content}}


def assistant(content, message_id="synthetic-assistant-message"):
    return {"type": "assistant", "message": {"id": message_id, "content": content}}


def text(value):
    return [{"type": "text", "text": value + " synthetic-transcript-marker"}]


with tempfile.TemporaryDirectory(prefix="reviewer-assist-stop-") as tmp:
    base = pathlib.Path(tmp)
    home = base / "home"
    mem = base / "memory"
    reviewer = base / "reviewer"
    project = base / "consumer"
    for path in (home, mem, reviewer, project):
        path.mkdir()
    (mem / "commit-auth.json").write_text(
        json.dumps({"reviewer": str(reviewer)}), encoding="utf-8")
    no_config_home = base / "home-no-config"
    no_config_home.mkdir()
    no_reviewer_mem = base / "memory-no-reviewer"
    no_reviewer_mem.mkdir()
    (no_reviewer_mem / "commit-auth.json").write_text(
        json.dumps({"reviewer": "relative-reviewer"}), encoding="utf-8")

    env = os.environ.copy()
    env.update({
        "HOME": str(home),
        "DRSG_MEM_DIR": str(mem),
        "CLAUDE_PROJECT_DIR": str(project),
    })
    env.pop("DRSG_EVENT_LANES", None)

    def write_rows(name, rows):
        path = base / (name + ".jsonl")
        with path.open("w", encoding="utf-8") as stream:
            for row in rows:
                stream.write(json.dumps(row, ensure_ascii=False) + "\n")
        return path

    def run(name, rows=None, raw=None, hook_input=None, env_extra=None,
            expected="allow", hint=False, expect_silent=True, elapsed_limit=None):
        if only and only != name:
            return None, 0.0
        started = time.perf_counter()
        transcript = write_rows(name, rows or []) if rows is not None else None
        data = hook_input or {
            "hook_event_name": "Stop",
            "stop_hook_active": False,
            "transcript_path": str(transcript) if transcript else "",
            "cwd": str(project),
        }
        if raw is not None:
            input_data = raw
        else:
            input_data = json.dumps(data)
        runenv = env.copy()
        if env_extra:
            runenv.update(env_extra)
        result = subprocess.run(
            [sys.executable, hook], input=input_data, text=True,
            capture_output=True, cwd=project, env=runenv, check=False,
        )
        elapsed = time.perf_counter() - started
        try:
            output = json.loads(result.stdout) if result.stdout.strip() else {}
        except ValueError:
            output = {}
        got = "block" if output.get("decision") == "block" else "allow"
        ok = result.returncode == 0 and got == expected
        if hint:
            ok = ok and output == {"decision": "block", "reason": (
                "你在等审核方协助，先用 event_post 发『请求协助：』，再停；"
                "如果只在等用户本人拍板，直接结束即可")}
            ok = ok and len(result.stdout.splitlines()) == 1
        if expect_silent and expected == "allow":
            ok = ok and not result.stdout.strip()
        if expected == "allow":
            ok = ok and "synthetic-transcript-marker" not in result.stdout + result.stderr
        if elapsed_limit is not None:
            ok = ok and elapsed < elapsed_limit
        detail = "exit=%s decision=%s elapsed=%.3fs" % (result.returncode, got, elapsed)
        if result.stderr.strip():
            detail += " stderr-present"
        check(name, ok, detail)
        return result, elapsed

    g1 = "权限检查被拦，需要代跑"
    mixed = "请用户确认发布；权限检查被拦，需要审核方代跑"
    c6_rows = [user(), assistant(text(g1))]
    run("g1-block", c6_rows, expected="block", hint=True, expect_silent=False)
    run("g5-block", [user(), assistant(text("commit_auth_apply 返回错误，需要审核方修复"))],
        expected="block", hint=True, expect_silent=False)
    run("g2-g3-block", [user(), assistant(text("审核方仓库的计划文件有误，需要审核方修改计划文件"))],
        expected="block", hint=True, expect_silent=False)
    run("g3-only-allow", [user(), assistant(text("等待审核方判定"))])
    run("g4-only-allow", [user(), assistant(text("起点归属待确认"))])
    run("g6-only-allow", [user(), assistant(text("请用户确认是否发布"))])
    run("mixed-g1-g3-g6-block", [user(), assistant(text(mixed))],
        expected="block", hint=True, expect_silent=False)

    run("event-post-allow", [
        user(),
        assistant([{"type": "tool_use", "id": "synthetic-tool",
                    "name": "mcp__drsg-events__event_post", "input": {"summary": "not a fixture"}}]),
        {"type": "user", "message": {"content": [
            {"type": "tool_result", "tool_use_id": "synthetic-tool", "content": "ok"}]}},
        assistant(text(g1), "after-event-post"),
    ])
    run("event-post-text-mention-does-not-count", [
        user(), assistant(text("I may call event_post later; " + g1)),
    ], expected="block", hint=True, expect_silent=False)
    run("tool-result-does-not-move-boundary", [
        user(),
        assistant([{"type": "tool_use", "id": "synthetic-post",
                    "name": "mcp__drsg-events__event_post", "input": {}}]),
        {"type": "user", "message": {"content": [
            {"type": "tool_result", "tool_use_id": "synthetic-post", "content": "ok"}]}},
        assistant(text(g1), "final-after-post"),
    ])

    context_cases = (
        ("explanation-g1", "这个脚本使用正则匹配拦截提示。", "allow"),
        ("explanation-g5", "commit_auth_apply 返回错误", "allow"),
        ("explanation-g2-g3", "审核方仓库保存计划文件。", "allow"),
        ("old-g2-g3-description", "需要修改审核方仓库的计划文件，等待验收判定", "allow"),
        ("cross-paragraph-keywords", "权限检查被拦。\n审核方仓库保存计划文件。", "allow"),
        ("quoted-request", "“需要审核方代跑”。", "allow"),
        ("inline-code-request", "示例：`需要审核方代跑`", "allow"),
        ("fenced-request", "```text\n需要审核方代跑\n```", "allow"),
        ("blockquote-request", "> 需要审核方代跑", "allow"),
        ("conditional-request", "如果被拦，就需要审核方代跑。", "allow"),
        ("hypothetical-request", "假如需要审核方代跑，应发送请求。", "allow"),
        ("negated-request", "不需要审核方代跑。", "allow"),
        ("no-longer-needed", "不再需要审核方修复。", "allow"),
        ("already-requested", "已经请审核方处理。", "allow"),
        ("resolved-request", "问题已解决，无需审核方代跑。", "allow"),
        ("historical-request", "之前需要审核方代跑，现在已经解决。", "allow"),
        ("hook-explanation", "守卫会在需要审核方代跑时提醒。", "allow"),
        ("waiting-receipt", "已发协助请求，正在等待审核方回执。", "allow"),
        ("current-reviewer-help", "本轮无法继续，需要审核方协助。", "block"),
        ("current-reviewer-wait", "当前仍卡住，等待审核方处理。", "block"),
        ("english-current-help", "The test was denied; I need reviewer help.", "block"),
        ("english-negated-help", "I do not need reviewer help.", "allow"),
        ("english-historical-help", "I previously needed reviewer help.", "allow"),
        ("english-old-and-current", "I already sent the old request. I need reviewer help for a new failure.", "block"),
        ("english-hook-explanation", "The hook checks whether I need reviewer help.", "allow"),
        ("indirect-current-request", "请用户同时联系审核方代跑", "block"),
        ("will-not-ask", "不会请审核方处理。", "allow"),
        ("resolved-and-new", "旧问题已解决，但需要审核方代跑新测试。", "block"),
        ("historical-and-current", "之前需要审核方代跑。\n当前需要审核方代跑新测试。", "block"),
        ("quote-and-current", "“需要审核方代跑”是旧示例，当前需要审核方代跑新测试。", "block"),
        ("negated-user-and-reviewer", "不需要用户处理，需要审核方代跑。", "block"),
        ("mixed-user-and-reviewer", mixed, "block"),
    )
    for name, value, expected in context_cases:
        for suffix, extra in (("", {}), ("-with-lane", {"DRSG_EVENT_LANES": "synthetic-lane"})):
            run(name + suffix, [user(), assistant(text(value))], env_extra=extra,
                expected=expected, hint=expected == "block", expect_silent=expected == "allow")

    post_name = "mcp__drsg-events__event_post"
    def call(name, payload=None):
        return {"type": "tool_use", "id": "synthetic-call", "name": name,
                "input": {} if payload is None else payload}

    def parallel_call(recipient):
        return call("multi_tool_use.parallel", {"tool_uses": [
            {"recipient_name": recipient, "parameters": {}}]})

    for name, block, expected in (
        ("qualified-post", call("functions." + post_name), "allow"),
        ("parallel-post", parallel_call(post_name), "allow"),
        ("parallel-qualified-post", parallel_call("functions." + post_name), "allow"),
        ("unknown-prefix-post", call("other." + post_name), "block"),
        ("lookalike-post", call(post_name + "_fake"), "block"),
        ("embedded-in-bash-not-call", call("Bash", {"command": post_name}), "block"),
        ("invalid-parallel-shape", call("multi_tool_use.parallel", {"tool_uses": {}}), "block"),
        ("invalid-parallel-item", call("multi_tool_use.parallel", {"tool_uses": [None]}), "block"),
        ("arbitrary-nesting-not-call", call("Bash", {"nested": parallel_call(post_name)}), "block"),
    ):
        run(name, [user(), assistant([block], "synthetic-call-message"),
            assistant(text(g1), "after-call")], expected=expected,
            hint=expected == "block", expect_silent=expected == "allow")

    posted = [user(), assistant([call(post_name)], "synthetic-post-message")]
    for name, boundary, expected in (
        ("meta-text-keeps-post", {**user(), "isMeta": True}, "allow"),
        ("meta-block-keeps-post", {**user(text("synthetic notification")), "isMeta": True}, "allow"),
        ("real-user-resets-post", user(), "block"),
        ("real-user-block-resets-post", user(text("new request")), "block"),
        ("false-meta-resets-post", {**user(), "isMeta": False}, "block"),
    ):
        run(name, posted + [boundary, assistant(text(g1), "after-boundary")],
            expected=expected, hint=expected == "block", expect_silent=expected == "allow")
    run("failed-post-not-retried", posted + [user([{
        "type": "tool_result", "tool_use_id": "synthetic-call", "is_error": True,
        "content": "synthetic denial"}]), assistant(text(g1), "after-failed-post")])

    run("active-stop-allow", c6_rows, hook_input={
        "hook_event_name": "Stop", "stop_hook_active": True,
        "transcript_path": str(write_rows("active-stop", c6_rows)), "cwd": str(project),
    })
    run("no-reviewer-allow", c6_rows, env_extra={
        "HOME": str(no_config_home), "DRSG_MEM_DIR": str(base / "absent-memory"),
    })
    run("invalid-reviewer-allow", c6_rows, env_extra={"DRSG_MEM_DIR": str(no_reviewer_mem)})
    run("reviewer-project-allow", c6_rows, hook_input={
        "hook_event_name": "Stop", "stop_hook_active": False,
        "transcript_path": str(write_rows("reviewer-project", c6_rows)), "cwd": str(reviewer),
    }, env_extra={"CLAUDE_PROJECT_DIR": str(reviewer)})

    run("malformed-json-allow", raw="{")
    run("non-object-json-allow", raw="[]")
    run("missing-transcript-allow", hook_input={
        "hook_event_name": "Stop", "stop_hook_active": False,
        "cwd": str(project),
    })
    missing_path = str(base / "absent.jsonl")
    run("nonexistent-transcript-allow", hook_input={
        "hook_event_name": "Stop", "stop_hook_active": False,
        "transcript_path": missing_path, "cwd": str(project),
    })
    run("directory-transcript-allow", hook_input={
        "hook_event_name": "Stop", "stop_hook_active": False,
        "transcript_path": str(base), "cwd": str(project),
    })
    malformed_path = base / "malformed-final.jsonl"
    malformed_path.write_text(
        json.dumps(user()) + "\n" + json.dumps(assistant(text(g1))) + "\n{bad-json\n",
        encoding="utf-8")
    run("malformed-final-record-allow", hook_input={
        "hook_event_name": "Stop", "stop_hook_active": False,
        "transcript_path": str(malformed_path), "cwd": str(project),
    })
    run("no-assistant-text-allow", [user(), assistant([{"type": "thinking", "thinking": "synthetic"}])])

    same_id = [
        user(),
        assistant(text(g1), "shared-message"),
        assistant(text("unrelated final block"), "shared-message"),
    ]
    run("full-message-text-blocks", same_id, expected="block", hint=True, expect_silent=False)

    large_path = base / "large-over-old-cap.jsonl"
    with large_path.open("w", encoding="utf-8") as stream:
        stream.write(json.dumps(user()) + "\n")
        stream.write(json.dumps({"type": "attachment", "content": "x" * (1536 * 1024)}) + "\n")
        stream.write(json.dumps(assistant(text(g1), "large-final")) + "\n")
    run("larger-than-old-cap-block", hook_input={
        "hook_event_name": "Stop", "stop_hook_active": False,
        "transcript_path": str(large_path), "cwd": str(project),
    }, expected="block", hint=True, expect_silent=False, elapsed_limit=3.0)

    no_boundary_path = base / "no-boundary.jsonl"
    with no_boundary_path.open("w", encoding="utf-8") as stream:
        for i in range(20):
            stream.write(json.dumps({"type": "attachment", "index": i}) + "\n")
        stream.write(json.dumps(assistant(text(g1), "window-final")) + "\n")
    run("no-user-boundary-whole-window", hook_input={
        "hook_event_name": "Stop", "stop_hook_active": False,
        "transcript_path": str(no_boundary_path), "cwd": str(project),
    }, expected="block", hint=True, expect_silent=False)

    rows_path = base / "over-line-cap.jsonl"
    with rows_path.open("w", encoding="utf-8") as stream:
        for i in range(3010):
            stream.write(json.dumps({"type": "attachment", "index": i}) + "\n")
        stream.write(json.dumps(assistant(text(g1), "row-cap-final")) + "\n")
    run("over-line-cap-block", hook_input={
        "hook_event_name": "Stop", "stop_hook_active": False,
        "transcript_path": str(rows_path), "cwd": str(project),
    }, expected="block", hint=True, expect_silent=False)

    over_bytes_path = base / "over-byte-cap-event.jsonl"
    with over_bytes_path.open("w", encoding="utf-8") as stream:
        stream.write(json.dumps({"type": "attachment", "content": "x" * (9 * 1024 * 1024)}) + "\n")
        stream.write(json.dumps(user()) + "\n")
        stream.write(json.dumps(assistant([{"type": "tool_use", "id": "recent-post",
                                          "name": "mcp__drsg-events__event_post", "input": {}}],
                                         "recent-post-message")) + "\n")
        stream.write(json.dumps(assistant(text(g1), "over-cap-final")) + "\n")
    _, elapsed = run("over-byte-cap-event-post-allow", hook_input={
        "hook_event_name": "Stop", "stop_hook_active": False,
        "transcript_path": str(over_bytes_path), "cwd": str(project),
    })
    if not only:
        print("INFO tail-read-8MiB elapsed=%.3fs" % elapsed)

    partial_path = base / "partial-first-line.jsonl"
    with partial_path.open("w", encoding="utf-8") as stream:
        stream.write(json.dumps({"type": "attachment", "content": "x" * (9 * 1024 * 1024)}) + "\n")
        stream.write(json.dumps(user()) + "\n")
        stream.write(json.dumps(assistant(text(g1), "after-partial")) + "\n")
    run("partial-first-line-discarded", hook_input={
        "hook_event_name": "Stop", "stop_hook_active": False,
        "transcript_path": str(partial_path), "cwd": str(project),
    }, expected="block", hint=True, expect_silent=False)

    lane_env = {"DRSG_EVENT_LANES": "synthetic-lane"}
    for name, rows, expected in (
        ("g1-block", c6_rows, "block"),
        ("g3-only-allow", [user(), assistant(text("等待审核方判定"))], "allow"),
    ):
        lane_name = name + "-with-lane"
        lane_path = write_rows(lane_name, rows)
        run(lane_name, hook_input={
            "hook_event_name": "Stop", "stop_hook_active": False,
            "transcript_path": str(lane_path), "cwd": str(project),
        }, env_extra=lane_env, expected=expected, hint=expected == "block",
           expect_silent=expected == "allow")

def check_mutant(name, case_name, old, new, should_kill=True):
    source = pathlib.Path(hook).read_text(encoding="utf-8")
    if source.count(old) != 1:
        failures.append("%s: mutation anchor is not unique" % name)
        return
    with tempfile.TemporaryDirectory(prefix="reviewer-assist-mutant-") as tmp:
        mutant = pathlib.Path(tmp) / "guard.py"
        mutant.write_text(source.replace(old, new, 1), encoding="utf-8")
        runenv = os.environ.copy()
        runenv.update({
            "ONLY": case_name,
            "REVIEWER_ASSIST_GUARD": str(mutant),
            "PYTHONPATH": os.path.dirname(os.path.realpath(hook)),
        })
        runenv.pop("MUTATION_SELF_TEST", None)
        baseline = subprocess.run(["bash", test_script], env={
            **runenv, "REVIEWER_ASSIST_GUARD": hook,
        }, text=True, capture_output=True, check=False)
        if baseline.returncode != 0:
            check(name + " baseline", False, "paired contract failed before mutation")
            return
        result = subprocess.run(["bash", test_script], env=runenv,
                                text=True, capture_output=True, check=False)
        target_failure = any(
            line.startswith("FAIL " + case_name + ":")
            for line in result.stdout.splitlines()
        )
        survived = result.returncode == 0
        mutation_results.append("survived" if survived else "killed")
        if should_kill:
            check(name, not survived and target_failure,
                  "mutant survived or another failure stopped the paired case")
        else:
            if survived:
                print("MUTATION SELF-CHECK: deliberate mutant survived")
                check(name, False, "deliberately live mutant survived as expected")
            else:
                print("MUTATION SELF-CHECK: deliberate mutant was killed")
                check(name, False, "deliberate mutant unexpectedly failed to survive")


if not only:
    check_mutant(
        "mutant event-post bypass", "event-post-allow",
        "if final_text is None or _has_event_post(rows) or not _should_block(final_text):",
        "if final_text is None or not _should_block(final_text):",
    )
    check_mutant(
        "mutant any-user-row boundary", "tool-result-does-not-move-boundary",
        'return "text" in block_types and "tool_result" not in block_types',
        'return row.get("type") == "user"',
    )
    check_mutant(
        "mutant active-stop bypass", "active-stop-allow",
        'if hook.get("stop_hook_active") is True:',
        "if False:",
    )
    check_mutant(
        "mutant missing-reviewer bypass", "no-reviewer-allow",
        "if not reviewer or _current_project(hook) == reviewer:",
        "if _current_project(hook) == reviewer:",
    )
    for name, case_name, old, new in (
        ("qualified-name", "qualified-post",
         'names = ("mcp__drsg-events__event_post", "functions.mcp__drsg-events__event_post")',
         'names = ("mcp__drsg-events__event_post",)'),
        ("parallel-wrapper", "parallel-post",
         'if block.get("name") != "multi_tool_use.parallel":', 'if True:'),
        ("meta-boundary", "meta-text-keeps-post",
         'if row.get("isMeta") is True:', 'if False:'),
        ("real-boundary", "real-user-resets-post", 'boundary = i', 'boundary = -1'),
        ("exact-name", "unknown-prefix-post", 'if block.get("name") in names:',
         'if isinstance(block.get("name"), str) and block["name"].endswith(names[0]):'),
        ("current-intent", "explanation-g1",
         'if not NOT_PENDING.search(clause) and ASSIST_REQUEST.search(clause):',
         'if not NOT_PENDING.search(clause):'),
        ("negated-intent", "negated-request",
         'if not NOT_PENDING.search(clause) and ASSIST_REQUEST.search(clause):',
         'if ASSIST_REQUEST.search(clause):'),
        ("hypothetical-intent", "conditional-request",
         'if NON_CURRENT.search(sentence):', 'if False:'),
        ("quoted-intent", "quoted-request",
         '''text = re.sub(r'`[^`\\n]*`|“[^“”\\n]*”|‘[^‘’\\n]*’|"[^"\\n]*"', " ", text)''',
         'text = text'),
        ("clause-isolation", "negated-user-and-reviewer",
         'for clause in re.split(r"[，,]+", sentence):', 'for clause in (sentence,):'),
        ("fenced-intent", "fenced-request",
         'text = re.sub(r"```.*?(?:```|\\Z)|~~~.*?(?:~~~|\\Z)", " ", text, flags=re.DOTALL)',
         'text = text'),
        ("blockquote-intent", "blockquote-request",
         'text = re.sub(r"(?m)^[ \\t]*>[^\\n]*", " ", text)', 'text = text'),
    ):
        check_mutant("mutant " + name, case_name, old, new)
    if os.environ.get("MUTATION_SELF_TEST") == "1":
        check_mutant(
            "deliberately live unused-constant mutant", "g6-only-allow",
            'MAX_LINES = 3000', 'MAX_LINES = 3001', should_kill=False,
        )

if only and checks == 0:
    failures.append("unknown-only-case: " + only)
if failures:
    for failure in failures:
        print("FAIL " + failure)
    print("FAIL %d/%d" % (checks - len(failures), checks))
    if not only:
        if os.environ.get("MUTATION_SELF_TEST") == "1":
            if mutation_results and mutation_results[-1] == "survived":
                print("MUTANT SURVIVED (self-check)")
            else:
                print("MUTATION SELF-CHECK DID NOT CONFIRM SURVIVOR")
        elif len(mutation_results) == expected_mutants and all(result == "killed" for result in mutation_results):
            print("ALL TARGETED MUTANTS KILLED")
        elif "survived" in mutation_results:
            print("MUTANT SURVIVED")
        else:
            print("MUTATION CHECK DID NOT RUN")
    raise SystemExit(1)
print("PASS %d/%d" % (checks, checks))
if not only:
    if len(mutation_results) == expected_mutants and all(result == "killed" for result in mutation_results):
        print("ALL TARGETED MUTANTS KILLED")
    else:
        print("MUTATION CHECK DID NOT RUN")
PY
