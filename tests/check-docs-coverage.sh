#!/usr/bin/env bash
# Synthetic contract tests for documentation completeness & coverage gate (COV0-COV4).
# Fully hermetic: uses temporary git repositories.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK_DOCS="$HERE/../tools/check-docs.py"
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

git -C "$REPO" add .
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
git -C "$REPO" add .
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

printf '\nPASS %d/%d\n' "$OK" "$RAN"
[ "$OK" -eq "$RAN" ]
