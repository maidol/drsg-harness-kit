# claude-model-picker.sh — ask which model to use before an interactive `claude`.
#
# Sourced from ~/.bashrc (`setup.sh --model-picker` adds the line), it defines
# a shell function `claude` that shows a short menu and then runs the real
# binary with `--model <choice>` in front of your own arguments. A function,
# not a wrapper script: it adds no process, so the Claude Code process is still
# the one whose argv starts with `claude` — event-poller.py ties its lease to
# exactly that process.
#
# Answer with a number from the menu, or type any model name or full id. Enter
# alone starts with the default (the `model` in settings.json). Ctrl+C or
# Ctrl+D starts nothing.
#
# No menu — the real `claude` runs with your arguments unchanged — when:
#   stdin or stdout is not a terminal (scripts, pipes, IDE launchers);
#   CLAUDE_PICK_MODEL=0;
#   the arguments already say --model, -p/--print, -h/--help or -v/--version;
#   the first argument is a subcommand (attach, mcp, doctor, ...).
#
# CLAUDE_PICK_MODELS overrides the menu (space-separated aliases or ids).
# CLAUDE_PICK_FORCE_TTY=1 treats stdin/stdout as a terminal (tests only).
# bash only.

claude() {
  local a
  if [ "${CLAUDE_PICK_MODEL:-1}" = 0 ]; then
    command claude "$@"; return
  fi
  if [ "${CLAUDE_PICK_FORCE_TTY:-0}" != 1 ] && { [ ! -t 0 ] || [ ! -t 1 ]; }; then
    command claude "$@"; return
  fi
  case "${1-}" in
    agents|attach|auth|auto-mode|doctor|gateway|import|install|logs|mcp|plugin|plugins|\
    project|respawn|rm|setup-token|stop|kill|ultrareview|update|upgrade)
      command claude "$@"; return ;;
  esac
  for a in "$@"; do
    case "$a" in
      --model|--model=*|-p|--print|-h|--help|-v|--version)
        command claude "$@"; return ;;
    esac
  done

  local picker_dir
  picker_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  local -a models=()
  if [ -n "${CLAUDE_PICK_MODELS:-}" ]; then
    read -r -a models <<< "$CLAUDE_PICK_MODELS"
  fi
  if [ "${#models[@]}" -eq 0 ]; then
    mapfile -t models < <(python3 "$picker_dir/claude-model-discovery.py" 2>/dev/null)
  fi
  if [ "${#models[@]}" -eq 0 ]; then
    read -r -a models <<< "opus sonnet haiku fable"
  fi
  local i choice
  echo "Model for this session (Enter = default from settings, Ctrl+C = cancel):" >&2
  for i in "${!models[@]}"; do
    printf '  %d) %s\n' "$((i + 1))" "${models[i]}" >&2
  done
  if ! read -r -p "> " choice; then
    echo >&2
    return 130
  fi
  if [ -z "$choice" ]; then
    command claude "$@"
  elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#models[@]}" ]; then
    command claude --model "${models[choice - 1]}" "$@"
  else
    command claude --model "$choice" "$@"
  fi
}
