#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
python3 -I tests/event-reliability.py
python3 -I tests/event-retry-guard.py
