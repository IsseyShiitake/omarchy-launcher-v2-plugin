#!/usr/bin/env python3
"""Build a QML harness from the launcher's Menu.qml.

The harness is the launcher's own top-level functions, verbatim, plus stubs for
the shell objects they touch, so the functions can be executed by a real Qt6
QML engine without the Omarchy shell. Usage:

    extract.py <path/to/Menu.qml> <output-dir>

`tests/qml/harness.py` calls this; you normally do not.
"""
import json
import os
import re
import sys

if len(sys.argv) != 3:
    sys.exit("usage: extract.py <Menu.qml> <output-dir>")

SRC = os.path.abspath(sys.argv[1])
OUT = os.path.abspath(sys.argv[2])
if not os.path.isfile(SRC):
    sys.exit("no such source file: " + SRC)


src = open(SRC, encoding="utf-8").read()
lines = src.split("\n")

# Find top-level function definitions: "  function NAME(" at exactly 2-space indent.
funcs = []
i = 0
while i < len(lines):
    m = re.match(r"^  function ([A-Za-z_$][\w$]*)\s*\(", lines[i])
    if m:
        name = m.group(1)
        # collect the full signature + body by brace matching from this line
        start = i
        depth = 0
        started = False
        body = []
        j = i
        while j < len(lines):
            body.append(lines[j])
            for ch in lines[j]:
                if ch == "{":
                    depth += 1; started = True
                elif ch == "}":
                    depth -= 1
            if started and depth == 0:
                break
            j += 1
        funcs.append((name, start + 1, j + 1, "\n".join(body)))
        i = j + 1
    else:
        i += 1

print(f"extracted {len(funcs)} top-level functions", file=sys.stderr)
for n, a, b, _ in funcs:
    print(f"  {n}  (lines {a}-{b})", file=sys.stderr)

