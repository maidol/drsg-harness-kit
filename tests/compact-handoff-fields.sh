#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
export REPO
python3 - "$REPO" <<'PY'
import contextlib
import importlib.util
import io
import json
import os
import pathlib
import sys
import tempfile
import time
from unittest import mock

repo = pathlib.Path(sys.argv[1])
hook_path = pathlib.Path(os.environ.get(
    "COMPACT_HANDOFF_SOURCE", repo / "tools/templates/hooks/compact_handoff.py"))
spec = importlib.util.spec_from_file_location("compact_handoff_fields_test", hook_path)
hook = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = hook
spec.loader.exec_module(hook)
template_path = repo / "tools/templates/compact-instructions.md"
template = template_path.read_text(encoding="utf-8")
only = {name for name in os.environ.get("ONLY", "").split(",") if name}
ran = passed = 0

def check(name, test):
    global ran, passed
    if only and name not in only:
        return
    ran += 1
    try:
        test()
        passed += 1
        print("ok   " + name)
    except Exception as exc:
        print("FAIL %s: %s: %s" % (name, type(exc).__name__, exc))

ZH = """## 交接
- 计划、判据、设计文档的路径:合成值
- 当前分支,起点 tree 或起点提交:合成值
- 做到计划的第几步,这一步完成到哪:合成值
- 下一步要做的第一件事:合成值
- 未解决的报错:无
- 用户的口头约束:无
- 改过但还没提交的文件清单:无
"""
EN = """**交接**
- Plan, criteria and design document paths: synthetic
- Current branch, and starting tree or commit: synthetic
- Plan step and progress: synthetic
- First thing to do next: synthetic
- Unresolved errors (verbatim): none
- User verbal constraints (verbatim, with scope): none
- Files changed but not committed: none
"""
NESTED = """交接
- 下一步要做的第一件事：合成值
- 改过但还没提交的文件清单：无
- 用户的口头约束：
  - 分类器提示：合成子项
  - 全局规则：合成子项
- 当前分支，起点 tree 或起点提交：合成值
- 计划、判据、设计文档的路径：合成值
- 做到计划的第几步，这一步完成到哪：合成值
- 未解决的报错：无
"""
TRANSLATED = """## 交接
- Translated docs label [handoff:docs]：synthetic
- Translated origin label [handoff:origin]：synthetic
- Translated progress label [handoff:progress]：synthetic
- Translated next label [handoff:next]：synthetic
- Translated errors label [handoff:errors]：无
- Translated constraints label [handoff:constraints]：无
- Translated files label [handoff:files]：无
"""

def rules(text=template):
    return hook.parse_handoff_fields(text)

def result(summary, text=template):
    return hook.check_handoff(summary, text)

def fields_by_name(check_result):
    return {field["name"]: field for field in check_result["fields"]}

def assert_all_present(summary, expected_by=None):
    checked = result(summary)
    assert checked["section_present"] is True
    assert checked["missing_fields"] == []
    assert all(field["present"] for field in checked["fields"])
    if expected_by:
        assert {field["by"] for field in checked["fields"]} == {expected_by}

check("sample-zh", lambda: assert_all_present(ZH, "name"))
check("sample-en", lambda: assert_all_present(EN, "alias"))
check("sample-nested", lambda: assert_all_present(NESTED, "name"))
check("translated-marker", lambda: assert_all_present(TRANSLATED, "marker"))

def missing_each_field():
    for rule in rules():
        name = rule["name"]
        label = name.replace("，", ",")
        summary = "\n".join(line for line in ZH.splitlines()
                             if label not in line)
        checked = result(summary)
        assert checked["missing_fields"] == [name], (name, checked["missing_fields"])
        field = fields_by_name(checked)[name]
        assert field == {"name": name, "present": False, "by": None}
check("missing-field", missing_each_field)

def empty_value():
    checked = result(ZH.replace(
        "- 下一步要做的第一件事:合成值", "- 下一步要做的第一件事:   "))
    assert checked["missing_fields"] == ["下一步要做的第一件事"]
check("empty-value", empty_value)

def no_is_value():
    checked = result(ZH)
    for field in checked["fields"]:
        if field["name"] in ("未解决的报错", "用户的口头约束", "改过但还没提交的文件清单"):
            assert field["present"] is True
check("no-value", no_is_value)
check("duplicate-field", lambda: assert_all_present(
    ZH.replace("- 计划、判据", "- 计划、判据", 1) +
    "- 计划、判据、设计文档的路径:重复合成值\n", "name"))
check("extra-field", lambda: assert_all_present(
    ZH.replace("## 交接", "## 交接\n- 模板外字段:额外值"), "name"))
def punctuation():
    assert_all_present(ZH, "name")
    assert_all_present(NESTED, "name")
    spaced = ZH.replace("路径:合成值", "路径  :   合成值")
    assert_all_present(spaced, "name")
