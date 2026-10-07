#!/usr/bin/env bash
# Contract tests for tools/permission-guard.py and its setup.sh wiring.
# Synthetic settings files only. The last line is "PASS n/n" only when every check ran.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PG="$HERE/../tools/permission-guard.py"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" CLAUDE_CONFIG_DIR="$T/claude" DRSG_MEM_DIR="$T/mem"
mkdir -p "$HOME" "$CLAUDE_CONFIG_DIR" "$T/proj/.claude" "$T/ws/reviews"
P="$T/proj"; R="$T/ws/reviews"; L="$P/.claude/settings.local.json"; U="$CLAUDE_CONFIG_DIR/settings.json"

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
# count RULE in the list KEY of FILE's permissions (or autoMode with a 4th arg)
count() {
  python3 - "$1" "$2" "$3" "${4:-permissions}" <<'PY'
import json, sys
path, key, rule, block = sys.argv[1:]
try:
    data = json.load(open(path)).get(block, {}).get(key, [])
except (OSError, ValueError):
    data = []
print(sum(1 for r in data if (r == rule if not rule.startswith("~") else rule[1:] in r)))
PY
}

# --- project scope -------------------------------------------------------
cat > "$L" <<'JSON'
{"env": {"KEEP": "1"}, "permissions": {"allow": ["Bash(python3 *)", "Bash(rtk git *)", "Bash(make build *)"]}}
JSON
chmod 600 "$L"
echo '{"permissions": {"allow": ["Bash(tracked *)"]}}' > "$P/.claude/settings.json"
SHARED_BEFORE="$(cksum < "$P/.claude/settings.json")"

OUT="$(python3 "$PG" apply --project "$P")"
check "apply adds the push ask rule"              "$(count "$L" ask 'Bash(git push *)')" 1
check "apply adds 19 ask rules"                   "$(python3 -c "import json;print(len(json.load(open('$L'))['permissions']['ask']))")" 19
check "ask covers git -C DIR commit"              "$(count "$L" ask 'Bash(git -C * commit *)')" 1
check "ask covers rtk git push"                   "$(count "$L" ask 'Bash(rtk git push *)')" 1
check "ask covers gh pr create"                   "$(count "$L" ask 'Bash(gh pr create *)')" 1
check "allow adds git -C <project> status"        "$(count "$L" allow "Bash(git -C $P status *)")" 1
check "allow adds event.py done under tools dir"  "$(count "$L" allow "Bash(python3 $DRSG_MEM_DIR/tools/event.py done *)")" 1
check "foreign allow rule kept"                   "$(count "$L" allow 'Bash(make build *)')" 1
check "broad rule kept without --prune-broad"     "$(count "$L" allow 'Bash(python3 *)')" 1
check "broad rule reported"                       "$(echo "$OUT" | grep -c 'broad: *Bash(python3 \*)')" 1
check "git write allow reported as kept"          "$(echo "$OUT" | grep -c 'kept: *Bash(rtk git \*)')" 1
check "other keys kept"                           "$(python3 -c "import json;print(json.load(open('$L'))['env']['KEEP'])")" 1
check "file mode kept"                            "$(stat -c %a "$L")" 600
check "tracked settings.json untouched"           "$(cksum < "$P/.claude/settings.json")" "$SHARED_BEFORE"

OUT="$(python3 "$PG" apply --project "$P")"
check "second apply adds nothing"                 "$(echo "$OUT" | grep -c 'already current')" 1
check "no duplicate after second apply"           "$(count "$L" ask 'Bash(git push *)')" 1

python3 "$PG" check --project "$P" >/dev/null;  check "check is clean after apply" "$?" 0
python3 - "$L" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["permissions"]["ask"].remove("Bash(git push *)")
json.dump(d, open(sys.argv[1], "w"))
PY
python3 "$PG" check --project "$P" >/dev/null;  check "check reports a missing rule" "$?" 1

python3 "$PG" apply --project "$P" --prune-broad >/dev/null
check "--prune-broad removes python3 *"           "$(count "$L" allow 'Bash(python3 *)')" 0
check "--prune-broad keeps rtk git *"             "$(count "$L" allow 'Bash(rtk git *)')" 1

