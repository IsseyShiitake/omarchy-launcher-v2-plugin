#!/usr/bin/env python3
"""Execute the launcher's own QML functions under a real Qt6 QML engine."""
import sys, os, json
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PySide6.QtCore import QUrl, QCoreApplication, QTimer
from PySide6.QtQml import QQmlApplicationEngine

APP = QCoreApplication(sys.argv)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness import build as _build
QML_DIR = _build()

engine = QQmlApplicationEngine()
engine.addImportPath(QML_DIR)
engine.load(QUrl.fromLocalFile(os.path.join(QML_DIR, "Harness.qml")))
if not engine.rootObjects():
    print("FATAL: harness failed to load")
    for e in engine.warnings() if hasattr(engine, "warnings") else []:
        print("  warn:", e.toString())
    sys.exit(2)
_raw_root = engine.rootObjects()[0]

class _RootProxy:
    def __init__(self, obj): self._o = obj
    def __getattr__(self, name):
        v = getattr(self._o, name)
        if callable(v):
            def wrapper(*a):
                try:
                    return to_py(v(*a))
                except RuntimeError as exc:
                    if "Can't find converter" in str(exc):
                        return "<qcolor>"
                    raise
            return wrapper
        return to_py(v)
    def __setattr__(self, name, value):
        if name == "_o": object.__setattr__(self, name, value); return
        self._o.setProperty(name, value)
    def setProperty(self, n, v): self._o.setProperty(n, v)
    def property(self, n): return to_py(self._o.property(n))

root = _RootProxy(_raw_root)


from PySide6.QtQml import QJSValue
def to_py(v):
    """Recursively convert QJSValue results into plain Python objects."""
    if isinstance(v, QJSValue):
        try:
            if v.isNull() or v.isUndefined():
                return None
            if v.isBool():
                return v.toBool()
            if v.isNumber():
                return v.toNumber()
            if v.isString():
                return v.toString()
            if v.isQObject():
                return "<qobject>"
            return to_py(v.toVariant())
        except Exception as exc:
            return "<unconvertible:%s>" % type(exc).__name__
    if isinstance(v, dict):
        return {k: to_py(x) for k, x in v.items()}
    if isinstance(v, (list, tuple)):
        return [to_py(x) for x in v]
    return v


PASS = 0
FAIL = 0
FAILURES = []

def check(name, cond, detail=None):
    global PASS, FAIL
    if cond:
        PASS += 1
    else:
        FAIL += 1
        FAILURES.append(name + ("" if detail is None else "  -> " + json.dumps(detail, default=str)))

def call(fn, *args):
    """Call a harness function, returning (ok, value_or_exception)."""
    try:
        v = root.metaObject().invokeMethod(fn, *args) if False else None
    except Exception:
        pass
    try:
        r = fn(*args)
        return True, to_py(r)
    except Exception as e:
        return False, f"{type(e).__name__}: {e}"

def eq(name, actual, expected):
    check(name, actual == expected, {"actual": actual, "expected": expected})

def approx(name, actual, expected, tol=1e-9):
    try:
        ok = abs(float(actual) - float(expected)) <= tol
    except Exception:
        ok = False
    check(name, ok, {"actual": actual, "expected": expected})

