#!/usr/bin/env bash
# Isolated mutations for the EVT-STALL regressions.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
KILLED=0
SURVIVED=0
NOT_RUN=0

run_mutation() {
  local name="$1" only="$2" source="$3" variant="$4"
  local copy="$T/$name.py"
  cp "$REPO/tools/event.py" "$T/event.py"
  cp "$source" "$copy"
  if [ "$variant" != no-op ]; then
    if ! python3 - "$copy" "$variant" <<'PY'
import sys

path, variant = sys.argv[1:]
text = open(path, encoding="utf-8").read()
mutations = {
    "no-one-shot-guard": (
        'if (e.get("kind") == "handoff" and not entry.get("renudged")\n',
        'if (e.get("kind") == "handoff" and True\n'),
    "allow-notices": (
        'if (e.get("kind") == "handoff" and not entry.get("renudged")\n',
        'if (True and not entry.get("renudged")\n'),
    "no-legacy-compat": (
        '    if isinstance(value, list):\n',
        '    if False:\n'),
    "no-fresh-supersession": (
        '        lines.append("启动时的“没有 Event owner / 本会话只读”快照已过时；以本次唤醒为准。")\n',
        ''),
}
if variant not in mutations:
    raise SystemExit("unknown mutation")
old, new = mutations[variant]
if text.count(old) != 1:
    raise SystemExit("mutation target not unique: " + variant)
with open(path, "w", encoding="utf-8") as out:
    out.write(text.replace(old, new, 1))
PY
    then
      printf 'NOT RUN %s (mutation setup failed)\n' "$name"
      NOT_RUN=$((NOT_RUN + 1))
      return
    fi
  fi

  printf '\n== %s: ONLY=%s ==\n' "$name" "$only"
  if [ "$only" = fresh-wake ]; then
    if ONLY=fresh-wake POLLER="$copy" bash "$HERE/poller-lease-takeover.sh"; then
      printf 'SURVIVED %s\n' "$name"
      SURVIVED=$((SURVIVED + 1))
    else
      printf 'killed %s\n' "$name"
      KILLED=$((KILLED + 1))
    fi
  else
    if ONLY="$only" POLLER="$copy" bash "$HERE/event-renudge.sh"; then
      printf 'SURVIVED %s\n' "$name"
      SURVIVED=$((SURVIVED + 1))
    else
      printf 'killed %s\n' "$name"
      KILLED=$((KILLED + 1))
    fi
  fi
}

run_mutation no-one-shot-guard one-shot "$REPO/tools/event-poller.py" no-one-shot-guard
run_mutation allow-notices notice "$REPO/tools/event-poller.py" allow-notices
run_mutation no-legacy-compat legacy "$REPO/tools/event-poller.py" no-legacy-compat
run_mutation no-fresh-supersession fresh-wake "$REPO/tools/event-poller.py" no-fresh-supersession
if [ "${MUTATION_SELF_TEST:-0}" = 1 ]; then
  run_mutation self-test-noop one-shot "$REPO/tools/event-poller.py" no-op
fi

if [ "$NOT_RUN" -gt 0 ]; then
  printf 'MUTATION NOT RUN (%d)\n' "$NOT_RUN"
  exit 1
fi
if [ "$SURVIVED" -gt 0 ]; then
  printf 'MUTATION SURVIVED (%d)\n' "$SURVIVED"
  exit 1
fi
printf 'ALL MUTATIONS KILLED (%d)\n' "$KILLED"
