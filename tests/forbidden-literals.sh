#!/usr/bin/env bash
# Synthetic contract tests and mutation verification for forbidden-literals-guard.py.
# Fully hermetic: uses isolated temporary git repositories.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$HERE/../tools/forbidden-literals-guard.py"
INST="$HERE/../tools/install-precommit-guard.sh"
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
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Test"

# Initial base commit
echo "base" > "$REPO/base.txt"
git -C "$REPO" add base.txt
git -C "$REPO" commit -q -m "initial commit"

# 场景 1: F2 无名单文件时静默放行 (exit 0)
rc_f2=0
out_f2=$(python3 "$GUARD" --repo "$REPO" --staged 2>&1) || rc_f2=$?
check "scene1_f2_no_list_yields_exit_0" "$rc_f2" "0"

# 场景 2: F1 名单未被 git 忽略时报错并阻断 (exit 3)
mkdir -p "$REPO/.drsg"
echo "customer-secret.test" > "$REPO/.drsg/forbidden-literals"
rc_f1=0
out_f1=$(python3 "$GUARD" --repo "$REPO" --staged 2>&1) || rc_f1=$?
check "scene2_f1_unignored_list_yields_exit_3" "$rc_f1" "3"

# 场景 3: F3 暂存区含有名单敏感字面量时阻断 (exit 1)
echo ".drsg/" > "$REPO/.gitignore"
echo "call customer-secret.test" >> "$REPO/base.txt"
git -C "$REPO" add base.txt
rc_f3=0
out_f3=$(python3 "$GUARD" --repo "$REPO" --staged 2>&1) || rc_f3=$?
check "scene3_f3_staged_violation_yields_exit_1" "$rc_f3" "1"

# 场景 4: F4 输出包含规则号 #1 且严禁回显字面量本身
has_rule=0
echo "$out_f3" | grep -q "matches #1" && has_rule=1
check "scene4_f4_reports_rule_number" "$has_rule" "1"

echo_leaked=0
echo "$out_f3" | grep -q "customer-secret.test" && echo_leaked=1
check "scene4_f4_no_echo_literal" "$echo_leaked" "0"

# 场景 5: F5 提交信息文件含有敏感字面量时阻断 (exit 1)
MSG_FILE="$T/commit_msg.txt"
echo "commit message mentioning customer-secret.test" > "$MSG_FILE"
rc_f5=0
out_f5=$(python3 "$GUARD" --repo "$REPO" --commit-msg "$MSG_FILE" 2>&1) || rc_f5=$?
check "scene5_f5_commit_msg_violation_yields_exit_1" "$rc_f5" "1"

msg_has_rule=0
echo "$out_f5" | grep -q "COMMIT_MSG:1 matches #1" && msg_has_rule=1
check "scene5_f5_reports_commit_msg_rule_number" "$msg_has_rule" "1"

msg_leaked=0
echo "$out_f5" | grep -q "customer-secret.test" && msg_leaked=1
check "scene5_f5_no_echo_literal" "$msg_leaked" "0"

# 场景 6: F6 全历史扫描查出历史提交并输出短 SHA 与规则号，不回显字面量
git -C "$REPO" reset --hard HEAD >/dev/null 2>&1
echo "safe content" > "$REPO/safe.txt"
git -C "$REPO" add safe.txt
git -C "$REPO" commit -q -m "clean commit"

echo "dirty content with customer-secret.test" > "$REPO/dirty.txt"
git -C "$REPO" add dirty.txt
git -C "$REPO" commit -q -m "dirty commit"

rc_f6=0
out_f6=$(python3 "$GUARD" --repo "$REPO" --history 2>&1) || rc_f6=$?
check "scene6_f6_history_scan_yields_exit_1" "$rc_f6" "1"

history_has_match=0
echo "$out_f6" | grep -q "matches #1" && history_has_match=1
check "scene6_f6_reports_match_rule" "$history_has_match" "1"

history_leaked=0
echo "$out_f6" | grep -q "customer-secret.test" && history_leaked=1
check "scene6_f6_no_echo_literal" "$history_leaked" "0"

# 场景 7: P4 通过 git config 关闭守卫
git -C "$REPO" config --local drsg.forbiddenLiterals false
rc_p4=0
python3 "$GUARD" --repo "$REPO" --history >/dev/null 2>&1 || rc_p4=$?
check "scene7_p4_disabled_via_config_yields_exit_0" "$rc_p4" "0"
git -C "$REPO" config --local --unset drsg.forbiddenLiterals