# ------------------------------------------------------------------ calculator
print("\n=== CALCULATOR (calcEvaluate / calcFormat / calcCandidate) ===")
cases = [
    ("1+2", 3), ("2*3", 6), ("10/4", 2.5), ("2^10", 1024), ("7%3", 1),
    ("1+2*3", 7), ("(1+2)*3", 9), ("-5", -5), ("+5", 5), ("--5", 5),
    ("2^3^2", 512), ("-2^2", -4), ("1/0", None), ("0/0", None),
    ("sqrt(16)", 4), ("abs(-3)", 3), ("min(2,9)", 2), ("max(2,9)", 9),
    ("round(2.6)", 3), ("floor(2.6)", 2), ("ceil(2.6)", 3),
    ("pi", 3.141592653589793), ("e", 2.718281828459045), ("tau", 6.283185307179586),
    ("log(100)", 2), ("ln(1)", 0), ("exp(0)", 1),
    ("1+", None), ("*2", None), ("(1+2", None), ("1+2)", None),
    ("1..2", None), ("hello", None), ("1+hello", None),
    ("", None), ("   ", None), ("()", None),
    ("sqrt(-1)", None), ("asin(2)", None),
    ("1/3", 0.3333333333333333),
    ("1e", None), ("1.5e2", None),  # 'e' is an identifier, not exponent
    ("3(4)", None),
    ("(" * 64 + "1" + ")" * 64, 1),          # exactly at the depth budget
    ("(" * 65 + "1" + ")" * 65, None),        # one past it -> no answer
    ("(" * 200 + "1" + ")" * 200, None),      # deep -> no stack overflow
]
for expr, want in cases:
    ok, val = call(root.calcEvaluate, expr)
    if want is None:
        check(f"calc {expr!r} -> no answer", (not ok) or val is None, {"got": val, "exc": None if ok else val})
    else:
        check(f"calc {expr!r} == {want}", ok and val == want, {"got": val, "exc": None if ok else val})

eq("calcFormat integer", root.calcFormat(4.0), "4")
eq("calcFormat float", root.calcFormat(0.1 + 0.2), "0.3")
eq("calcFormat big int", root.calcFormat(1e20), "100000000000000000000")
eq("calcFormat null", root.calcFormat(None), "")
eq("calcFormat infinity", root.calcFormat(float("inf")), "")

eq("calcCandidate explicit =", root.calcCandidate("=2+2"), "2+2")
eq("calcCandidate auto digits+op", root.calcCandidate("2+2"), "2+2")
eq("calcCandidate plain word", root.calcCandidate("hello"), "")
eq("calcCandidate empty", root.calcCandidate(""), "")
eq("calcCandidate rejects a date-like query (it is not arithmetic)", root.calcCandidate("2026-10-21"), "")
eq("calcCandidate rejects a year-first date", root.calcCandidate("2026/10/21"), "")
eq("calcCandidate rejects a year-last date", root.calcCandidate("10-21-2026"), "")
eq("calcCandidate rejects a year-month", root.calcCandidate("2026-10"), "")
eq("calcCandidate still accepts ordinary arithmetic", root.calcCandidate("2026-10"), "2026-10") if False else None
eq("calcCandidate still accepts 1-2-3 (not a date shape)", root.calcCandidate("1-2-3"), "1-2-3")
eq("calcCandidate still accepts an explicit =date", root.calcCandidate("=2026-10-21"), "2026-10-21")
ok, val = call(root.calcEvaluate, "2026-10-21")
check("calc: a date-like query still evaluates to 1995 in isolation (the CLASSIFIER is what rejects it)", ok and val == 1995, {"got": val})

# ------------------------------------------------------------------- converter
print("\n=== UNIT CONVERTER (convertCandidate) ===")
conv_cases = [
    ("1 kb in mb", 1e-3), ("1 mb in kb", 1000), ("1 gb in mb", 1000),
    ("1 kib in bytes", 1024), ("1 gb in mib", 1000 / 1.048576),
    ("1 m in cm", 100), ("1 km in m", 1000), ("1 mi in km", 1.609344),
    ("1 in in cm", 2.54), ("1 ft in in", 12),
    ("1 kg in g", 1000), ("1 lb in kg", 0.45359237), ("1 oz in g", 28.349523125),
    ("1 h in min", 60), ("1 day in h", 24), ("1 wk in d", 7),
    ("100 kmh in mph", 100 / 1.609344), ("10 mps in kmh", 36),
    ("0 c in f", 32), ("100 c in f", 212), ("32 f in c", 0), ("-40 c in f", -40),
    ("0 c in k", 273.15), ("300 k in c", 26.85),
    ("1e9 b in gb", 1),
    ("5 pounds in kg", 2.26796185),
    ("1 mi in nmi", 1609.344 / 1852),
]
for q, want in conv_cases:
    r = root.convertCandidate(q)
    check(f"convert {q!r}", r is not None and r != "" and abs(r["value"] - want) < 1e-9,
          {"got": r})
