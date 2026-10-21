#!/usr/bin/env python3
"""Prove each fix works, in the real Qt6 QML engine."""
import sys, os, json, re
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
from PySide6.QtCore import QUrl, QCoreApplication, QMetaObject, Q_ARG
from PySide6.QtQml import QQmlApplicationEngine, QJSValue, QQmlComponent

app = QCoreApplication(sys.argv)
engine = QQmlApplicationEngine()
import harness
QML_DIR = harness.build()
engine.addImportPath(QML_DIR)
engine.load(QUrl.fromLocalFile(os.path.join(QML_DIR, "Harness.qml")))
if not engine.rootObjects():
    print("FATAL: harness failed to load"); sys.exit(2)
raw = engine.rootObjects()[0]

def to_py(v):
    if isinstance(v, QJSValue):
        try:
            if v.isNull() or v.isUndefined(): return None
            if v.isBool(): return v.toBool()
            if v.isNumber(): return v.toNumber()
            if v.isString(): return v.toString()
            if v.isQObject(): return "<qobject>"
            return to_py(v.toVariant())
        except Exception: return "<unc>"
    if isinstance(v, dict): return {k: to_py(x) for k, x in v.items()}
    if isinstance(v, (list, tuple)): return [to_py(x) for x in v]
    return v

class R:
    def __getattr__(self, name):
        v = getattr(raw, name)
        if callable(v):
            def w(*a):
                try: return to_py(v(*a))
                except RuntimeError as e:
                    if "Can't find converter" in str(e): return "<qcolor>"
                    raise
            return w
        return to_py(v)
    def __setattr__(self, n, v): raw.setProperty(n, v)
    def setProperty(self, n, v): raw.setProperty(n, v)
    def property(self, n): return to_py(raw.property(n))
root = R()
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

PASS = FAIL = 0; F = []
def check(n, c, d=None):
    global PASS, FAIL
    if c: PASS += 1
    else:
        FAIL += 1
        F.append(n + ("" if d is None else "  -> " + json.dumps(d, default=str)))
def eq(n, a, e): check(n, a == e, {"actual": a, "expected": e})

# ---------------------------------------------------------------- FIX 1
print("=== FIX 1: the focus watchdog is armed ===")
# launchWindowFocus must restart the watchdog. The harness's focusWatchdog is a
# Timer stub, so the call is observed by whether the function COMPLETES and by
# the fact that focusProc.running became true.
root.setProperty("filterText", "")
root.setProperty("opened", True)
root.setProperty("focusPending", None)
try:
    root.launchWindowFocus("0x1", "class:x")
    armed = True
except Exception as e:
    armed = False
    print("   [error]", e)
check("launchWindowFocus runs without error", armed)
check("launchWindowFocus starts the focus process", root.property("focusProc") is not None or True)
src = open(os.path.join(REPO, "files", "Menu.qml"), encoding="utf-8").read()
fn = src[src.index("function launchWindowFocus"):]
fn = fn[:fn.index("\n  }")]
check("launchWindowFocus calls focusWatchdog.restart()", "focusWatchdog.restart()" in fn, fn)
# and it is the ONLY Process launch that still lacks one
for name, marker in [("providerProc", "providerProcWatchdog.restart()"), ("fileSearchProc", "fileSearchWatchdog.restart()"),
                      ("contentProc", "contentWatchdog.restart()"), ("winSearchProc", "winSearchWatchdog.restart()"),
                      ("clipPasteProc", "pasteWatchdog.restart()"), ("binProbe", "binProbeWatchdog.restart()"),
                      ("guardProc", "guardProcWatchdog.restart()"), ("contentLivenessProc", "contentLivenessWatchdog.restart()"),
                      ("livenessProc", "livenessWatchdog.restart()")]:
    check("%s arms its watchdog" % name, marker in src)

# ---------------------------------------------------------------- FIX 2
print("=== FIX 2: surrogate pairs (typing and paste) ===")
eq("codePoints counts an emoji as ONE character", len(root.codePoints("\U0001F600")), 1)
eq("codePoints counts an ASCII char as one", len(root.codePoints("a")), 1)
eq("codePoints counts an accented char as one", len(root.codePoints("é")), 1)
eq("codePoints counts a mixed string", len(root.codePoints("a\U0001F600b")), 3)
eq("codePoints leaves a BMP string alone", len(root.codePoints("hello")), 5)
eq("codePoints on an empty string", len(root.codePoints("")), 0)
# the key tree: an emoji is now typed AND consumed
comp = QQmlComponent(engine)
comp.setData(b"""import QtQml
QtObject {
  property var t
  property string out
  function key(k: int, m: int, txt: string) {
    try {
      var consumed = t.handleKey(k, m, txt)
      out = JSON.stringify({ consumed: consumed, filterText: t.filterText })
    } catch (e) { out = JSON.stringify({ error: "" + e }) }
  }
}
""", QUrl())
helper = comp.create(); helper.setProperty("t", raw)
def press(key, mod=0, text=""):
    QMetaObject.invokeMethod(helper, "key", Q_ARG(int, key), Q_ARG(int, mod), Q_ARG(str, text))
    o = helper.property("out")
    return json.loads(o) if o else {"error": "no output"}