check("punctuation", punctuation)
def nested_items():
    assert_all_present(NESTED, "name")
    counterfeit = NESTED.replace(
        "- 下一步要做的第一件事：合成值\n", "").replace(
        "  - 分类器提示：合成子项",
        "  - 下一步要做的第一件事：合成子项\n  - 分类器提示：合成子项")
    assert result(counterfeit)["missing_fields"] == ["下一步要做的第一件事"]
check("nested-items", nested_items)
def no_section():
    checked = result("## Other\nbody")
    assert checked["section_present"] is False
    assert checked["missing_fields"] == [rule["name"] for rule in rules()]
check("no-section", no_section)

def template_growth():
    extra = "- Extra synthetic field [handoff:extra]："
    alias = "[handoff:extra]=Extra synthetic field"
    changed = template.replace("<!-- handoff-aliases", extra + "\n<!-- handoff-aliases")
    marker = " -->"
    assert marker in changed
    changed = changed.replace(marker, "; " + alias + marker, 1)
    checked = result(ZH, changed)
    assert "Extra synthetic field" in checked["missing_fields"]
check("template-growth", template_growth)

def make_project(root, summary, managed=True):
    project = root / "project"
    project.mkdir()
    transcript = root / "transcript.jsonl"
    transcript.write_text("synthetic transcript", encoding="utf-8")
    if managed:
        project.joinpath("CLAUDE.md").write_text(
            "before\n<!-- BEGIN DRSG COMPACT INSTRUCTIONS -->\n" + template +
            "\n<!-- END DRSG COMPACT INSTRUCTIONS -->\nafter\n", encoding="utf-8")
    return project, transcript

def invoke_postcompact(summary, managed=True, failure=None):
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        project, transcript = make_project(root, summary, managed)
        data_home = root / "xdg"
        env_names = ("CLAUDE_PROJECT_DIR", "XDG_DATA_HOME")
        previous = {key: os.environ.get(key) for key in env_names}
        os.environ["CLAUDE_PROJECT_DIR"] = str(project)
        os.environ["XDG_DATA_HOME"] = str(data_home)
        stdout, stderr = io.StringIO(), io.StringIO()
        data = {"trigger": "manual", "session_id": "synthetic-session",
                "transcript_path": str(transcript), "compact_summary": summary}
        patches = [mock.patch.object(hook, "open_events", lambda _: [])]
        if failure == "read":
            patches.append(mock.patch.object(
                hook, "project_handoff_block", side_effect=OSError("synthetic read error"),
                create=True))
        elif failure == "parse":
            patches.append(mock.patch.object(
                hook, "check_handoff", side_effect=ValueError("synthetic parse error"),
                create=True))
        try:
            with contextlib.ExitStack() as stack:
                for patcher in patches:
                    stack.enter_context(patcher)
                stack.enter_context(mock.patch.object(hook.sys, "stdin", io.StringIO(json.dumps(data))))
                stack.enter_context(contextlib.redirect_stdout(stdout))
                stack.enter_context(contextlib.redirect_stderr(stderr))
                hook.main()
            _, directory = hook.storage_dir(str(project.resolve()))
            saved = [json.loads(path.read_text(encoding="utf-8"))
                     for path in pathlib.Path(directory).glob("*.json")]
            return stdout.getvalue(), stderr.getvalue(), saved[0] if saved else None
        finally:
            for key, value in previous.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value

def record_complete():
    out, _, record = invoke_postcompact(TRANSLATED)
    assert json.loads(out) == {} and record is not None
    checked = record["handoff_check"]
    assert checked["section_present"] is True
    assert checked["missing_fields"] == []
    assert len(checked["fields"]) == len(rules())
    assert all(field["present"] and field["by"] == "marker"
               for field in checked["fields"])
    out, _, english_record = invoke_postcompact(EN)
    assert json.loads(out) == {} and english_record is not None
    english_fields = english_record["handoff_check"]["fields"]
    assert all(field["present"] and field["by"] == "alias" for field in english_fields)
check("record-complete", record_complete)

def record_unmanaged():
    out, err, record = invoke_postcompact(ZH, managed=False)
    assert json.loads(out) == {} and record is not None
    assert "handoff_check" not in record
    assert "交接" not in err
check("record-unmanaged", record_unmanaged)

def record_failure(kind):
    out, err, record = invoke_postcompact("SYNTHETIC_SECRET_BODY", failure=kind)
    assert json.loads(out) == {} and record is not None
    assert "handoff_check" not in record
    assert record["summary"] == "SYNTHETIC_SECRET_BODY"
    assert "SYNTHETIC_SECRET_BODY" not in err
    assert len(err.strip().splitlines()) == 1
    assert ("OSError" if kind == "read" else "ValueError") in err
check("record-read-error", lambda: record_failure("read"))
check("record-parse-error", lambda: record_failure("parse"))

def record_legacy():
    old = {"summary": "## Current Work\nsynthetic legacy summary", "session_id": "old",
           "created_at_epoch": 0, "transcript_path": "/nonexistent/synthetic-transcript"}
    with tempfile.TemporaryDirectory() as tmp:
        output = hook.render_handoff(tmp, [(str(pathlib.Path(tmp) / "old.json"), old)])
    assert "交接字段缺失" not in output and "这次摘要没有「交接」一节" not in output