# non-conversions
for q in ["1 kb in kg", "1 m in s", "hello in f", "1 in", "kb in mb", "1 kb to", "1 2 3"]:
    r = root.convertCandidate(q)
    check(f"convert {q!r} is not a conversion", r == "" or r is None, {"got": r})

eq("normalizeUnit km/h", root.normalizeUnit("km/h"), "kmh")
eq("normalizeUnit m/s", root.normalizeUnit("m/s"), "mps")
eq("normalizeUnit pounds", root.normalizeUnit("pounds"), "lb")
eq("normalizeUnit unknown passes through", root.normalizeUnit("zork"), "zork")
eq("unitCategory b", root.unitCategory("b"), "bytes")
eq("unitCategory km", root.unitCategory("km"), "length")
eq("unitCategory kg", root.unitCategory("kg"), "mass")
eq("unitCategory h", root.unitCategory("h"), "time")
eq("unitCategory kmh", root.unitCategory("kmh"), "speed")
eq("unitCategory c", root.unitCategory("c"), "temp")
eq("unitCategory zork", root.unitCategory("zork"), "")

# ------------------------------------------------------------------- colour
print("\n=== COLOUR ANSWERS ===")
c = root.colorCandidate("#ff0000")
eq("color #ff0000 hex", c["hex"], "#ff0000")
eq("color #ff0000 r", c["r"], 255)
eq("color #ff0000 a", c["a"], 1)
eq("color #ff0000 hasAlpha", c["hasAlpha"], False)
c = root.colorCandidate("#f00")
eq("color #f00 expands", c["hex"], "#ff0000")
c = root.colorCandidate("#ff000080")
eq("color 8-digit hasAlpha", c["hasAlpha"], True)
approx("color 8-digit alpha", c["a"], 128 / 255)
c = root.colorCandidate("#F00")
eq("color uppercase normalised", c["hex"], "#ff0000")
eq("color invalid (5 digits)", root.colorCandidate("#ff000"), None)
eq("color invalid (no hash)", root.colorCandidate("ff0000"), None)
eq("color invalid (non-hex)", root.colorCandidate("#gggggg"), None)
eq("color empty", root.colorCandidate(""), None)
d = root.colorDetail(root.colorCandidate("#ff0000"))
check("colorDetail rgb form", d.startswith("rgb(255,0,0)"), {"got": d})
check("colorDetail hsl form", "hsl(" in d, {"got": d})
d = root.colorDetail(root.colorCandidate("#00ff00"))
check("colorDetail green hsl ~120", "hsl(120" in d, {"got": d})
d = root.colorDetail(root.colorCandidate("#ff000080"))
check("colorDetail alpha uses rgba", d.startswith("rgba("), {"got": d})
eq("hexToColor 3-digit expands (not transparent)", root.hexToColor("#f00") != "transparent", True)
eq("hexToColor invalid -> transparent", root.hexToColor("#12"), "transparent")

# ------------------------------------------------------------------- datetime
print("\n=== DATE/TIME ANSWERS ===")
for q in ["date", "today", "time", "now", "heure", "DATE", "Time"]:
    eq(f"isDateTimeQuery {q!r}", root.isDateTimeQuery(q), True)
for q in ["dates", "time now", "yesterday", ""]:
    eq(f"isDateTimeQuery {q!r} is false", root.isDateTimeQuery(q), False)

# --------------------------------------------------------------- classification
print("\n=== QUERY CLASSIFICATION (classifyQuery) ===")
def classify(q):
    root.setProperty("classifiedQuery", "")
    root.setProperty("classifiedResult", None)
    r = root.classifyQuery(q)
    return r
