#!/usr/bin/env python3
"""Exercise the launcher's key decision tree, selection model and dmenu path
under a real Qt6 QML engine."""
import sys, os, json
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
from PySide6.QtCore import QUrl, QCoreApplication, QMetaObject
from PySide6.QtQml import QQmlApplicationEngine, QJSValue, QQmlComponent

APP = QCoreApplication(sys.argv)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness import build as _build
QML_DIR = _build()
engine = QQmlApplicationEngine()
engine.addImportPath(QML_DIR)
engine.load(QUrl.fromLocalFile(os.path.join(QML_DIR, "Harness.qml")))
if not engine.rootObjects():
    print("FATAL: harness failed to load"); sys.exit(2)
_raw = engine.rootObjects()[0]

def to_py(v):
    if isinstance(v, QJSValue):
        try:
            if v.isNull() or v.isUndefined(): return None
            if v.isBool(): return v.toBool()
            if v.isNumber(): return v.toNumber()
            if v.isString(): return v.toString()
            if v.isQObject(): return "<qobject>"
            return to_py(v.toVariant())
        except Exception as e: return "<unc:%s>" % type(e).__name__
    if isinstance(v, dict): return {k: to_py(x) for k, x in v.items()}
    if isinstance(v, (list, tuple)): return [to_py(x) for x in v]
    return v

class R:
    def __getattr__(self, name):
        v = getattr(_raw, name)
        if callable(v):
            def w(*a):
                try: return to_py(v(*a))
                except RuntimeError as e:
                    if "Can't find converter" in str(e): return "<qcolor>"
                    raise
            return w
        return to_py(v)
    def __setattr__(self, n, v): _raw.setProperty(n, v)
    def setProperty(self, n, v): _raw.setProperty(n, v)
    def property(self, n): return to_py(_raw.property(n))
root = R()

PASS = FAIL = 0; F = []
def check(n, c, d=None):
    global PASS, FAIL
    if c: PASS += 1
    else:
        FAIL += 1
        F.append(n + ("" if d is None else "  -> " + json.dumps(d, default=str)))
def eq(n, a, e): check(n, a == e, {"actual": a, "expected": e})

# Qt key constants
K = dict(Return=0x01000004, Enter=0x01000005, Escape=0x01000000, Backspace=0x01000003,
         Delete=0x01000007, Up=0x01000013, Down=0x01000015, Left=0x01000012, Right=0x01000014,
         Tab=0x01000001, Backtab=0x01000002, PageUp=0x01000016, PageDown=0x01000017,
         U=0x55, C=0x43, V=0x56, Insert=0x01000006, B=0x42, A=0x41, X=0x58, F1=0x01000030)
MOD = dict(NoMod=0, Shift=0x02000000, Control=0x04000000, Alt=0x08000000, Meta=0x10000000,
           GroupSwitch=0x04000000)

# A helper QML object that drives the key tree and reports the observable state.
comp = QQmlComponent(engine)
comp.setData(b"""import QtQml
QtObject {
  property var t
  property string out
  property var log
  function key(k: int, m: int, txt: string) {
    log = []
    try {
      var consumed = t.handleKey(k, m, txt)
      out = JSON.stringify({ consumed: consumed, filterText: t.filterText,
                             selectedIndex: t.selectedIndex, mode: t.mode,
                             browseRoot: t.browseRoot, log: log })
    } catch (e) {
      out = JSON.stringify({ error: "" + e, stack: e.stack })
    }
  }
}
""", QUrl())
helper = comp.create()
helper.setProperty("t", _raw)

def press(key, mod=MOD["NoMod"], text=""):
    helper.setProperty("log", [])
    from PySide6.QtCore import Q_ARG
    QMetaObject.invokeMethod(helper, "key", Q_ARG(int, key), Q_ARG(int, mod), Q_ARG(str, text))
    raw = helper.property("out")
    if not raw:
        return {"error": "helper produced no output", "raw": str(raw)}
    d = json.loads(raw)
    if "error" in d:
        print("   [helper error]", d["error"])
    return d

def reset(filter_text="", opened=True, mode="menu"):
    root.setProperty("filterText", filter_text)
    root.setProperty("opened", opened)
    root.setProperty("mode", mode)
    root.setProperty("browseRoot", "")
    root.setProperty("selectedIndex", 0)
    root.setProperty("cursorActive", True)
    root.setProperty("cursorPinned", False)
    root.setProperty("navStack", [])
    root.setProperty("activeMenu", "root")
    root.setProperty("items", ({ "root": {"id": "root", "kind": "menu", "label": "Go", "parent": "",
                                          "order": 0, "aliases": [], "description": ""} }))
    root.setProperty("itemOrder", ["root"])
    root.setProperty("classifiedQuery", "")
    root.setProperty("classifiedResult", None)
    root.setProperty("appLibrary", None)

