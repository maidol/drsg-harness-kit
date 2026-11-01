#!/usr/bin/env python3
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "tools/claude-model-discovery.py"
TESTS = ROOT / "tests/test_model_picker_discovery.py"
MUTATIONS = [
    ("threshold", "test_route_suffix_contract_is_independent",
     'and capacity >= 1_000_000', 'and capacity > 1_000_000'),
    ("suffix", "test_route_suffix_contract_is_independent",
     'route_id += "[1m]"', 'route_id = response_id'),
    ("capacity-source", "test_max_tokens_is_not_input_capacity",
     'row.get("max_input_tokens")', 'row.get("max_tokens")'),
    ("control-filter", "test_c1_and_format_names_fall_back",
     'if any(unicodedata.category(char) in ("Cc", "Cf") for char in value):', 'if False:'),
    ("truncate", "test_truncation_keeps_complete_utf8_and_capacity_suffix",
     'rows_by_route.append((route_id, _truncate_utf8(name, 111), capacity_suffix))', 'rows_by_route.append((route_id, name, capacity_suffix))'),
    ("user-agent", "test_exact_client_user_agent",
     ', "User-Agent": "claude-model-discovery/1"', ''),
    ("duplicate-order", "test_duplicate_conflict_both_orders",
     'capacities = {capacity for capacity, _ in sources if capacity is not None}\n        capacity = next(iter(capacities)) if len(capacities) == 1 else None',
     'capacity = sources[0][0]'),
    ("duplicate-label-index", "test_duplicate_labels_unique_for_shared_tail_and_truncated_name",
     'disambiguator = f" (#{index})"', 'disambiguator = " (#1)"'),
    ("surrogate-fallback", "test_json_surrogate_name_falls_back_without_dropping_rows",
     'except UnicodeEncodeError:\n        return response_id', 'except UnicodeEncodeError:\n        return "unusable-name"'),
]


def fixture(root, mutate=None, assertion_removed=False):
    tools = root / "tools"
    tests = root / "tests"
    tools.mkdir(parents=True)
    tests.mkdir()
    source = SOURCE.read_text()
    if mutate:
        _, _, old, new = mutate
        if source.count(old) != 1:
            raise RuntimeError("mutation anchor is not unique: " + mutate[0])
        source = source.replace(old, new)
    test = TESTS.read_text()
    if assertion_removed:
        old = '        self.assertEqual(opener.request.get_header("User-agent"), "claude-model-discovery/1")\n'
        if test.count(old) != 1:
            raise RuntimeError("UA assertion anchor is not unique")
        test = test.replace(old, "")
    (tools / SOURCE.name).write_text(source)
    shutil.copy2(ROOT / "tools/claude-model-picker.sh", tools / "claude-model-picker.sh")
    (tests / TESTS.name).write_text(test)


def run_case(root, case):
    return subprocess.run(
        ["python3", "-I", "tests/test_model_picker_discovery.py", "TestDiscovery." + case],
        cwd=root, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )


with tempfile.TemporaryDirectory(prefix="model-picker-mutants-") as temp:
    temp = Path(temp)
    baseline = temp / "baseline"
    fixture(baseline)
    result = subprocess.run(["python3", "-I", "tests/test_model_picker_discovery.py"],
                           cwd=baseline, text=True, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT)
    if result.returncode != 0:
        print("未变异对照失败（不是存活判定）")
        print(result.stdout, end="")
        print("末行：没有跑起来")
        raise SystemExit(2)
    print("未变异对照：通过")

    alive = []
    not_run = []
    for mutation in MUTATIONS:
        root = temp / mutation[0]
        fixture(root, mutation)
        result = run_case(root, mutation[1])
        expected = "FAIL: " + mutation[1]
        killed = result.returncode == 1 and expected in result.stdout and "ERROR:" not in result.stdout
        if killed:
            print("已杀死：" + mutation[0] + " — " + expected)
        elif result.returncode == 0:
            alive.append(mutation[0])
            print("存活：" + mutation[0])
        else:
            not_run.append(mutation[0])
            print("没有跑起来：" + mutation[0])
            print(result.stdout, end="")

    control = next(m for m in MUTATIONS if m[0] == "user-agent")
    reverse = temp / "reverse-assertion"
    fixture(reverse, control, assertion_removed=True)
    result = run_case(reverse, control[1])
    reverse_alive = result.returncode == 0
    print("删掉 UA 断言的隔离反向控制：" + ("存活" if reverse_alive else "未达到预期"))

    try:
        subprocess.run(["/definitely/missing-model-picker-python"], check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        no_run_detected = False
    except FileNotFoundError:
        no_run_detected = True
    print("未运行反向控制：" + ("已识别" if no_run_detected else "未识别"))

    if alive:
        print("末行：存在存活变异 " + ",".join(alive))
        raise SystemExit(1)
    if not_run or not reverse_alive or not no_run_detected:
        print("末行：变异未全部通过自检")
        raise SystemExit(2)
    print("反向控制：预期存活；命令未启动：已识别")
    print("末行：全部变异均被对应断言杀死")