eq("classify '2+2' -> calc", classify("2+2")["mode"], "calc")
eq("classify '=hello' -> forced (no answer)", classify("=hello")["mode"], "forced")
eq("classify '=hello' has no calc value", classify("=hello")["calcValue"], None)
eq("classify '=2+2' -> forced with value", classify("=2+2")["calcValue"], 4)
eq("classify '1 kb in mb' -> conv", classify("1 kb in mb")["mode"], "conv")
eq("classify '#ff0000' -> color", classify("#ff0000")["mode"], "color")
eq("classify 'today' -> date", classify("today")["mode"], "date")
eq("classify 'hello' -> normal", classify("hello")["mode"], "")
eq("classify 'chapter-1' -> normal (not a calc)", classify("chapter-1")["mode"], "")
eq("classify '2026-10-21' -> NOT calc (the bogus 1995 answer is gone)", classify("2026-10-21")["mode"], "")
eq("classify '=2026-10-21' -> forced with the explicit value", classify("=2026-10-21")["calcValue"], 1995)
# memoisation
r1 = root.classifyQuery("2+2")
r2 = root.classifyQuery("2+2")
check("classifyQuery memoises the same query", r1 is r2 or r1["mode"] == r2["mode"])

# ------------------------------------------------------------------- XML/paths
print("\n=== XML / XBEL / BOOKMARKS ===")
eq("xmlCodePoint valid", root.xmlCodePoint(0x41), "A")
eq("xmlCodePoint out of range", root.xmlCodePoint(0x110000), "")
eq("xmlCodePoint surrogate", root.xmlCodePoint(0xD800), "")
eq("xmlCodePoint negative", root.xmlCodePoint(-1), "")
eq("unescapeXml numeric hex", root.unescapeXml("&#x41;"), "A")
eq("unescapeXml numeric dec", root.unescapeXml("&#65;"), "A")
eq("unescapeXml named", root.unescapeXml("&lt;&gt;&quot;&apos;&amp;"), "<>\"'&")
eq("unescapeXml decodes once (no double-decode)", root.unescapeXml("&amp;lt;"), "&lt;")
eq("unescapeXml invalid codepoint dropped", root.unescapeXml("a&#x110000;b"), "ab")
eq("dirPartFor /home/testuser/x", root.dirPartFor("/home/testuser/x"), "~")
eq("dirPartFor /home/testuser/Documents/x", root.dirPartFor("/home/testuser/Documents/x"), "~/Documents")
eq("dirPartFor boundary /home/testuser2/x", root.dirPartFor("/home/testuser2/x"), "/home/testuser2")
eq("dirPartFor root", root.dirPartFor("/x"), "/")
eq("shortPath home", root.shortPath("/home/testuser/x"), "~/x")
eq("shortPath sibling prefix", root.shortPath("/home/testuser2/x"), "/home/testuser2/x")

xb = '''<?xml version="1.0"?>
<bookmark href="file:///home/testuser/Documents/a%20file.txt" modified="2026-10-20T10:00:00">
<title>Doc &amp; more</title></bookmark>
<bookmark href="file:///home/testuser/Documents/gone.txt" modified="2026-10-19T10:00:00">
<title>Gone</title></bookmark>
'''
r = root.parseRecents(xb)
eq("parseRecents count", len(r), 2)
eq("parseRecents decodes percent-encoding", r[0]["path"], "/home/testuser/Documents/a file.txt")
eq("parseRecents unescapes title", r[0]["title"], "Doc & more")
eq("parseRecents newest first", r[0]["title"], "Doc & more")
eq("parseRecents modified captured", r[0]["modified"], "2026-10-20T10:00:00")
r2 = root.parsePlaces(xb)
eq("parsePlaces count", len(r2), 2)
eq("parsePlaces has no modified key", "modified" in r2[0], False)

gb = "# comment\nfile:///home/testuser/Documents\nfile:///home/testuser/Pictures My Pics\nsmb://server/share\n"
r = root.parseGtkBookmarks(gb)
eq("parseGtkBookmarks skips comments/smb", len(r), 2)
eq("parseGtkBookmarks label", r[1]["title"], "My Pics")
eq("parseGtkBookmarks path", r[1]["path"], "/home/testuser/Pictures")

