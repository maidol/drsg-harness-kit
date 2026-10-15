#!/usr/bin/env bash
# serve.sh hands the daemon the env file's values verbatim: the file is data
# (install.sh writes an L3 key into it), so `$(…)`, backticks and spaces in a
# value must reach the daemon as written and never run as shell.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
cat > "$T/fake-drsg" <<FAKE
#!/bin/sh
printf '%s' "\$OPENAI_API_KEY" > "$T/seen"
FAKE
chmod +x "$T/fake-drsg"
mkdir -p "$T/mem"
printf '%s\n' 'DRSG_TOKEN=test-token' "OPENAI_API_KEY=a\$(touch $T/pwned)\`touch $T/pwned2\`b c" > "$T/mem/env"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
DRSG_MEM_DIR="$T/mem" DRSG_MEM_BIN="$T/fake-drsg" DRSG_MEM_ADDR="127.0.0.1:$PORT" \
  bash "$REPO/tools/serve.sh" start >"$T/out" 2>&1   # fails readiness: the fake never listens
for _ in $(seq 1 20); do [ -f "$T/seen" ] && break; sleep 0.1; done
ran=0; ok=0
check() { ran=$((ran+1)); if [ "$2" = "$3" ]; then ok=$((ok+1)); echo "ok   $1"; else echo "FAIL $1: got [$2] want [$3]"; fi; }
check "no command substitution ran from the env file" "$([ -e "$T/pwned" ] || [ -e "$T/pwned2" ] && echo ran || echo none)" none
check "daemon sees the value verbatim" "$(cat "$T/seen" 2>/dev/null)" "a\$(touch $T/pwned)\`touch $T/pwned2\`b c"
echo "PASS $ok/$ran"
[ "$ok" = "$ran" ]
