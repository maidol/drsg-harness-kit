#!/usr/bin/env bash
# Synthetic contract tests for documentation completeness & coverage gate (COV0-COV4) and resident rules size.
# Fully hermetic: uses temporary git repositories.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK_DOCS="${CHECK_DOCS_SOURCE:-$HERE/../tools/check-docs.py}"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

RAN=0
OK=0
check() {
  RAN=$((RAN + 1))
  if [ "$2" = "$3" ]; then
    OK=$((OK + 1))
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s: got %s want %s\n' "$1" "$2" "$3"
  fi
}

REPO="$T/repo"
mkdir -p "$REPO/tools" "$REPO/skills/codegraph"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Test"

# Create minimal initial setup satisfy all check-docs rules
cat > "$REPO/setup.sh" <<'SH'
#!/usr/bin/env bash
case "$1" in
  --existing-opt) echo ok ;;
  -h|--help) echo "Usage: setup.sh [--existing-opt]"; exit 0 ;;
esac
SH
chmod +x "$REPO/setup.sh"

cat > "$REPO/README.md" <<'MD'
# Test Project

```bash
./setup.sh --existing-opt
```

## Refresh the runtime copies
Use --project to refresh hooks.
MD

cat > "$REPO/README.zh-CN.md" <<'MD'
# 测试项目

```bash
./setup.sh --existing-opt
```

## 刷新运行时副本
使用 --project 刷新 hook 副本。
MD

cat > "$REPO/tools/install.sh" <<'SH'
#!/usr/bin/env bash
case "$1" in
  --tool-opt) echo ok ;;
  -h|--help) echo "Usage: install.sh [--tool-opt]"; exit 0 ;;
esac
SH
chmod +x "$REPO/tools/install.sh"

cat > "$REPO/tools/README.md" <<'MD'
# Tools

```bash
./install.sh --tool-opt
```
MD

cat > "$REPO/tools/README.zh-CN.md" <<'MD'
# 工具

```bash
./install.sh --tool-opt
```
MD

cat > "$REPO/skills/codegraph/SKILL.md" <<'MD'
# Codegraph
It checks six things and has a table:
| `skill` | desc |

## Where these scripts live
Use --project to refresh hooks.
MD

cat > "$REPO/skills/codegraph/SKILL.zh-CN.md" <<'MD'
# 代码图
检查六项内容。
| `skill` | 说明 |

## 脚本所在位置
使用 --project 刷新 hook 副本。
MD

touch "$REPO/tools/doc-coverage-baseline.txt"
cp "$CHECK_DOCS" "$REPO/tools/check-docs.py"
mkdir -p "$REPO/claude"
printf '%*s' 8010 '' | tr ' ' 'x' > "$REPO/claude/AGENT-EFFICIENCY.md"
cat > "$REPO/claude/CROSS-PROJECT-REVIEW.md" <<'MD'
# Full cross-project rules

This sentence is shared.
| key | value |

```bash
printf shared
```
MD
cat > "$REPO/claude/CROSS-PROJECT-EXECUTION.md" <<'MD'
# Full cross-project rules

审核方专用规则见完整版「入口与职责」「授权提交判定与时机」「Event 交接材料」各节。
This sentence is shared.
| key | value |

```bash
printf shared
```
MD
cat > "$REPO/claude/CROSS-PROJECT-COMMIT.md" <<'MD'
# Full cross-project rules

审核方的授权提交判定规则见完整版「授权提交判定与时机」一节。
This sentence is shared.
MD
cp "$REPO/claude/CROSS-PROJECT-EXECUTION.md" "$T/execution-valid.md"

git -C "$REPO" add setup.sh README.md README.zh-CN.md tools skills claude/AGENT-EFFICIENCY.md
git -C "$REPO" commit -q -m "initial baseline"

run_check() {
  (cd "$REPO" && python3 tools/check-docs.py) > "$T/out.txt" 2>&1
  return $?
}