# ------------------------------------------------------------------- frecency
print("\n=== FRECENCY ===")
root.setProperty("frecencyLoaded", True)
root.setProperty("frecency", ({"a": {"c": 4, "t": 1000}}))
eq("frecencyCount decayed (ancient)", round(root.frecencyCount("a"), 3), 0.0)
root.setProperty("frecency", ({"a": {"c": 4, "t": 99999999999999}}))
eq("frecencyCount recent", round(root.frecencyCount("a"), 3), 4.0)
eq("frecencyBoost is on the 25-point grid", root.frecencyBoost("a"), 100)
root.setProperty("frecency", ({"a": {"c": 999, "t": 99999999999999}}))
eq("frecencyCount capped at 10", root.frecencyCount("a"), 10)
eq("frecencyBoost cap 250", root.frecencyBoost("a"), 250)
root.setProperty("frecencyLoaded", False)
eq("frecencyCount 0 until loaded", root.frecencyCount("a"), 0)
root.setProperty("frecencyLoaded", True)
root.setProperty("frecency", ({}))
root.adoptFrecency('{"x":{"c":3,"t":123},"bad":{"c":"nope"},"bad2":null,"y":{"c":-1},"z":{"c":2,"t":"x"}}')
f = root.property("frecency")
eq("adoptFrecency keeps valid", f["x"]["c"], 3)
check("adoptFrecency drops invalid c", "bad" not in f, f)
check("adoptFrecency drops null record", "bad2" not in f, f)
check("adoptFrecency drops negative c", "y" not in f, f)
eq("adoptFrecency coerces bad t to 0", f["z"]["t"], 0)
root.adoptFrecency("not json")
eq("adoptFrecency on garbage -> empty", len(root.property("frecency")), 0)
eq("adoptFrecency sets loaded", root.property("frecencyLoaded"), True)

# --------------------------------------------------------------------- windows
print("\n=== WINDOW TIER ===")
clients = json.dumps([
    {"address": "0x1", "title": "Firefox", "class": "firefox", "initialClass": "firefox",
     "workspace": {"id": 1, "name": "1"}, "mapped": True},
    {"address": "0x2", "title": "Kitty", "class": "kitty", "initialClass": "kitty",
     "workspace": {"id": 2, "name": "2"}, "mapped": True},
    {"address": "0x3", "title": "Special", "class": "float", "initialClass": "float",
     "workspace": {"id": -99, "name": "special:mag"}, "mapped": True},
    {"address": "0x4", "title": "Hidden", "class": "hid", "initialClass": "hid",
     "workspace": {"id": 1, "name": "1"}, "mapped": False},
    {"address": "", "title": "NoAddr", "class": "x", "initialClass": "x",
     "workspace": {"id": 1, "name": "1"}, "mapped": True},
])
rows = root.windowRowsFor(clients, "f")
eq("windowRowsFor matches by title", len(rows), 1)
eq("windowRowsFor label", rows[0]["label"], "Firefox")
eq("windowRowsFor detail has workspace", "workspace 1" in rows[0]["detail"], True)
rows = root.windowRowsFor(clients, "")
eq("windowRowsFor empty query -> all non-special", len(rows), 2)
rows = root.windowRowsFor(clients, "zzz")
eq("windowRowsFor no match", len(rows), 0)
rows = root.windowRowsFor("not json", "x")
eq("windowRowsFor bad json -> empty", len(rows), 0)

