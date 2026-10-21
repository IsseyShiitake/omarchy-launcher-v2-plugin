#!/usr/bin/env python3
"""Focused check: the selection model (nextSelectable / settleCursor)."""
import sys, os, json
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
from PySide6.QtCore import QUrl, QCoreApplication, QMetaObject, Q_ARG
from PySide6.QtQml import QQmlApplicationEngine, QJSValue, QQmlComponent

app = QCoreApplication(sys.argv)
engine = QQmlApplicationEngine()
import harness
QML_DIR = harness.build()
engine.addImportPath(QML_DIR)
engine.load(QUrl.fromLocalFile(os.path.join(QML_DIR, "Harness.qml")))
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

comp = QQmlComponent(engine)
comp.setData(b"""import QtQml
QtObject {
  property var t
  property string out
  function fill() {
   try {
    t.displayModelRef.clear()
    var mk = function(id, label, dis) {
      return { itemId: id, kind: "action", label: label, disabled: dis, detail: "", target: "",
               icon: "", iconFont: "", appIcon: "", appId: "", path: "", action: "", childCount: 0,
               score: 0, section: "", swatch: "", isFolder: false }
    }
    t.displayModelRef.append(mk("r0", "A", false))
    t.displayModelRef.append(mk("r1", "B", true))
    t.displayModelRef.append(mk("r2", "C", false))
    out = JSON.stringify({
      count: t.displayModelRef.count,
      sel0: t.rowSelectable(0), sel1: t.rowSelectable(1), sel2: t.rowSelectable(2),
      next0: t.nextSelectable(0, 1),
      next1: t.nextSelectable(1, 1),
      next1back: t.nextSelectable(1, -1),
      next2fwd: t.nextSelectable(2, 1),
      next0back: t.nextSelectable(0, -1),
      selOutOfRange: t.rowSelectable(99)
    })
   } catch (e) { out = JSON.stringify({ error: "" + e, stack: e.stack }) }
  }
  function allDisabled() {
    t.displayModelRef.clear()
    var mk = function(id, dis) {
      return { itemId: id, kind: "action", label: id, disabled: dis, detail: "", target: "",
               icon: "", iconFont: "", appIcon: "", appId: "", path: "", action: "", childCount: 0,
               score: 0, section: "", swatch: "", isFolder: false }
    }
    t.displayModelRef.append(mk("d0", true))
    t.displayModelRef.append(mk("d1", true))
    t.selectedIndex = 5
    t.settleCursor()
    out = JSON.stringify({ count: t.displayModelRef.count, next: t.nextSelectable(0, 1),
                            selectedIndex: t.selectedIndex, cursorActive: t.cursorActive })
  }
  function empty() {
    t.displayModelRef.clear()
    out = JSON.stringify({ count: t.displayModelRef.count, next: t.nextSelectable(0, 1) })
  }
}
""", QUrl())
h = comp.create()
h.setProperty("t", raw)

PASS = FAIL = 0
def check(n, c, d=None):
    global PASS, FAIL
    if c: PASS += 1
    else:
        FAIL += 1
        print("  x %s  %s" % (n, json.dumps(d, default=str) if d is not None else ""))

QMetaObject.invokeMethod(h, "fill")
r = json.loads(h.property("out"))
print("=== SELECTION MODEL ===")
print("  ", json.dumps(r))
check("model holds 3 rows", r["count"] == 3, r)
check("rowSelectable(0) enabled", r["sel0"] is True, r)
check("rowSelectable(1) disabled", r["sel1"] is False, r)
check("rowSelectable(2) enabled", r["sel2"] is True, r)
check("rowSelectable out of range is false", r["selOutOfRange"] is False, r)
check("nextSelectable(0,+1) -> 0 (row 0 selectable)", r["next0"] == 0, r)
check("nextSelectable(1,+1) SKIPS the disabled row -> 2", r["next1"] == 2, r)
check("nextSelectable(1,-1) SKIPS the disabled row -> 0", r["next1back"] == 0, r)
check("nextSelectable(2,+1) returns the selectable row AT 2", r["next2fwd"] == 2, r)
check("nextSelectable(0,-1) returns the selectable row AT 0", r["next0back"] == 0, r)

QMetaObject.invokeMethod(h, "allDisabled")
r = json.loads(h.property("out"))
print("  all-disabled:", json.dumps(r))
check("nextSelectable -> -1 when every row is disabled", r["next"] == -1, r)
check("settleCursor parks on index 0", r["selectedIndex"] == 0, r)
check("settleCursor leaves the cursor INACTIVE", r["cursorActive"] is False, r)

QMetaObject.invokeMethod(h, "empty")
r = json.loads(h.property("out"))
print("  empty:", json.dumps(r))
check("nextSelectable -> -1 on an empty model", r["next"] == -1, r)

print("\npassed:", PASS, " failed:", FAIL)
sys.exit(1 if FAIL else 0)