# 场景 1: 新增一个 CLI 选项，文档不动 -> 应该在 COV1 失败
cat > "$REPO/setup.sh" <<'SH'
#!/usr/bin/env bash
case "$1" in
  --existing-opt) echo ok ;;
  --brand-new-flag) echo new ;;
  -h|--help) echo "Usage: setup.sh [--existing-opt] [--brand-new-flag]"; exit 0 ;;
esac
SH
run_check && s1_res=0 || s1_res=$?
cov1_caught=$(grep -q "COV1" "$T/out.txt" && echo "yes" || echo "no")
check "scene1_new_option_without_doc_fails_cov1" "$cov1_caught" "yes"

# 场景 2: 仅在表格中加一行，代码块中无示例 -> 应该在 COV1 失败
cat >> "$REPO/README.md" <<'MD'
| `--brand-new-flag` | off | new flag |
MD
cat >> "$REPO/README.zh-CN.md" <<'MD'
| `--brand-new-flag` | 关闭 | 新选项 |
MD
run_check && s2_res=0 || s2_res=$?
cov1_table_only=$(grep -q "COV1" "$T/out.txt" && echo "yes" || echo "no")
check "scene2_table_only_fails_cov1" "$cov1_table_only" "yes"

# 场景 3: 仅改英文文档代码块示例，中文文档漏加 -> 应该在 COV1 失败
cat >> "$REPO/README.md" <<'MD'
```bash
./setup.sh --brand-new-flag
```
MD
run_check && s3_res=0 || s3_res=$?
cov1_zh_missing=$(grep -q "COV1" "$T/out.txt" && echo "yes" || echo "no")
check "scene3_only_english_doc_fails_cov1" "$cov1_zh_missing" "yes"

# 补齐中文文档代码块，恢复场景
cat >> "$REPO/README.zh-CN.md" <<'MD'
```bash
./setup.sh --brand-new-flag
```
MD
git -C "$REPO" add -u
git -C "$REPO" commit -q -m "add brand new flag"

# 场景 4: 擅自往基线清单里加不存在或未出现的条目 -> 应该在 COV0 失败
echo "setup.sh:--unauthorized-baseline-entry" >> "$REPO/tools/doc-coverage-baseline.txt"
run_check && s4_res=0 || s4_res=$?
cov0_baseline_tamper=$(grep -q "COV0" "$T/out.txt" && echo "yes" || echo "no")
check "scene4_baseline_tamper_fails_cov0" "$cov0_baseline_tamper" "yes"
git -C "$REPO" checkout -q -- tools/doc-coverage-baseline.txt

# 场景 5: 选项在脚本里解析但在 --help 中漏写 -> 应该在 COV4 失败
cat > "$REPO/setup.sh" <<'SH'
#!/usr/bin/env bash
case "$1" in
  --existing-opt) echo ok ;;
  --brand-new-flag) echo new ;;
  --hidden-opt) echo hidden ;;
  -h|--help) echo "Usage: setup.sh [--existing-opt] [--brand-new-flag]"; exit 0 ;;
esac
SH
cat >> "$REPO/README.md" <<'MD'
```bash
./setup.sh --hidden-opt
```
MD
cat >> "$REPO/README.zh-CN.md" <<'MD'
```bash
./setup.sh --hidden-opt
```
MD
run_check && s5_res=0 || s5_res=$?
cov4_help_missing=$(grep -q "COV4" "$T/out.txt" && echo "yes" || echo "no")
check "scene5_help_missing_fails_cov4" "$cov4_help_missing" "yes"

# 场景 6: 补齐 --help，全部通过 -> 应该全绿 PASS 0
cat > "$REPO/setup.sh" <<'SH'
#!/usr/bin/env bash
case "$1" in
  --existing-opt) echo ok ;;
  --brand-new-flag) echo new ;;
  --hidden-opt) echo hidden ;;
  -h|--help) echo "Usage: setup.sh [--existing-opt] [--brand-new-flag] [--hidden-opt]"; exit 0 ;;