# Property stubs the functions read. Values that matter for the tests are set
# from Python; the rest just need to exist so the JS does not throw.
PROPS = """
  property string filterText: ""
  property bool dmenuActive: false
  property string browseRoot: ""
  property string mode: "menu"
  property var items: ({})
  property var itemOrder: []
  property var whenResults: ({})
  property var checkedResults: ({})
  property var disabledResults: ({})
  property var frecency: ({})
  property bool frecencyLoaded: false
  property double frecencyHalfLifeMs: 30 * 24 * 60 * 60 * 1000
  property string classifiedQuery: ""
  property var classifiedResult: null
  property bool colorAnswers: true
  property var unitTables: ({
    bytes: { b: 1, kb: 1e3, mb: 1e6, gb: 1e9, tb: 1e12,
             kib: 1024, mib: 1048576, gib: 1073741824, tib: 1099511627776 },
    length: { mm: 0.001, cm: 0.01, m: 1, km: 1000, in: 0.0254, ft: 0.3048,
              yd: 0.9144, mi: 1609.344, nmi: 1852 },
    mass: { mg: 1e-6, g: 0.001, kg: 1, t: 1000,
            oz: 0.028349523125, lb: 0.45359237, st: 6.35029318 },
    time: { ms: 0.001, s: 1, min: 60, h: 3600, d: 86400, wk: 604800 },
    speed: { kmh: 1, mph: 1.609344, mps: 3.6, kn: 1.852 },
    temp: { c: 1, f: 1, k: 1 }
  })
  property var unitAliases: ({
    pounds: "lb", lbs: "lb", ounce: "oz", ounces: "oz",
    gram: "g", grams: "g", kilogram: "kg", kilograms: "kg",
    kilometer: "km", kilometers: "km", kilometre: "km", kilometres: "km",
    meter: "m", meters: "m", metre: "m", metres: "m",
    centimeter: "cm", centimeters: "cm", centimetre: "cm", centimetres: "cm",
    millimeter: "mm", millimeters: "mm", millimetre: "mm", millimetres: "mm",
    mile: "mi", miles: "mi", foot: "ft", feet: "ft", inch: "in", inches: "in",
    yard: "yd", yards: "yd", hour: "h", hours: "h", minute: "min", minutes: "min",
    second: "s", seconds: "s", day: "d", days: "d", week: "wk", weeks: "wk",
    byte: "b", bytes: "b", kilobyte: "kb", kilobytes: "kb",
    megabyte: "mb", megabytes: "mb", gigabyte: "gb", gigabytes: "gb",
    terabyte: "tb", terabytes: "tb",
    millisecond: "ms", milliseconds: "ms", milligram: "mg", milligrams: "mg",
    knot: "kn", knots: "kn", nauticalmile: "nmi", nauticalmiles: "nmi",
    stone: "st", stones: "st", tonne: "t", tonnes: "t", ton: "t", tons: "t",
    celsius: "c", fahrenheit: "f", kelvin: "k", "\\u00b0c": "c", "\\u00b0f": "f", "\\u00b0k": "k"
  })
  property var fileGlyphs: ({
    ".mp3": "A", ".flac": "A", ".ogg": "A", ".m4a": "A", ".wav": "A",
    ".png": "B", ".jpg": "B", ".jpeg": "B", ".gif": "B", ".svg": "B",
    ".mp4": "C", ".mkv": "C", ".webm": "C", ".mov": "C",
    ".pdf": "D", ".txt": "E", ".md": "E", ".zip": "F"
  })
  property string fileManagerSearchCommand: ""
  property var fileManagerCandidates: ["dolphin", "nautilus", "thunar", "nemo", "pcmanfm", "files"]
  property var appLibrary: null
  property bool opened: false
  property bool deleteConfirmOpen: false
  property var deleteTarget: null
  property int layoutSerial: 0
  property int browseDirLimitX: 0
  property string fileManagerDetected: ""
  property bool capFileTier: true
  property int fileTierLimit: 5
  property int uncappedFolderLimit: 6
  property int uncappedFileLimit: 12
  property int browseDirLimit: 120
  property int browseFileLimit: 240
  property var binaries: ({ fd: true, hyprctl: true, wlcopy: true, wlpaste: true, baloo: true, focus: true })
  property bool binariesProbed: false
  property var fileDirRows: []
  property var fileFileRows: []
  property var fileContentRows: []
  property string fileSearchPending: ""
  property int fileSearchSerial: 0
  property string fileSearchPhase: ""
  property string fileSearchQuery: ""
  property string contentRowsQuery: ""
  property string contentSearchPending: ""
  property bool contentLivenessPending: false
  property string winSearchPending: ""
  property var focusPending: null
  property bool livenessPending: false
  property bool guardsPending: false
  property bool recentsLanded: true
  property string placesXbelRaw: ""
  property string gtkBookmarksRaw: ""
  property string dateRowFormat: "hh:mm:ss"
  property bool dateRowShowing: false
  property var recentsLive: ({})
  property var liveDirs: ({})
  property var recentsEntries: []
  property var placesEntries: []
  property bool recentsLanded: true
  property bool showRecentRows: false
  property var winClientsJson: ""
  property double winClientsAt: 0
  property int winClientsMaxAgeMs: 10000
  property bool separateFolderRows: true
  property int contentTierLimit: 3
  property var providers: ({})
  property string defaultMenuPath: ""
  property string userMenuPath: ""
  property var defaultMenuItems: []
  property var userMenuItems: []
  property var navStack: []
  property var providerQueue: []
  property var providersLoaded: ({})
  property int providerRevision: 0
  property bool rowsLoaded: true
  property string activeMenu: "root"
  property string fontFamily: ""
  property bool requestActive: false
  property string selectionFile: ""
  property string doneFile: ""
  property int selectedIndex: 0
  property bool cursorActive: false
  property bool cursorPinned: false
  property int applySerial: 0
  property int requestSerial: 0
  property string toastText: ""
  property int toastY: 0
  property string clipboardCommand: "/usr/bin/wl-copy"
  property string fileOpenCommand: ""
  property int dmenuWidth: 300
  property int dmenuMaxHeight: 0
  property var dmenuOptions: []
  property string dmenuPrompt: ""
  property string fileManagerSearchCommandEffective: ""
  property string frecencyPath: ""
  property bool dateRowShowing: false
  property string dateRowFormat: "hh:mm:ss"
  property int contentTierLimit: 3
  property string fileManagerCommand: ""
  property string fileManagerBinary: ""
  property bool fileManagerRedirects: false
"""