# 场景 8: P7 错误正则 (如 re:[) 不回显表达式本身
echo "re:[" > "$REPO/.drsg/forbidden-literals"
echo "modified line" >> "$REPO/base.txt"
git -C "$REPO" add base.txt
rc_p7=0
out_p7=$(python3 "$GUARD" --repo "$REPO" --staged 2>&1) || rc_p7=$?
# GRD-2: a broken list is a configuration error (exit 3, as documented), not a
# content violation pinned on every added line.
check "scene8_p7_invalid_regex_yields_exit_3" "$rc_p7" "3"

regex_not_leaked=0
echo "$out_p7" | grep -q "invalid regex" && regex_not_leaked=1
check "scene8_p7_reports_invalid_regex" "$regex_not_leaked" "1"
blamed_line=0
echo "$out_p7" | grep -q "base.txt:" && blamed_line=1
check "scene8_grd2_invalid_regex_not_reported_against_content" "$blamed_line" "0"
names_list_line=0
echo "$out_p7" | grep -q "line 1: invalid regex" && names_list_line=1
check "scene8_grd2_names_the_list_line" "$names_list_line" "1"

# 场景 8c: GRD-2 空的 re: 会匹配一切，按配置错误拒绝
echo "re:" > "$REPO/.drsg/forbidden-literals"
rc_empty=0
out_empty=$(python3 "$GUARD" --repo "$REPO" --staged 2>&1) || rc_empty=$?
check "scene8c_grd2_empty_regex_yields_exit_3" "$rc_empty" "3"
empty_named=0
echo "$out_empty" | grep -q "line 1: empty regex" && empty_named=1
check "scene8c_grd2_reports_empty_regex" "$empty_named" "1"

# 还原 base.txt 与规则文件
git -C "$REPO" checkout -q HEAD -- base.txt
echo "customer-secret.test" > "$REPO/.drsg/forbidden-literals"

# 场景 8b: 以 "++" 开头的新增行同样要查（暂存区）
printf '++ customer-secret.test\n' >> "$REPO/base.txt"
git -C "$REPO" add base.txt
rc_pp=0
out_pp=$(python3 "$GUARD" --repo "$REPO" --staged 2>&1) || rc_pp=$?
check "scene8b_f3_added_line_starting_with_plus_plus_yields_exit_1" "$rc_pp" "1"
git -C "$REPO" checkout -q HEAD -- base.txt

# 场景 8c: 以 "++" 开头的新增行同样要查（--history）
HREPO="$T/hrepo"
git init -q -b main "$HREPO"
git -C "$HREPO" config user.email "test@example.com"
git -C "$HREPO" config user.name "Test"
printf '.drsg/\n' > "$HREPO/.gitignore"
printf '++ customer-secret.test\n' > "$HREPO/pp.txt"
git -C "$HREPO" add .gitignore pp.txt
git -C "$HREPO" commit -q -m "plus plus line"
mkdir -p "$HREPO/.drsg"
echo "customer-secret.test" > "$HREPO/.drsg/forbidden-literals"
rc_hpp=0
out_hpp=$(python3 "$GUARD" --repo "$HREPO" --history 2>&1) || rc_hpp=$?
check "scene8c_f6_history_line_starting_with_plus_plus_yields_exit_1" "$rc_hpp" "1"
hpp_has_file=0
echo "$out_hpp" | grep -q "pp.txt:1 matches #1" && hpp_has_file=1
check "scene8c_f6_reports_file_and_line" "$hpp_has_file" "1"