esac
SH
run_check && s6_code=0 || s6_code=$?
check "scene6_fully_covered_passes_all" "$s6_code" "0"

# 场景 7: tools/ 下新增工具还没 git add（未跟踪），文档没提 -> 应该在 COV2 失败
# （pre-commit 会在暂存后拦下它，提交前跑的 test-all 必须给出同样的结论）
printf '#!/usr/bin/env python3\n' > "$REPO/tools/new-tool.py"
run_check && s7_res=0 || s7_res=$?
cov2_untracked=$(grep -q "COV2.*new-tool.py" "$T/out.txt" && echo "yes" || echo "no")
check "scene7_untracked_new_tool_fails_cov2" "$cov2_untracked" "yes"

# 场景 8: 同一个文件暂存之后 -> 照样在 COV2 失败
git -C "$REPO" add tools/new-tool.py
run_check && s8_res=0 || s8_res=$?
cov2_staged=$(grep -q "COV2.*new-tool.py" "$T/out.txt" && echo "yes" || echo "no")
check "scene8_staged_new_tool_fails_cov2" "$cov2_staged" "yes"
git -C "$REPO" rm -q -f tools/new-tool.py

# The resident efficiency rules stay at or below the fixed token budget.
run_check && gate_under_rc=0 || gate_under_rc=$?
check "resident_efficiency_at_limit_passes" "$gate_under_rc" 0
check "resident_efficiency_at_limit_reports_estimate" \
  "$(grep -q 'AE1.*3500.*3500' "$T/out.txt" && echo yes || echo no)" yes
printf 'x' >> "$REPO/claude/AGENT-EFFICIENCY.md"
run_check && gate_over_rc=0 || gate_over_rc=$?
check "resident_efficiency_over_limit_fails" "$gate_over_rc" 1
check "resident_efficiency_over_limit_reports_estimate_and_limit" \
  "$(grep -q 'AE1.*3501.*3500' "$T/out.txt" && echo yes || echo no)" yes

legacy_tokens=$(python3 - "$CHECK_DOCS" "$HERE/.." <<'PY'
import pathlib
import runpy
import subprocess
import sys

check_docs, repo = sys.argv[1:]
namespace = runpy.run_path(check_docs)
legacy = subprocess.check_output(
    ["git", "-C", repo, "show", "83f8ce3:claude/AGENT-EFFICIENCY.md"],
    text=True,
)
print(namespace["estimate_tokens"](legacy))
PY
)
check "resident_efficiency_legacy_calibration_is_7672" "$legacy_tokens" 7672

# tools/README tells users to run check-docs.py from tools/; from there it must still check the whole repository.
(cd "$REPO/tools" && python3 check-docs.py) > "$T/out.txt" 2>&1 || true
check "check_docs_from_tools_dir_reports_ae1" \
  "$(grep -q 'AE1.*3501.*3500' "$T/out.txt" && echo yes || echo no)" yes

# Cross-project short rules are fixed inputs, budgeted per file and per read path.
git -C "$REPO" checkout -q -- claude/AGENT-EFFICIENCY.md
run_check && cross_base_rc=0 || cross_base_rc=$?
check "cross_project_valid_subset_passes" "$cross_base_rc" 0
check "cross_project_full_and_short_estimates_are_reported" \
  "$(grep -c 'CROSS-PROJECT-.*estimated .* tokens' "$T/out.txt" || true)" 3

cp "$REPO/claude/CROSS-PROJECT-REVIEW.md" "$T/full-valid.md"
python3 - "$CHECK_DOCS" "$REPO/claude/CROSS-PROJECT-EXECUTION.md" "$REPO/claude/CROSS-PROJECT-REVIEW.md" <<'PY'
import pathlib, runpy, sys
estimate = runpy.run_path(sys.argv[1])["estimate_tokens"]
paths = [pathlib.Path(p) for p in sys.argv[2:]]
size = 1
while estimate("x" * size) < 5001:
    size += 1
