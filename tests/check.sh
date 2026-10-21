#!/usr/bin/env bash
# Verification entry point for this repository: `make check`, or
# `bash tests/check.sh`. Exits non-zero if any suite fails. A suite that
# cannot run here is reported as "skip" with the reason, never as a pass.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2

PASS=0 FAIL=0 SKIP=0
FAILED=()
ok()   { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); FAILED+=("$1"); printf '  FAIL  %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf '  skip  %s\n' "$1"; }

run() {
  local name="$1"; shift
  local log; log=$(mktemp)
  if "$@" >"$log" 2>&1; then
    local summary; summary=$(grep -oE 'passed: [0-9]+' "$log" | tail -1)
    ok "$name${summary:+ — $summary}"
  else
    bad "$name"
    tail -n 20 "$log" | sed 's/^/        /'
  fi
  rm -f "$log"
}

printf '==> static\n'
if node --check files/MenuModel.js 2>/dev/null; then ok "MenuModel.js parses"; else bad "MenuModel.js parses"; fi
if [[ -x /usr/lib64/qt6/bin/qmllint ]] || command -v qmllint >/dev/null 2>&1; then
  QMLLINT=$(command -v qmllint || echo /usr/lib64/qt6/bin/qmllint)
  out=$("$QMLLINT" -I "$ROOT/files" files/Menu.qml 2>&1 || true)
  if printf '%s' "$out" | grep -qE '(^|[^a-zA-Z])Error:'; then
    bad "qmllint reports no errors"
    printf '%s\n' "$out" | grep -E 'Error:' | head -5 | sed 's/^/        /'
  else
    ok "qmllint reports no errors"
  fi
else
  skip "qmllint not installed"
fi

printf '\n==> model layer (Node)\n'
run "MenuModel.js suite"        node tests/model/test_model.js
run "MenuModel.js fixes"        node tests/model/test_fixes.js
run "hostility probes"          node tests/model/test_hostility.js

printf '\n==> QML functions (real Qt6 engine)\n'
if python3 -c 'import PySide6' 2>/dev/null; then
  run "launcher functions"      python3 tests/qml/test_functions.py
  run "key decision tree"       python3 tests/qml/test_keys.py
  run "selection model"         python3 tests/qml/test_selection.py
  run "fix contracts"           python3 tests/qml/test_fixes.py
else
  skip "PySide6 not installed (pip install PySide6 to run the QML suites)"
fi

printf '\n==> editions\n'
if [[ -f ../omarchy-launcher-v2/files/Menu.qml ]]; then
  for f in Menu.qml MenuModel.js; do
    if cmp -s "files/$f" "../omarchy-launcher-v2/files/$f"; then ok "files/$f identical in both editions"; else bad "files/$f identical in both editions"; fi
  done
else
  skip "pack checkout not beside this one — edition comparison needs both"
fi

printf '\n==> %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
for f in "${FAILED[@]:-}"; do [[ -n "$f" ]] && printf '  x %s\n' "$f"; done
exit $((FAIL > 0 ? 1 : 0))