python3 "$PG" remove --project "$P" >/dev/null
check "remove drops our ask rules"                "$(count "$L" ask 'Bash(git push *)')" 0
check "remove drops our allow rules"              "$(count "$L" allow "Bash(git -C $P status *)")" 0
check "remove keeps foreign rules"                "$(count "$L" allow 'Bash(make build *)')" 1

# --- user scope ----------------------------------------------------------
python3 - "$U" "$T/ws" "$R" <<'PY'
import json, sys
path, ws, reviews = sys.argv[1:]
json.dump({"theme": "dark", "autoMode": {
    "environment": ["**Organization**: None configured",
                    "**Trusted local workspace**: %s is the user's private repo (hand-written)" % ws],
    "allow": ["$defaults", "Running a copy of a script from %s/<project>/ (hand-written)" % reviews]}},
    open(path, "w"))
PY
chmod 600 "$U"
python3 "$PG" apply --user --reviews-dir "$R" >/dev/null
check "user env entry added with marker"          "$(count "$U" environment '~(drsg-harness-kit permission-guard) **Trusted local workspace**' autoMode)" 1
check "hand-written env entry replaced"           "$(count "$U" environment '~(hand-written)' autoMode)" 0
check "hand-written allow entry replaced"         "$(count "$U" allow '~(hand-written)' autoMode)" 0
check "two marked allow entries"                  "$(count "$U" allow '~(drsg-harness-kit permission-guard)' autoMode)" 2
check "allow keeps \$defaults"                    "$(count "$U" allow '$defaults' autoMode)" 1
check "foreign env entry kept"                    "$(count "$U" environment '**Organization**: None configured' autoMode)" 1
check "user settings other keys kept"             "$(python3 -c "import json;print(json.load(open('$U'))['theme'])")" dark
check "user settings mode kept"                   "$(stat -c %a "$U")" 600
check "allow entry requires a Write-visible copy" "$(count "$U" allow '~with a Write call earlier in this session' autoMode)" 1
OUT="$(python3 "$PG" apply --user --reviews-dir "$R")"
check "second user apply adds nothing"            "$(echo "$OUT" | grep -c 'already current')" 1
python3 "$PG" check --user --reviews-dir "$R" >/dev/null; check "user check clean" "$?" 0
python3 "$PG" remove --user >/dev/null
check "user remove drops marked entries"          "$(count "$U" allow '~(drsg-harness-kit permission-guard)' autoMode)" 0
check "user remove keeps foreign entries"         "$(count "$U" environment '**Organization**: None configured' autoMode)" 1
python3 "$PG" apply --user >/dev/null 2>&1;                       check "--user needs --reviews-dir" "$?" 2
python3 "$PG" apply --user --reviews-dir "$T/nope" >/dev/null 2>&1; check "--reviews-dir must exist" "$?" 2
python3 "$PG" apply >/dev/null 2>&1;                               check "needs --project or --user" "$?" 2

# --- setup.sh wiring -----------------------------------------------------
rm -f "$L" "$U"
bash "$HERE/../setup.sh" --no-skills --no-event-poller --no-streak-hint \
  --permission-guard "$P" --reviews-dir "$R" >/dev/null 2>&1
check "setup --permission-guard writes project rules" "$(count "$L" ask 'Bash(git push *)')" 1
check "setup --reviews-dir writes autoMode rules"     "$(count "$U" allow '~(drsg-harness-kit permission-guard)' autoMode)" 2
check 'fresh autoMode allow starts from $defaults' "$(python3 -c "import json;print(json.load(open('$U'))['autoMode']['allow'][0])")" '$defaults'
bash "$HERE/../setup.sh" --no-skills --no-event-poller --no-streak-hint --prune-broad >/dev/null 2>&1
check "setup rejects --prune-broad alone"             "$?" 1

printf '\nPASS %d/%d\n' "$OK" "$RAN"
[ "$RAN" -eq 43 ] && [ "$OK" -eq "$RAN" ]