check("record-legacy", record_legacy)

def render_pair(summary, checked):
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        transcript = root / "transcript.jsonl"
        transcript.write_text("synthetic", encoding="utf-8")
        path = str(root / "record.json")
        base = {"summary": summary, "session_id": "synthetic-session",
                "created_at_epoch": 0, "transcript_path": str(transcript),
                "created_at": "synthetic-time", "events": [], "consumed": False}
        checked_record = dict(base)
        if checked is not None:
            checked_record["handoff_check"] = checked
        legacy = hook.render_handoff(str(root), [(path, base)])
        rendered = hook.render_handoff(str(root), [(path, checked_record)])
        return legacy, rendered

def test_check_for(summary, missing=(), section=True, by="name"):
    fields = [{"name": rule["name"], "present": rule["name"] not in missing,
               "by": by if rule["name"] not in missing else None}
              for rule in rules()]
    return {"version": 1, "section_present": section, "fields": fields,
            "missing_fields": list(missing)}

def render_complete():
    base, rendered = render_pair(ZH, test_check_for(ZH))
    assert rendered.encode("utf-8") == base.encode("utf-8")
check("render-complete", render_complete)

def render_one_missing():
    name = rules()[0]["name"]
    _, text = render_pair(ZH, test_check_for(ZH, [name]))
    alert = next(line for line in text.splitlines() if "缺" in line)
    assert name in alert and "git status" in alert and "git log" in alert
    assert "synthetic" not in alert
check("render-one-missing", render_one_missing)

def render_many_missing():
    names = [rule["name"] for rule in rules()[:2]]
    _, text = render_pair(ZH, test_check_for(ZH, names))
    alert = next(line for line in text.splitlines() if "缺" in line)
    assert all(name in alert for name in names)
check("render-many-missing", render_many_missing)

def render_no_section():
    summary = "## Current Work\nsynthetic body"
    _, text = render_pair(summary, test_check_for(summary, [r["name"] for r in rules()], False))
    assert "这次摘要没有「交接」一节" in text
    assert "synthetic body" in text
check("render-no-section", render_no_section)

def render_legacy():
    base, rendered = render_pair(ZH, None)
    assert rendered.encode("utf-8") == base.encode("utf-8")
    assert "交接字段缺失" not in rendered and "这次摘要没有「交接」一节" not in rendered
check("render-legacy", render_legacy)

def render_budget():
    summary = "## 交接\n- next: SYNTHETIC_VALUE\n" + ("正文" * 10000)
    name = rules()[0]["name"]
    _, text = render_pair(summary, test_check_for(summary, [name]))
    assert len(text) <= 8000
    assert "历史压缩交接" in text
    alert = next(line for line in text.splitlines() if "缺" in line)
    assert name in alert and "git status" in alert
check("render-budget", render_budget)

def startup_p95():
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        project = root / "project"
        project.mkdir()
        transcript = root / "transcript.jsonl"
        transcript.write_text("synthetic", encoding="utf-8")
        env_names = ("XDG_DATA_HOME", "DRSG_COMPACT_HANDOFF")
        previous = {key: os.environ.get(key) for key in env_names}
        os.environ["XDG_DATA_HOME"] = str(root / "xdg")
        os.environ["DRSG_COMPACT_HANDOFF"] = "1"
        try:
            _, directory = hook.storage_dir(str(project.resolve()))
            os.makedirs(directory, mode=0o700, exist_ok=True)
            path = str(pathlib.Path(directory) / "synthetic.json")
            checks = [test_check_for(ZH), test_check_for(ZH, [rules()[0]["name"]])]
            samples = []
            for index in range(100):
                now = time.time()
                record = {"project_path": str(project.resolve()),
                          "summary": ZH, "session_id": "synthetic-session",
                          "created_at": "synthetic-time", "created_at_epoch": now,
                          "trigger": "manual", "transcript_path": str(transcript),
                          "branch": "synthetic-branch", "head": "synthetic-head",
                          "git_status": {"paths": [], "total": 0}, "events": [],
                          "consumed": False, "handoff_check": checks[index % len(checks)]}
                hook.atomic_write(path, record)
                started = time.perf_counter()
                text, pending = hook.prepare_handoff(str(project), "startup", {})
                samples.append(time.perf_counter() - started)
                assert text is not None and pending is not None
                pending.finish(False)
            p95 = sorted(samples)[int(len(samples) * .95) - 1]
            print("FIELDS_STARTUP_P95_MS=%.3f" % (p95 * 1000))
            assert p95 <= .050, "SessionStart P95 %.2fms > 50ms" % (p95 * 1000)
        finally:
            for key, value in previous.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value
check("startup-p95", startup_p95)

if only and not ran:
    print("not ok: no selected tests matched ONLY=" + ",".join(sorted(only)))
    raise SystemExit(2)
print("%d/%d checks passed" % (passed, ran))
raise SystemExit(0 if passed == ran else 1)
PY
