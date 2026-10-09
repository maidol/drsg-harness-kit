#!/usr/bin/env bash
# Enable or disable the model picker in ~/.bashrc.
set -euo pipefail

usage() {
  printf 'Usage: claude-model-picker-config.sh {enable|disable}\n' >&2
  exit 2
}

[ "$#" -eq 1 ] || usage
case "$1" in
  enable|disable) action="$1" ;;
  *) usage ;;
esac

TOOLS_DIR_LOGICAL="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR_PHYSICAL="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
LOGICAL_LINE="[ -f \"$TOOLS_DIR_LOGICAL/claude-model-picker.sh\" ] && . \"$TOOLS_DIR_LOGICAL/claude-model-picker.sh\""
PHYSICAL_LINE="[ -f \"$TOOLS_DIR_PHYSICAL/claude-model-picker.sh\" ] && . \"$TOOLS_DIR_PHYSICAL/claude-model-picker.sh\""
RC="$HOME/.bashrc"

if [ -L "$RC" ]; then
  RC_TARGET="$(readlink -f -- "$RC")" || {
    printf 'ERROR: cannot resolve %s\n' "$RC" >&2
    exit 1
  }
  [ -n "$RC_TARGET" ] || {
    printf 'ERROR: cannot resolve %s\n' "$RC" >&2
    exit 1
  }
else
  RC_TARGET="$RC"
fi

has_line() {
  local line="$1"
  [ -f "$RC_TARGET" ] && grep -qxF -- "$line" "$RC_TARGET"
}

if [ "$action" = enable ]; then
  if has_line "$LOGICAL_LINE" || has_line "$PHYSICAL_LINE"; then
    printf 'model picker: already enabled in %s\n' "$RC"
    exit 0
  fi
fi

if [ "$action" = disable ]; then
  if [ ! -e "$RC_TARGET" ]; then
    printf 'model picker: already disabled in %s\n' "$RC"
    exit 0
  fi
  if ! has_line "$LOGICAL_LINE" && ! has_line "$PHYSICAL_LINE"; then
    printf 'model picker: already disabled in %s\n' "$RC"
    exit 0
  fi
fi

TMP1=""
TMP2=""
cleanup() {
  [ -z "$TMP1" ] || rm -f -- "$TMP1"
  [ -z "$TMP2" ] || rm -f -- "$TMP2"
}
trap cleanup EXIT

mkdir -p -- "$(dirname -- "$RC_TARGET")"
TMP1="$(mktemp "$(dirname -- "$RC_TARGET")/.claude-model-picker.XXXXXX")"
if [ -e "$RC_TARGET" ]; then
  cp -- "$RC_TARGET" "$TMP1"
else
  mask="$(umask)"
  mode="$(printf '%o' $(( 0666 & ~(8#$mask) )))"
  chmod "$mode" "$TMP1"
fi

if [ "$action" = enable ]; then
  if [ -s "$TMP1" ] && [ "$(tail -c 1 -- "$TMP1" | wc -l)" -eq 0 ]; then
    printf '\n' >> "$TMP1"
  fi
  printf '%s\n' "$LOGICAL_LINE" >> "$TMP1"
else
  TMP2="${TMP1}.filtered"
  if grep -vxF -- "$LOGICAL_LINE" "$TMP1" > "$TMP2"; then
    :
  else
    status=$?
    [ "$status" -eq 1 ] || {
      printf 'ERROR: failed reading %s\n' "$RC" >&2
      exit 1
    }
  fi
  if grep -vxF -- "$PHYSICAL_LINE" "$TMP2" > "${TMP1}.filtered2"; then
    :
  else
    status=$?
    [ "$status" -eq 1 ] || {
      printf 'ERROR: failed reading %s\n' "$RC" >&2
      exit 1
    }
  fi
  rm -f -- "$TMP2"
  TMP2="${TMP1}.filtered2"
  mv -- "$TMP2" "$TMP1"
  TMP2=""
fi

if [ -e "$RC_TARGET" ]; then
  chmod --reference="$RC_TARGET" "$TMP1"
fi
mv -- "$TMP1" "$RC_TARGET"
TMP1=""
if [ "$action" = enable ]; then
  printf 'model picker: enabled in %s (takes effect in a new shell)\n' "$RC"
else
  printf 'model picker: disabled in %s (takes effect in a new shell)\n' "$RC"
fi