text = "x" * size
assert estimate(text) == 5001
for path in paths:
    path.write_text(text, encoding="utf-8")
PY
run_check && cross_oversize_rc=0 || cross_oversize_rc=$?
check "cross_project_5001_tokens_fails" "$cross_oversize_rc" 1
check "cross_project_5001_diagnostic_names_file_and_limit" \
  "$(grep -Fq 'FAIL  XPT   claude/CROSS-PROJECT-EXECUTION.md estimated 5001 tokens (limit 5000)' "$T/out.txt" && echo yes || echo no)" yes

cp "$T/full-valid.md" "$REPO/claude/CROSS-PROJECT-REVIEW.md"
cp "$T/execution-valid.md" "$REPO/claude/CROSS-PROJECT-EXECUTION.md"
rm "$REPO/claude/CROSS-PROJECT-EXECUTION.md"
run_check && cross_missing_rc=0 || cross_missing_rc=$?
check "cross_project_missing_required_file_fails" "$cross_missing_rc" 1
check "cross_project_missing_diagnostic_names_fixed_path" \
  "$(grep -Fq 'Missing required cross-project document: claude/CROSS-PROJECT-EXECUTION.md' "$T/out.txt" && echo yes || echo no)" yes

cp "$T/execution-valid.md" "$REPO/claude/CROSS-PROJECT-EXECUTION.md"
mv "$REPO/claude/CROSS-PROJECT-EXECUTION.md" "$REPO/claude/CROSS-PROJECT-EXECUTION-renamed.md"
run_check && cross_renamed_rc=0 || cross_renamed_rc=$?
check "cross_project_renamed_file_fails" "$cross_renamed_rc" 1
check "cross_project_rename_diagnostic_names_fixed_path" \
  "$(grep -Fq 'Missing required cross-project document: claude/CROSS-PROJECT-EXECUTION.md' "$T/out.txt" && echo yes || echo no)" yes
rm "$REPO/claude/CROSS-PROJECT-EXECUTION-renamed.md"
cp "$T/execution-valid.md" "$REPO/claude/CROSS-PROJECT-EXECUTION.md"
python3 - "$REPO/claude/CROSS-PROJECT-EXECUTION.md" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
path.write_text(text.replace("This sentence is shared.", "This sentence was changed."), encoding="utf-8")
PY
run_check && cross_sentence_rc=0 || cross_sentence_rc=$?
check "cross_project_non_subset_sentence_fails" "$cross_sentence_rc" 1
check "cross_project_sentence_diagnostic_names_unmatched_text" \
  "$(grep -Fq 'This sentence was changed.' "$T/out.txt" && echo yes || echo no)" yes

aggregate_budget=$(python3 - "$CHECK_DOCS" <<'PY'
import runpy, sys
ns = runpy.run_path(sys.argv[1])
violations = ns["cross_project_budget_violations"](
    {"a.md": 3000, "b.md": 3000}, {"combined": ("a.md", "b.md")})
print("yes" if any("combined" in v and "6000" in v for v in violations) else "no")
PY
)
check "cross_project_read_path_sum_is_checked" "$aggregate_budget" yes

route_coverage=$(python3 - "$CHECK_DOCS" <<'PY'
import runpy, sys
ns = runpy.run_path(sys.argv[1])
valid = ns["cross_project_routes_match_short_files"](
    ("execution.md", "commit.md"), {"execution": ("execution.md",), "commit": ("commit.md",)})
missing = ns["cross_project_routes_match_short_files"](
    ("execution.md", "commit.md"), {"execution": ("execution.md",)})
extra = ns["cross_project_routes_match_short_files"](
    ("execution.md", "commit.md"), {"execution": ("execution.md",), "commit": ("commit.md", "other.md")})
print("yes" if valid and not missing and not extra else "no")
PY
)
check "cross_project_routes_cover_short_files" "$route_coverage" yes

printf '\nPASS %d/%d\n' "$OK" "$RAN"
[ "$OK" -eq "$RAN" ]
