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
  local a picker_dir project_dir model_choice="" lane_selection="" lane_rc
  local show_model=1 show_lanes=1
  local -a models=() labels=() rows=()

  [ "${CLAUDE_PICK_MODEL:-1}" = 0 ] && show_model=0
  [ "${CLAUDE_PICK_LANES:-1}" = 0 ] && show_lanes=0
  [ "${DRSG_EVENT_LANES+x}" = x ] && show_lanes=0

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
      -p|--print|-h|--help|-v|--version)
        command claude "$@"; return ;;
      --model|--model=*) show_model=0 ;;
    esac
  done

  picker_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  if [ "$show_model" -eq 1 ]; then
    if [ -n "${CLAUDE_PICK_MODELS:-}" ]; then
      read -r -a models <<< "$CLAUDE_PICK_MODELS"
      labels=("${models[@]}")
    fi
    if [ "${#models[@]}" -eq 0 ]; then
      mapfile -t rows < <(python3 "$picker_dir/claude-model-discovery.py" 2>/dev/null)
      local row model label
      for row in "${rows[@]}"; do
        if [[ "$row" == *$'\t'* ]]; then
          model="${row%%$'\t'*}"
          label="${row#*$'\t'}"
        else
          model="$row"
          label="$row"
        fi
        models+=("$model")
        labels+=("$label")
      done
    fi
    if [ "${#models[@]}" -eq 0 ]; then
      read -r -a models <<< "opus sonnet haiku fable"
      labels=("${models[@]}")
    fi
    local i choice
    echo "Model for this session (Enter = default from settings, Ctrl+C = cancel):" >&2
    for i in "${!models[@]}"; do
      printf '  %d) %s\n' "$((i + 1))" "${labels[i]}" >&2
    done
    if ! read -r -p "> " choice; then
      echo >&2
      return 130
    fi
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#models[@]}" ]; then
      model_choice="${models[choice - 1]}"
    elif [ -n "$choice" ]; then
      model_choice="$choice"
    fi
  fi

  project_dir="$(pwd -P)"
  if [ "$show_lanes" -eq 1 ] && [ -f "$project_dir/.drsg/lanes" ]; then
    if lane_selection="$(python3 "$picker_dir/claude-lane-picker.py" "$project_dir")"; then
      :
    else
      lane_rc=$?
      if [ "$lane_rc" -eq 130 ]; then
        return 130
      fi
      printf 'ERROR: lane picker failed (exit %s); Claude was not started. Set CLAUDE_PICK_LANES=0 to bypass.\n' \
        "$lane_rc" >&2
      return 1
    fi
  fi

  if [ -n "$model_choice" ]; then
    if [ -n "$lane_selection" ]; then
      DRSG_EVENT_LANES="$lane_selection" command claude --model "$model_choice" "$@"
    else
      command claude --model "$model_choice" "$@"
    fi
  else
    if [ -n "$lane_selection" ]; then
      DRSG_EVENT_LANES="$lane_selection" command claude "$@"
    else
      command claude "$@"
    fi
  fi
}
