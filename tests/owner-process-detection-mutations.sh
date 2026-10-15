#!/usr/bin/env bash
# Isolated mutations for the four Claude Code owner detectors.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
TEST="$HERE/owner-process-detection.sh"

if ! command -v node >/dev/null 2>&1; then
  printf 'SKIP owner-process-detection-mutations: node executable not found\n'
  exit 0
fi
for tool in bash python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'SKIP owner-process-detection-mutations: %s executable not found\n' "$tool"
    exit 0
  fi
done

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
KILLED=0
SURVIVED=0
NOT_RUN=0

run_mutation() {
  local name="$1" only="$2" variant="$3" target="$4"
  local dir="$T/$name" poller="$T/$name/poller.py"
  local session_start="$T/$name/session_start.py"
  local user_prompt="$T/$name/user_prompt.py" event="$T/$name/event.py"
  mkdir -p "$dir"
  cp "$REPO/tools/event-poller.py" "$poller"
  cp "$REPO/tools/templates/hooks/session_start.py" "$session_start"
  cp "$REPO/tools/templates/hooks/user_prompt.py" "$user_prompt"
  cp "$REPO/tools/event.py" "$event"

  if [ "$variant" != no-op ]; then
    local target_path
    case "$target" in
      poller) target_path="$poller" ;;
      session_start) target_path="$session_start" ;;
      user_prompt) target_path="$user_prompt" ;;
      event) target_path="$event" ;;
      all) target_path=all ;;
      *)
        printf 'MUTATION NOT RUN %s (unknown target)\n' "$name"
        NOT_RUN=$((NOT_RUN + 1))
        return
        ;;
    esac
    if ! python3 - "$variant" "$target_path" "$poller" "$session_start" "$user_prompt" "$event" <<'PY'
import sys

variant, target, *paths = sys.argv[1:]
node_rule = '''        is_node_claude = (
            len(argv) > 1
            and os.path.basename(argv[0]).startswith("node")
            and "/@anthropic-ai/claude-code/" in argv[1]
        )
'''
mutations = {
    "no-node-rule": [
        (node_rule, ""),
        ("        if is_native_claude or is_node_claude:\n",
         "        if is_native_claude:\n"),
    ],
    "no-package-path-gate": [
        (node_rule, '''        is_node_claude = (
            len(argv) > 0
            and os.path.basename(argv[0]).startswith("node")
        )
'''),
    ],
}
if variant not in mutations:
    raise SystemExit("unknown mutation")
selected = paths if target == "all" else [target]
for path in selected:
    text = open(path, encoding="utf-8").read()
    for old, new in mutations[variant]:
        if text.count(old) != 1:
            raise SystemExit("mutation target not unique: " + variant)
        text = text.replace(old, new, 1)
    with open(path, "w", encoding="utf-8") as out:
        out.write(text)
PY
    then
      printf 'MUTATION NOT RUN %s (mutation setup failed)\n' "$name"
      NOT_RUN=$((NOT_RUN + 1))
      return
    fi
  fi

  printf '\n== %s: ONLY=%s ==\n' "$name" "$only"
  if ONLY="$only" \
    SOURCE_POLLER="$poller" SOURCE_SESSION_START="$session_start" \
    SOURCE_USER_PROMPT="$user_prompt" SOURCE_EVENT="$event" \
    bash "$TEST"; then
    printf 'SURVIVED %s\n' "$name"
    SURVIVED=$((SURVIVED + 1))
  else
    printf 'killed %s\n' "$name"
    KILLED=$((KILLED + 1))
  fi
}

run_mutation no-poller-node-rule npm-poller no-node-rule poller
run_mutation no-session-start-node-rule npm-session-start no-node-rule session_start
run_mutation no-user-prompt-node-rule npm-user-prompt no-node-rule user_prompt
run_mutation no-event-node-rule npm-event no-node-rule event
run_mutation no-package-path-gate ccr-poller no-package-path-gate all
if [ "${MUTATION_SELF_TEST:-0}" = 1 ]; then
  run_mutation self-test-noop npm-event no-op all
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