# ==============================================================================
# 变异自检函数（Mutation Verification）
# 返回：0 全杀，1 有存活，2 脚本错误
# ==============================================================================
run_mutation_verification() {
  local target_guard="$1"
  local skip_mutant="${2:-none}"
  local m1_killed=0
  local m2_killed=0
  local m3_killed=0

  # 准备纯净测试仓库
  local MT="$T/mut_repo"
  rm -rf "$MT"
  mkdir -p "$MT"
  git -C "$MT" init -q -b main
  git -C "$MT" config user.email "test@example.com"
  git -C "$MT" config user.name "Test"
  echo ".drsg/" > "$MT/.gitignore"
  echo "base" > "$MT/base.txt"
  git -C "$MT" add .
  git -C "$MT" commit -q -m "base"
  mkdir -p "$MT/.drsg"
  echo "customer-secret.test" > "$MT/.drsg/forbidden-literals"

  # 变异 1: 删掉 ignore 检查 (暂存区干净，仅名单未 ignore)
  if [ "$skip_mutant" != "mutant1" ]; then
    local M1_SCRIPT="$T/guard_m1.py"
    sed 's/ok, err = check_list_security(repo_root, list_path)/ok, err = True, None/' "$target_guard" > "$M1_SCRIPT"
    git -C "$MT" rm -q --cached .gitignore 2>/dev/null || true
    echo "" > "$MT/.gitignore"
    local rc1=0
    local out1
    out1=$(python3 "$M1_SCRIPT" --repo "$MT" --staged 2>&1) || rc1=$?
    echo ".drsg/" > "$MT/.gitignore"
    # 原版脚本应该退出 3 且输出 "not ignored"；如果变异体未能报出这个错误 (例如返回 0)，
    # 说明该测试用例成功阻断了变异体（变异体被杀死，m1_survived=0）。
    # 反之，若变异体依然能返回 3 且输出 not ignored，说明删除 check_list_security 没起作用（变异体存活）。
    if [ "$rc1" -eq 3 ] && echo "$out1" | grep -q "not ignored"; then
      m1_survived=1 # 变异体未能被该用例检测出来（存活了）
    else
      m1_survived=0 # 变异体成功被该用例杀死
    fi
  else
    m1_survived=1 # 故意模拟存活
  fi

  # 变异 2: 改成回显字面量 (暂存区含有敏感字面量)
  if [ "$skip_mutant" != "mutant2" ]; then
    local M2_SCRIPT="$T/guard_m2.py"
    sed 's/desc = err_desc or f"matches #{rule_idx}"/desc = f"matches #{rule_idx}: customer-secret.test"/' "$target_guard" > "$M2_SCRIPT"
    echo "call customer-secret.test" >> "$MT/base.txt"
    git -C "$MT" add "$MT/base.txt"
    local rc2=0
    local out2
    out2=$(python3 "$M2_SCRIPT" --repo "$MT" --staged 2>&1) || rc2=$?
    git -C "$MT" checkout -q HEAD -- "$MT/base.txt"
    # 原版脚本应该阻断且输出中绝对不含 customer-secret.test；
    # 变异体输出了 customer-secret.test，测试用例检测到回显并判定违规（变异体被杀死）。
    if echo "$out2" | grep -q "customer-secret.test"; then
      m2_survived=0 # 用例抓到了回显，成功杀死变异体
    else
      m2_survived=1 # 没抓到回显，变异体存活
    fi
  else
    m2_survived=1
  fi

  # 变异 3: 不查提交信息 (暂存区干净，仅提交信息含敏感词)
  if [ "$skip_mutant" != "mutant3" ]; then
    local M3_SCRIPT="$T/guard_m3.py"
    sed 's/violations = check_commit_msg(args.commit_msg, rules)/violations = []/' "$target_guard" > "$M3_SCRIPT"
    local MSG_TMP="$T/mut_msg.txt"
    echo "commit with customer-secret.test" > "$MSG_TMP"
    local rc3=0
    local out3
    out3=$(python3 "$M3_SCRIPT" --repo "$MT" --commit-msg "$MSG_TMP" 2>&1) || rc3=$?
    # 原版脚本必须退出 1 并包含 COMMIT_MSG:1 matches #1；
    # 变异体如果未能退出 1，说明该测试用例成功抓到了变异（变异体被杀死）。
    if [ "$rc3" -eq 1 ] && echo "$out3" | grep -q "COMMIT_MSG:1 matches #1"; then
      m3_survived=1 # 变异体未能被该用例检测出来（存活了）
    else
      m3_survived=0 # 变异体成功被该用例杀死
    fi
  else
    m3_survived=1
  fi

  if [ "$m1_survived" -eq 1 ]; then
    echo "MUTATION TEST FAILED: mutant 1 survived!"
    return 1
  fi
  if [ "$m2_survived" -eq 1 ]; then
    echo "MUTATION TEST FAILED: mutant 2 survived!"
    return 1
  fi
  if [ "$m3_survived" -eq 1 ]; then
    echo "MUTATION TEST FAILED: mutant 3 survived!"
    return 1
  fi

  echo "mutation verification: all 3 mutants killed"
  return 0
}

# 场景 9: 变异自检实跑（全部杀死时退出 0）
rc_mut=0
mut_out=$(run_mutation_verification "$GUARD" 2>&1) || rc_mut=$?
check "scene9_mutation_verification_kills_all_3" "$rc_mut" "0"

# 场景 10: 故意留一个变异不杀时自检脚本必须非 0 退出
rc_fake_mut=0
fake_out=$(run_mutation_verification "$GUARD" "mutant1" 2>&1) || rc_fake_mut=$?
check "scene10_mutation_verification_fails_on_survivor" "$rc_fake_mut" "1"

printf '\nPASS %d/%d\n' "$OK" "$RAN"
[ "$OK" -eq "$RAN" ]
