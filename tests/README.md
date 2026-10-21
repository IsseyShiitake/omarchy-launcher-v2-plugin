# Tests

`make check` (or `bash tests/check.sh`) runs everything that can run on this
machine and prints `ok`, `FAIL` or `skip` per check. A skip always names the
missing prerequisite — it is never counted as a pass.

| Suite | What it pins down | Needs |
|---|---|---|
| `model/test_model.js` | the model layer: JSONC, normalisation, merge, scoring, rows, guard batching | Node |
| `model/test_fixes.js` | per-key merge, quoted guard ids, a fixture guard batch, string-aware JSONC | Node |
| `model/test_hostility.js` | hostile ids, hostile JSONC, no shell execution from data | Node, bash |
| `qml/test_functions.py` | 233 assertions over the launcher's own functions, executed by a real Qt6 engine | PySide6 |
| `qml/test_keys.py` | the key decision tree, including emoji/surrogate handling | PySide6 |
| `qml/test_selection.py` | `nextSelectable` / `settleCursor` | PySide6 |
| `qml/test_fixes.py` | the fixed defects as contracts (watchdog armed, dates, openers, …) | PySide6, bash |
| `check.sh` editions | `files/Menu.qml` and `files/MenuModel.js` are byte-identical to the pack's | both checkouts side by side |

## The QML harness

`qml/extract.py` copies the top-level `function` blocks out of `files/Menu.qml`
verbatim, adds stubs for the shell objects they touch (`panel`, `displayModel`,
the `Process`es, the `Timer`s) and writes a `Harness.qml` in a temp directory;
`qml/harness.py` builds it on demand, keyed by `Menu.qml`'s mtime, and the
Python suites load it into `QQmlApplicationEngine` with
`QT_QPA_PLATFORM=offscreen`. The functions under test are the ones that ship,
not re-typed copies — the only synthetic part is the fake shell.

`Quickshell.env("HOME")` is stubbed to `/home/testuser`, so path assertions do
not depend on whose machine runs them.

## What is deliberately not here

- **Real-menu integration** (merging *your* `omarchy-menu.jsonc` and diffing the
  visible rows, timing the guard batch against your package probes). Those
  numbers only mean something on the machine they were measured on; they are a
  maintainer's local check, not a portable test.
- **The installer and patch tests** — they live in the pack repository, which
  owns `install.sh`, `uninstall.sh` and `patches/`.
- **Live-shell checks** (IPC summon/ping/close, shell log). They would need a
  running Omarchy session and would kill the user's menu to test it.

## Requirements

- Node 18+ (the suites use `node --check` and plain CommonJS).
- Python 3 + PySide6 for the QML suites; without it they are skipped.
- `bash` for the guard batches (they are the real generated scripts).