# Functions that reference UI objects (panel/displayModel/resultList/...) cannot run
# outside the shell; keep them but they will only be called if they avoid those.
bodies = "\n\n".join(f[3] for f in funcs)

STUBS = """
  // ---- UI stubs so the interaction functions can be exercised outside the shell
  ListModel { id: displayModel }
  // An id is not a property: expose the model so a test can reach it.
  property alias displayModelRef: displayModel
  QtObject {
    id: panel
    property int cardTop: -1
    property int maxRowsHeight: -1
    property int height: 1080
    property int width: 1920
    property bool shown: true
    function freezeCardTop() { }
  }
  QtObject { id: card; property real contentTopInset: 0; property real contentRightInset: 0
             property real contentBottomInset: 0; property real contentLeftInset: 0
             property real width: 400; property real height: 600 }
  QtObject { id: resultList
    property real originY: 0; property real contentY: 0
    property real contentHeight: 0; property real height: 600
    function positionViewAtIndex(i, mode) { }
    function itemAtIndex(i) { return null }
  }
  Item { id: keyCatcher; function forceActiveFocus() { } }
  // Timer stubs: the functions only ever restart/stop them.
  Timer { id: fileSearchTimer; interval: 180 }
  Timer { id: contentSearchTimer; interval: 300 }
  Timer { id: recentsSyncTimer; interval: 250 }
  Timer { id: pathCopiedHide; interval: 1400 }
  Timer { id: dateTick; interval: 1000; repeat: true }
  QtObject { id: clipPasteProc; property bool running: false; property string collected: ""; property string command: "" }
  QtObject { id: fileSearchProc; property bool running: false; property string collected: ""; property string command: "" }
  QtObject { id: winSearchProc; property bool running: false; property string collected: ""; property string command: "" }
  QtObject { id: contentProc; property bool running: false; property string collected: ""; property string command: "" }
  QtObject { id: contentLivenessProc; property bool running: false; property string collected: ""; property string command: "" }
  QtObject { id: livenessProc; property bool running: false; property string collected: ""; property string command: "" }
  QtObject { id: providerProc; property bool running: false; property string collected: ""; property string command: "" }
  QtObject { id: binProbe; property bool running: false; property string collected: ""; property string command: "" }
  QtObject { id: guardProc; property bool running: false; property string collected: ""; property string command: "" }
  QtObject { id: focusProc; property bool running: false; property string collected: ""; property string command: "" }
  QtObject { id: resultProc; property bool running: false; property string collected: ""; property string command: "" }
  Timer { id: pasteWatchdog; interval: 4000 }
  Timer { id: fileSearchWatchdog; interval: 4000 }
  Timer { id: winSearchWatchdog; interval: 4000 }
  Timer { id: contentWatchdog; interval: 4000 }
  Timer { id: contentLivenessWatchdog; interval: 4000 }
  Timer { id: livenessWatchdog; interval: 4000 }
  Timer { id: providerProcWatchdog; interval: 4000 }
  Timer { id: binProbeWatchdog; interval: 4000 }
  Timer { id: focusWatchdog; interval: 4000 }
  Timer { id: guardProcWatchdog; interval: 4000 }
  Item { id: deleteConfirm; property int selectedIndex: 0 }
  QtObject { id: pathCopiedToast; property real height: 32; property real opacity: 0; property real width: 100 }
  Item { id: pointerGate; function reset() { } function allowInitialSample() { } function moved(a, b) { return true } }
"""