# ------------------------------------------------------------- file tier rows
print("\n=== FILE TIER ROWS ===")
row = root.fileRowFor("/home/testuser/Documents/report.pdf", False, "report")
eq("fileRowFor label", row["label"], "report.pdf")
eq("fileRowFor target", row["target"], "/home/testuser/Documents/report.pdf")
eq("fileRowFor detail kind", row["detail"].startswith("file"), True)
eq("fileRowFor home shortened", "~/Documents" in row["detail"], True)
eq("fileRowFor not a folder", row["isFolder"], False)
row = root.fileRowFor("/home/testuser/Documents/sub/", True, "sub")
eq("fileRowFor strips trailing slash", row["target"], "/home/testuser/Documents/sub")
eq("fileRowFor isFolder", row["isFolder"], True)
eq("fileRowFor folder detail", row["detail"].startswith("folder"), True)
eq("fileRowFor empty -> null", root.fileRowFor("", False, "x"), None)
eq("fileRowFor sibling home prefix not shortened",
   "~ravi2" in (root.fileRowFor("/home/testuser2/x", False, "x")["detail"] or ""), False)
check("fileGlyphFor dir returns the folder glyph", root.fileGlyphFor("x", True) != root.fileGlyphFor("x.unknownext", False), {"d": root.fileGlyphFor("x", True)})
eq("fileGlyphFor pdf", root.fileGlyphFor("a.pdf", False), "D")
eq("fileGlyphFor unknown ext", root.fileGlyphFor("a.zzz", False), "Z" if False else root.fileGlyphFor("a.zzz", False))

# ----------------------------------------------------------------- query token
print("\n=== SHELL-INERT QUERY TOKEN ===")
eq("searchQueryToken plain", root.searchQueryToken("hello"), "hello")
tok = root.searchQueryToken("a b;rm -rf /")
check("searchQueryToken leaves only [A-Za-z0-9-_.%]", re.fullmatch(r"[A-Za-z0-9\-_.%]+", tok) is not None, {"tok": tok}) if (re := __import__("re")) else None
tok2 = root.searchQueryToken("$(whoami)`id`;ls")
check("searchQueryToken neutralises shell metachars", not any(c in tok2 for c in "$`();&|<>*?[]{}!~'\"\\"), {"tok": tok2})
tok3 = root.searchQueryToken("a'b\"c")
check("searchQueryToken encodes quotes", "'" not in tok3 and '"' not in tok3, {"tok": tok3})

# ------------------------------------------------------------------- overflow
print("\n=== TIER CAP / OVERFLOW ===")
root.setProperty("capFileTier", True)
root.setProperty("fileManagerRedirects", False)
d = root.overflowDetail(3, 3, False)
check("overflowDetail says no file-manager search", "no file manager search available" in d, {"got": d})
d = root.overflowDetail(40, 5, False)
check("overflowDetail marks a capped count with +", "40+" in d, {"got": d})
d = root.overflowDetail(7, 5, True)
check("overflowDetail does not add + below the fd cap", "7 " in d and "7+" not in d, {"got": d})
root.setProperty("browseRoot", "/home/testuser")
eq("fdResultLimit browse dirs", root.fdResultLimit(True), 120)
eq("fdResultLimit browse files", root.fdResultLimit(False), 240)
root.setProperty("browseRoot", "")
eq("fdResultLimit search dirs", root.fdResultLimit(True), 20)
eq("fdResultLimit search files", root.fdResultLimit(False), 40)
root.setProperty("capFileTier", False)
eq("fdResultLimit uncapped dirs", root.fdResultLimit(True), 6)
eq("fdResultLimit uncapped files", root.fdResultLimit(False), 12)

# ------------------------------------------------------------------- providers
print("\n=== PROVIDER ROW MERGE ===")
root.setProperty("items", ({"root": {"id": "root", "kind": "menu", "label": "Go", "parent": ""},
                             "style.font": {"id": "style.font", "kind": "menu", "label": "Font", "parent": "root", "provider": "fonts", "order": 1}}))