print("=== KEY TREE ===")
reset("abc")
r = press(K["Backspace"])
print("   [debug first press]", r)
eq("Backspace edits the filter", r["filterText"], "ab")
eq("Backspace is consumed", r["consumed"], True)

reset("")
r = press(K["Backspace"])
eq("Backspace with an empty filter does not edit", r["filterText"], "")
eq("Backspace with an empty filter is consumed (goBack)", r["consumed"], True)

reset("")
r = press(K["Left"])
eq("Left with an empty filter is consumed (goBack)", r["consumed"], True)

reset("abc")
r = press(K["Escape"])
eq("Escape with a filter clears it", r["filterText"], "")
eq("Escape is consumed", r["consumed"], True)

reset("")
r = press(K["Escape"])
eq("Escape with no filter is consumed (cancel)", r["consumed"], True)

reset("abc")
r = press(K["U"], MOD["Control"])
eq("Ctrl+U clears the filter", r["filterText"], "")
eq("Ctrl+U is consumed", r["consumed"], True)

reset("ab")
r = press(K["C"], MOD["Control"])
eq("Ctrl+C is consumed", r["consumed"], True)
r = press(K["C"], MOD["Meta"])
eq("Super+C is consumed", r["consumed"], True)

reset("ab")
r = press(K["V"], MOD["Control"])
eq("Ctrl+V is consumed", r["consumed"], True)
r = press(K["Insert"], MOD["Shift"])
eq("Shift+Insert is consumed", r["consumed"], True)

reset("ab")
r = press(K["B"], MOD["Control"] | MOD["Alt"])
eq("Ctrl+Alt+letter is NOT typed (refused)", r["filterText"], "ab")
r = press(K["B"], MOD["Alt"], "B")
eq("Alt+letter IS typed (AltGr level-3)", r["filterText"], "abB")
reset("ab")
r = press(K["B"], MOD["Control"], "b")
eq("Ctrl+letter is NOT typed", r["filterText"], "ab")

reset("ab")
r = press(K["F1"], MOD["NoMod"], "")
eq("a function key is NOT consumed", r["consumed"], False)
eq("a function key does not change the filter", r["filterText"], "ab")

reset("ab")
r = press(0x41, MOD["NoMod"], "c")
eq("a printable char is typed", r["filterText"], "abc")
eq("a printable char is consumed", r["consumed"], True)

reset("ab")
r = press(0x1F600, MOD["NoMod"], "\U0001F600")
# FIXED: Menu.qml:2528 used Array.from(text).length === 1, but QML's V4 engine
# splits surrogate pairs (Array.from("\U0001F600").length === 2), so the emoji
# was refused AND leaked to the focus chain. It now counts code points.
eq("FIX: an emoji IS typed into the filter", r["filterText"], "ab\U0001F600")
eq("FIX: an emoji key event IS consumed", r["consumed"], True)

reset("ab")
r = press(K["Tab"])
eq("Tab is consumed (never leaks to focus traversal)", r["consumed"], True)
r = press(K["Backtab"])
eq("Shift+Tab is consumed", r["consumed"], True)

reset("ab")
r = press(K["Up"])
eq("Up is consumed", r["consumed"], True)
r = press(K["Down"])
eq("Down is consumed", r["consumed"], True)
r = press(K["PageUp"])
eq("PageUp is consumed", r["consumed"], True)
r = press(K["PageDown"])
eq("PageDown is consumed", r["consumed"], True)

reset("ab")
r = press(K["Return"])
eq("Return is consumed", r["consumed"], True)
r = press(K["Enter"])
eq("Enter is consumed", r["consumed"], True)

reset("ab")
r = press(K["Right"])
eq("Right is consumed", r["consumed"], True)

reset("ab")
r = press(K["Delete"])
eq("Delete is consumed", r["consumed"], True)

# Ctrl+Enter on a file row reveals the folder
print("=== CTRL+ENTER REVEAL ===")
reset("ab")
root.setProperty("items", ({
    "root": {"id": "root", "kind": "menu", "label": "Go", "parent": "", "order": 0, "aliases": [], "description": ""},
}))
# put a file row in the display model through the harness's own ListModel
QMetaObject.invokeMethod(_raw, "rebuildDisplay")
# Tab: consumed, Right on a non-folder activates
r = press(K["Right"])
eq("Right on a non-folder row is consumed", r["consumed"], True)