harness = f'''import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "MenuModel.js" as MenuModel

// Auto-generated harness: the launcher's own functions, verbatim, executed by a
// real Qt6 QML engine.
Item {{
  id: root
{PROPS}
{bodies}
{STUBS}
}}
'''
# The root property snippet above was extended by hand over the session and
# now repeats a few names; QML refuses a redefinition, so keep the first of
# each. ONLY root-level lines (indent 2) are touched: nested stubs legitimately
# reuse names like width/height, and a line may declare two properties at once.
import re as _re
_seen = set()
_kept = []
for _line in harness.splitlines(True):
    _m = _re.match(r"  property\s+\S+\s+(\w+)\s*:", _line)
    if _m and _line.count("property") == 1:
        if _m.group(1) in _seen:
            continue
        _seen.add(_m.group(1))
    _kept.append(_line)
harness = "".join(_kept)

os.makedirs(OUT, exist_ok=True)
open(os.path.join(OUT, "Harness.qml"), "w", encoding="utf-8").write(harness)
# The harness calls MenuModel; keep its copy in step with the repo.
import shutil as _shutil
_shutil.copyfile(os.path.join(os.path.dirname(SRC), "MenuModel.js"),
                 os.path.join(OUT, "MenuModel.js"))

# Quickshell mock module
os.makedirs(os.path.join(OUT, "Quickshell"), exist_ok=True)
open(os.path.join(OUT, "Quickshell", "qmldir"), "w").write(
    "module Quickshell\nsingleton Quickshell 1.0 Quickshell.qml\n")
open(os.path.join(OUT, "Quickshell", "Quickshell.qml"), "w").write(
    '''pragma Singleton
import QtQuick

QtObject {
  property var envMap: ({ "HOME": "/home/testuser", "OMARCHY_PATH": "/home/testuser/.local/share/omarchy" })
  function env(name) { return envMap[name] !== undefined ? envMap[name] : "" }
}
''')

# qs.Commons / qs.Ui mocks (only what the harness touches)
for mod, body in {
    "qs.Commons": """pragma Singleton
import QtQuick

QtObject {
  function shellQuote(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }
  function alpha(c, a) { return c }
  function execDetached(c) {}
  function execArgv(a) {}
  // Copied verbatim from upstream omarchy shell/Commons/Util.qml
  function editsFilter(event, text) {
    if (!text) return false
    if (event.modifiers & (Qt.AltModifier | Qt.MetaModifier)) return false
    if (event.key === Qt.Key_U)
      return event.modifiers === Qt.ControlModifier
    return event.key === Qt.Key_Backspace
  }
  function editedFilter(event, text) {
    if (event.key === Qt.Key_U) return ""
    if (event.modifiers & Qt.ControlModifier)
      return text.replace(/\\s+$/, "").replace(/\\S+$/, "")
    return text.slice(0, -1)
  }
}
""",
    "qs.Ui": '''pragma Singleton
import QtQuick

QtObject {
  function surfaceSpec() { return ({}) }
  function left() { return 0 }
  function right() { return 0 }
}
''',
}.items():
    d = os.path.join(OUT, *mod.split("."))
    os.makedirs(d, exist_ok=True)
    leaf = {"qs.Commons": "Util", "qs.Ui": "Border"}[mod]
    open(os.path.join(d, "qmldir"), "w").write(
        f"module {mod}\nsingleton {leaf} 1.0 {leaf}.qml\n")
    open(os.path.join(d, leaf + ".qml"), "w").write(body)

json.dump([{"name": n, "start": a, "end": b} for n, a, b, _ in funcs],
          open(os.path.join(OUT, "funcs.json"), "w"), indent=1)
print("wrote harness to " + OUT, file=sys.stderr)