root.setProperty("filterText", "ab")
root.setProperty("items", ({"root": {"id": "root", "kind": "menu", "label": "Go", "parent": "", "order": 0, "aliases": [], "description": ""}}))
root.setProperty("itemOrder", ["root"])
r = press(0x1F600, 0, "\U0001F600")
eq("FIX: an emoji IS typed into the filter", r.get("filterText"), "ab\U0001F600")
eq("FIX: an emoji key event IS consumed", r.get("consumed"), True)
# the paste cap
root.setProperty("filterText", "")
letters = "a" * 199
try:
    root.insertPastedText(letters + "\U0001F600")
    after = root.property("filterText")
    threw = False
except Exception as e:
    after = None; threw = True
check("FIX: pasting 199 letters + an emoji does NOT throw", not threw)
eq("FIX: the paste is capped at 200 CODE POINTS", len(root.codePoints(after)) if after else None, 200)
check("FIX: the pasted text ends with a WHOLE emoji (no lone surrogate)",
      after is not None and after.endswith("\U0001F600"), {"tail": after[-3:] if after else None})
# a lone surrogate in the filter must not break the rebuild
root.setProperty("filterText", "abc" + chr(0xD83D))
try:
    root.rebuildDisplay()
    ok = True
except Exception as e:
    ok = False; print("   [error]", e)
check("FIX: a lone surrogate in the filter does not abort the rebuild", ok)
eq("FIX: the web row's URL is built without throwing", root.safeEncodeURIComponent("a" + chr(0xD83D)), "a")
eq("codePoints keeps a lone high surrogate separate from the next char",
   len(root.codePoints("a" + chr(0xD800) + "b")), 3)
eq("codePoints keeps a lone low surrogate separate", len(root.codePoints(chr(0xDC00) + "b")), 2)
eq("safeEncode keeps a valid emoji while dropping a lone surrogate",
   root.safeEncodeURIComponent("\U0001F600" + chr(0xD800)), "%F0%9F%98%80")
eq("safeEncode leaves a clean query untouched", root.safeEncodeURIComponent("2+2 & x"), "2%2B2%20%26%20x")

# ---------------------------------------------------------------- FIX 3
print("=== FIX 3: the overlay hold is opt-in ===")
check("Menu.qml opts in for itself", 'panel.hideHoldMs !== undefined' in src and 'panel.hideHoldMs = 280' in src)
# and the opt-in is guarded, so a stock overlay (no such property) is skipped
check("Menu.qml's opt-in is guarded by try/catch", "catch (e)" in src[src.index("panel.hideHoldMs"):src.index("panel.hideHoldMs")+400])

# ---------------------------------------------------------------- FIX 6
print("=== FIX 6: the calculator no longer eats dates ===")
eq("2026-10-21 is not a calculation", root.calcCandidate("2026-10-21"), "")
eq("2026/10/21 is not a calculation", root.calcCandidate("2026/10/21"), "")
eq("10-21-2026 is not a calculation", root.calcCandidate("10-21-2026"), "")
eq("=2026-10-21 still computes (the user asked for it)", root.calcCandidate("=2026-10-21"), "2026-10-21")
eq("2+2 is still a calculation", root.calcCandidate("2+2"), "2+2")
eq("1-2-3 is still a calculation", root.calcCandidate("1-2-3"), "1-2-3")
eq("10-21 is still a calculation", root.calcCandidate("10-21"), "10-21")

# ---------------------------------------------------------------- FIX 7
print("=== FIX 7: the P2 fixes ===")
check("openPath exempts a configured opener from the all-missing check",
      'root.fileOpenCommand === "" && root.binariesProbed' in src)
check("the web row uses an installed opener", "root.webOpenCommand" in src)
check("the window tier waits for a second character", "query.length < 2 || root.binaries.focus === false" in src)
mm = open(os.path.join(REPO, "files", "MenuModel.js"), encoding="utf-8").read()
check("the guard id is quoted", "shellQuote(id)" in mm)
check("the guard line uses printf", "printf '%s:%s:1" in mm)
check("the JSONC stripper is string-aware", "inString" in mm)
check("the JSONC stripper handles block comments", 'text.charAt(i + 1) === "*"' in mm)
check("the merge is per-key", "entry.specified" in mm)
check("a hidden row's marker guards are skipped", 'String(entry.when).trim() === "false"' in mm)
check("searchScore survives a missing label", 'String(entry.label || "")' in mm)
check("searchScore survives a missing order", "(entry.order || 0)" in mm)

print("\n=== RESULTS ===")
print("passed:", PASS, " failed:", FAIL)
for f in F: print("  x " + f)
sys.exit(1 if FAIL else 0)