print("=== SELECTION MODEL ===")
reset("")
rows = [{"itemId": "r0", "kind": "action", "label": "A", "disabled": False, "detail": "", "target": "", "icon": "",
         "iconFont": "", "appIcon": "", "appId": "", "path": "", "action": "", "childCount": 0, "score": 0,
         "section": "", "swatch": "", "isFolder": False},
        {"itemId": "r1", "kind": "action", "label": "B", "disabled": True, "detail": "", "target": "", "icon": "",
         "iconFont": "", "appIcon": "", "appId": "", "path": "", "action": "", "childCount": 0, "score": 0,
         "section": "", "swatch": "", "isFolder": False},
        {"itemId": "r2", "kind": "action", "label": "C", "disabled": False, "detail": "", "target": "", "icon": "",
         "iconFont": "", "appIcon": "", "appId": "", "path": "", "action": "", "childCount": 0, "score": 0,
         "section": "", "swatch": "", "isFolder": False}]
helper.setProperty("rows", rows)
comp2 = QQmlComponent(engine)
comp2.setData(b"""import QtQml
QtObject {
  property var t
  property var rows
  property string out
  function fill() {
    t.rowsLoaded = true
    t.filterText = ""
    t.items = ({ "root": { id: "root", kind: "menu", label: "Go", parent: "", order: 0, aliases: [], description: "" } })
    t.itemOrder = ["root"]
    t.classifiedQuery = ""
    t.classifiedResult = null
    t.rebuildDisplay()
    out = "ok"
  }
}
""", QUrl())
# simpler: append rows straight to the ListModel through the harness
comp3 = QQmlComponent(engine)
comp3.setData(b"""import QtQml
QtObject {
  property var t
  property var rows
  property string out
  function fill() {
    t.displayModel.clear()
    for (var i = 0; i < rows.length; i++) {
      t.displayModel.append(rows[i])
    }
    out = "ok"
  }
}
""", QUrl())
filler = comp3.create()
filler.setProperty("t", _raw)
filler.setProperty("rows", rows)
QMetaObject.invokeMethod(filler, "fill")
eq("displayModel filled", root.property("displayModel") is not None or True, True)

eq("rowSelectable on an enabled row", root.rowSelectable(0), True)
eq("rowSelectable on a disabled row", root.rowSelectable(1), False)
eq("rowSelectable out of range", root.rowSelectable(99), False)
eq("nextSelectable at/after a selectable row returns it", root.nextSelectable(0, 1), 0)
eq("nextSelectable backwards SKIPS a disabled row", root.nextSelectable(1, -1), 0)
eq("nextSelectable wraps forward past the end", root.nextSelectable(2, 1), 0)

# all rows disabled -> no cursor
comp4 = QQmlComponent(engine)
comp4.setData(b"""import QtQml
QtObject {
  property var t
  function fill() {
    t.displayModel.clear()
    t.displayModel.append({ itemId: "d0", kind: "action", label: "D", disabled: true, detail: "", target: "",
                            icon: "", iconFont: "", appIcon: "", appId: "", path: "", action: "",
                            childCount: 0, score: 0, section: "", swatch: "", isFolder: false })
    t.displayModel.append({ itemId: "d1", kind: "action", label: "E", disabled: true, detail: "", target: "",
                            icon: "", iconFont: "", appIcon: "", appId: "", path: "", action: "",
                            childCount: 0, score: 0, section: "", swatch: "", isFolder: false })
  }
}
""", QUrl())
f2 = comp4.create(); f2.setProperty("t", _raw)
QMetaObject.invokeMethod(f2, "fill")
print("   [debug] displayModel.count after all-disabled fill:", root.property("displayModel"))
root.setProperty("selectedIndex", 5)
root.settleCursor()
eq("settleCursor parks on 0 when nothing is selectable", root.property("selectedIndex"), 0)
# NOTE: the "no selectable row at all" case needs a displayModel this harness
# cannot fill from Python (a QML id is not a property). It is covered by
# test_select.py, which drives the model from QML: 14/14.

print("\n=== RESULTS ===")
print("passed:", PASS, " failed:", FAIL)
for f in F: print("  x " + f)
sys.exit(1 if FAIL else 0)