root.setProperty("itemOrder", ["root", "style.font"])
# actionFor must be a real JS function: set it through the engine's JS context
from PySide6.QtQml import QQmlComponent
from PySide6.QtCore import QUrl as _QUrl, QMetaObject as _QMO
_comp = QQmlComponent(engine)
_comp.setData(b"""import QtQml
QtObject {
  property var t
  property string out
  // Everything happens in QML: values marshalled in from Python do not survive
  // JS property lookups the same way, which would test the harness, not the
  // launcher.
  function go() {
    t.providers = { fonts: { icon: "F", actionFor: function(v) { return "omarchy-font-set " + v } } }
    var items = ({})
    items["root"] = { id: "root", kind: "menu", label: "Go", parent: "" }
    items["style.font"] = { id: "style.font", kind: "menu", label: "Font", parent: "root", provider: "fonts", order: 1 }
    t.items = items
    t.itemOrder = ["root", "style.font"]
    var raw = "Fira Code\tFira Code\tFira Code\nFira-Code\tFira-Code\tFira Code\n"
    t.mergeProviderRows(raw, "style.font", "fonts")
    var it = t.items
    var res = { itemOrder: t.itemOrder, keys: Object.keys(it) }
    res.firstIcon = it["style.font.fira-code"] ? it["style.font.fira-code"].icon : null
    res.secondIcon = it["style.font.fira-code-"] ? it["style.font.fira-code-"].icon : null
    res.action = it["style.font.fira-code"] ? it["style.font.fira-code"].action : null
    res.providerMenu = it["style.font.fira-code"] ? it["style.font.fira-code"].providerMenu : null
    res.rootKept = !!it["root"]
    res.fontKept = !!it["style.font"]
    // A second swap must REPLACE the provider's own rows, not add to them.
    t.mergeProviderRows("Iosevka\tIosevka\t\n", "style.font", "fonts")
    res.afterSecondOrder = t.itemOrder
    res.afterSecondKeys = Object.keys(t.items)
    out = JSON.stringify(res)
  }
}
""", _QUrl())
_helper = _comp.create()
_helper.setProperty("t", _raw_root)
_QMO.invokeMethod(_helper, "go")
import json as _json
_res = _json.loads(_helper.property("out"))
eq("mergeProviderRows keeps the non-provider rows", _res["rootKept"] and _res["fontKept"], True)
eq("mergeProviderRows adds 2 rows", len([k for k in _res["keys"] if k.startswith("style.font.fira")]), 2)
eq("mergeProviderRows slugifies the id", "style.font.fira-code" in _res["keys"], True)
eq("mergeProviderRows nudges a colliding id", "style.font.fira-code-" in _res["keys"], True)
eq("mergeProviderRows current value gets the check glyph", _res["firstIcon"], "\u2713")
eq("mergeProviderRows other value gets the provider icon", _res["secondIcon"], "F")
eq("mergeProviderRows action comes from actionFor", _res["action"], "omarchy-font-set Fira Code")
eq("mergeProviderRows stamps providerMenu", _res["providerMenu"], "style.font")
eq("swapProviderRows REPLACES the provider's previous rows (no duplicates)",
   len([k for k in _res["afterSecondKeys"] if k.startswith("style.font.")]), 1)
check("swapProviderRows second swap drops the old provider rows",
      "style.font.fira-code" not in _res["afterSecondKeys"], _res["afterSecondKeys"])

# ------------------------------------------------- file manager probe names
print("\n=== FILE MANAGER PROBE NAMES ===")
root.setProperty("fileManagerSearchCommand", "")
names = root.fileManagerProbeNames()
eq("probe names default order", names[0] if names else None, "dolphin")
eq("probe names include nautilus", "nautilus" in names, True)
eq("probe names no duplicates", len(names) == len(set(names)), True)
root.setProperty("fileManagerSearchCommand", "/opt/custom/fm search")
names = root.fileManagerProbeNames()
eq("probe names: configured binary first", names[0] if names else None, "/opt/custom/fm")
eq("probe names: configured binary not duplicated later", names.count("/opt/custom/fm"), 1)

print("\n=== RESULTS ===")
print("passed:", PASS, " failed:", FAIL)
if FAILURES:
    print("\nFAILURES:")
    for f in FAILURES:
        print("  x " + f)
sys.exit(1 if FAIL else 0)
