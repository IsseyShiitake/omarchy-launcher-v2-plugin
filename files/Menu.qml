import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "MenuModel.js" as MenuModel

Item {
  id: root

  // Injected by omarchy-shell when this plugin is summoned. A shell started
  // without the variable used to resolve the menu sources to "/default/…"
  // and open empty with no diagnostic — fall back to the standard install
  // location instead.
  property string omarchyPath: {
    var injected = Quickshell.env("OMARCHY_PATH")
    return injected && injected.length > 0 ? injected : Quickshell.env("HOME") + "/.local/share/omarchy"
  }
  property var shell: null
  property var manifest: null

  // Plugin lifecycle hooks. The host calls open(payloadJson) after
  // `omarchy-shell shell summon omarchy.menu ...` and close() when hidden.
  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }

    // Unfreeze here, not on close: resetting cardTop while the 200ms fade-out
    // still plays re-centers the card mid-fade (visible teleport). Between
    // close and the next open the frozen geometry is harmless — nothing
    // renders. Guarded so a re-route while open keeps its frozen top.
    if (!root.opened) {
      panel.cardTop = -1
      panel.maxRowsHeight = -1
    }

    if (payload.fontFamily) root.fontFamily = payload.fontFamily

    if (payload.mode === "select" || payload.mode === "input") {
      root.openDmenu(payload)
    } else {
      root.openRoute(payload.initialMenu || payload.menu || "root")
    }
  }

  function close() {
    root.cancel()
  }

  function refresh() {
    defaultMenuFile.reload()
    userMenuFile.reload()
    return "ok"
  }

  function ping() { return "ok" }

  property string fontFamily: Style.font.menuFamily
  // JSONC menu definitions. The shell parses both at startup and merges
  // the user file on top of the defaults, so the keybind → IPC → visible
  // path doesn't have to shell out to bash + jq on every open.
  property string defaultMenuPath: omarchyPath + "/default/omarchy/omarchy-menu.jsonc"
  property string userMenuPath: Quickshell.env("HOME") + "/.config/omarchy/extensions/omarchy-menu.jsonc"
  property var defaultMenuItems: []
  property var userMenuItems: []
  property bool opened: false
  property string mode: "menu"
  readonly property bool dmenuActive: mode === "select" || mode === "input"
  property string dmenuPrompt: ""
  property var dmenuOptions: []
  property string selectionFile: ""
  property string doneFile: ""
  property int dmenuWidth: 300
  property int dmenuMaxHeight: 0
  property bool requestActive: false
  property bool rowsLoaded: false
  property string activeMenu: "root"
  property string filterText: ""
  property int selectedIndex: 0
  property bool cursorActive: false
  // True only once the user actually moved the cursor (arrows, page keys,
  // pointer). Typing parks it on the first row without pinning it, which is
  // what keeps the highlight on the best result as async tiers land — see
  // rebuildDisplay's anchor.
  property bool cursorPinned: false
  property int requestSerial: 0
  property int applySerial: 0
  property var items: ({})
  property var itemOrder: []
  property var navStack: []
  property var providersLoaded: ({})
  property var providerQueue: []
  property int providerRevision: 0

  // ---- File/folder search tier ---------------------
  // fd runs asynchronously per search keystroke (debounced); results land in
  // two phases (dirs, then files) and are appended below the menu matches.
  property var fileDirRows: []
  property var fileFileRows: []
  property string fileSearchPending: ""
  property int fileSearchSerial: 0
  property string fileSearchPhase: ""
  property string fileSearchQuery: ""
  // ---- Open-windows tier ---------------------
  // Rows are DERIVED at rebuild time from the cached `hyprctl clients` JSON and
  // the query at hand (see winClientsJson), never stored: a stored set could
  // outlive the filter it was computed for and show windows that no longer
  // match. Only the pending-query slot is state.
  property string winSearchPending: ""
  property var focusPending: null
  // ---- Baloo content tier ---------------------
  property var fileContentRows: []
  // The query those rows answer. A killed or failed run keeps the last good set
  // (a half-read index answer is worse than none), so the set must carry the
  // query it belongs to — otherwise it would be shown under a newer filter.
  property string contentRowsQuery: ""
  property string contentSearchPending: ""
  property bool contentLivenessPending: false
  // ---- Recent documents + places ---------------------
  // Parsed from the two xbel files (and, on a non-KDE machine, the GTK
  // bookmarks file) at open; a liveness pass (44% of recents are dead paths)
  // filters before any row is ever shown.
  property var recentsEntries: []
  property var placesEntries: []
  // Raw text of the two places sources, held until BOTH have landed so one
  // merge produces the tier (either file may be missing on a given machine).
  property string placesXbelRaw: ""
  property string gtkBookmarksRaw: ""
  // GTK bookmarks file — Nautilus/Thunar/GTK-chooser places. GTK4 still reads
  // the gtk-3.0 path, so one property covers both.
  property string gtkBookmarksPath: Quickshell.env("HOME") + "/.config/gtk-3.0/bookmarks"
  property var recentsLive: ({})
  property var liveDirs: ({})
  property bool recentsLanded: false
  property bool livenessPending: false
  // ---- Frecency (file + window tiers) ----
  property var frecency: ({})
  property bool frecencyLoaded: false
  readonly property string frecencyPath: Quickshell.env("HOME") + "/.local/state/omarchy/launcher-frecency.json"

  // Live date/time answer rows: true while a date answer is on screen, with
  // the format it was rendered in — the tick timer below re-renders it each
  // second so Enter copies what the display is showing NOW, not the stamp
  // from when the query was typed.
  property bool dateRowShowing: false
  property string dateRowFormat: "hh:mm:ss"

  // ---- Result presentation switches ---------------------
  // Each switch below is independent and ON by default, so any one of them can
  // be returned to the pre-pack look from this block alone. They shape what is
  // SHOWN only; what fd fetches adapts to them, because a capped block has to
  // see more candidates to show the real best five rather than the first five
  // the walk happened to reach.
  //
  // Folders and files render as two blocks with the same hairline between them
  // that already separates menu matches, windows and the file tier.
  property bool separateFolderRows: true
  // Folders and files are each capped at fileTierLimit. A block that had more
  // matches than that ends with a row that hands the query to the file
  // manager's own search — the "there is more, elsewhere" escape hatch.
  // Without a file manager that can be handed a query, the cap is not applied
  // at all and the pre-pack caps below take over (see fileManagerRedirects).
  property bool capFileTier: true
  property int fileTierLimit: 5
  // What a block shows when there is no redirect row to earn the tighter cap.
  // These are the pre-pack caps fd itself is limited to in that mode, so the
  // two never disagree about how many rows a block may hold.
  property int uncappedFolderLimit: 6
  property int uncappedFileLimit: 12
  // Recent documents + Dolphin places would otherwise lead the file tier (they
  // score below zero on purpose), which read as unexplained extra folders
  // floating above the real results. Off by default: frecency already learns
  // which paths you actually open, without the system's own recent list.
  property bool showRecentRows: false
  // Baloo full-text rows kept while the tier is capped. They are files too,
  // but a different kind of match: they get their own smaller budget and their
  // own hairline-separated block after the file block.
  property int contentTierLimit: 3
  // "#rrggbb" (also #rgb, #rgba, #rrggbbaa) answers with the rgb()/hsl() forms.
  property bool colorAnswers: true
  // Command the capped tier's "more" rows run. "%1" becomes the query as a
  // shell-inert, percent-encoded token (see searchQueryToken) — safe inside
  // or outside quotes. EMPTY = AUTO (see fileManagerCandidates):
  // Dolphin gets KDE's Baloo search — the content tier already needs a Baloo
  // index — and everything else gets nothing, because no other file manager
  // can be handed a query from the command line. Set this to override, e.g.
  // "dolphin 'baloosearch:?query=%1'" or a wrapper script of your own.
  //
  // KDE's worker reads the term from `?query=`, NOT from the path: verified with
  // `kioclient ls "baloosearch:/launcher"` → no results, versus
  // `kioclient ls "baloosearch:?query=launcher"` → real hits. The `?` sits
  // inside quotes so a login shell with nullglob cannot swallow the word.
  //
  // GNOME Files is NOT an option here however tempting: `nautilus --search`
  // does not exist (the whole CLI is --version/--new-window/--quit/--select,
  // docs/nautilus.1) and passing its internal search URI is refused outright
  // ("“x-nautilus-search:” is an internal protocol. Opening this location
  // directly is not supported.", src/nautilus-application.c). Thunar, Nemo and
  // PCManFM have no search switch either. So on those machines the file tier
  // simply shows more rows instead of pretending it can hand them over.
  property string fileManagerSearchCommand: ""
  // File managers the probe looks for, most capable first. The first one
  // present is `fileManagerDetected`; a configured command's own binary is
  // probed too, so a custom command is never reported as "no file manager".
  property var fileManagerCandidates: ["dolphin", "nautilus", "thunar", "nemo", "pcmanfm", "files"]
  // Written by the probe. Empty = no file manager found.
  property string fileManagerDetected: ""
  // What the "more" rows actually run: the configured command, or the built-in
  // one for a detected file manager, or "" when there is nothing to run.
  readonly property string fileManagerCommand: root.fileManagerSearchCommand !== ""
    ? root.fileManagerSearchCommand
    : (root.fileManagerDetected === "dolphin" ? "dolphin 'baloosearch:?query=%1'" : "")
  // Binary named by the effective command, for the label and the "not found"
  // hint; falls back to the detected file manager (which has no search).
  readonly property string fileManagerBinary: {
    var parts = String(root.fileManagerCommand || "").trim().split(/\s+/)
    if (parts.length > 0 && parts[0]) return parts[0]
    return root.fileManagerDetected
  }
  // A redirect row needs a command AND that command's own binary: a command
  // pointing at something that is not installed would otherwise close the menu
  // and open nothing, silently — the pack's oldest failure mode. The probe
  // checks the configured binary FIRST, so "the first one found is not the
  // command's binary" means that binary is not on this machine. Until the probe
  // answers there is no command for the auto case anyway, and the file tier is
  // simply shown uncapped for the few milliseconds before it lands (fd's own
  // 180 ms debounce means this is never visible).
  readonly property bool fileManagerRedirects: root.fileManagerCommand !== ""
    && root.fileManagerDetected !== ""
    && root.fileManagerDetected === root.fileManagerBinary
  // Clipboard sink for every copy action (Enter on an answer row, Ctrl+C or
  // right-click on a file row). /usr/bin exists everywhere; /usr/sbin does not.
  property string clipboardCommand: "/usr/bin/wl-copy --type 'text/plain;charset=utf-8'" // pinned 2026-10-15: wl-copy infers MIME; numerics sniff as octet-stream
  // Last anchor for the confirmation pill, in card coordinates — set by the
  // click or the keyboard copy, read by the toast's y binding. The text is state
  // too, so one pill serves "Path copied!" and "Color copied!".
  property int toastY: 0
  property string toastText: "Path copied!"

  // ---- Folder browsing ----------------------------
  // Right (or Tab) on a folder row turns the list into that folder's contents —
  // no other action, no click. Typing then filters inside the folder,
  // Backspace/Left (with an empty filter) or the ".." row go back up, and going
  // up from $HOME ends the browse and search resumes. "" = normal search.
  property string browseRoot: ""
  // Browsing is a listing, not a search: the tier cap and its redirect rows do
  // not apply there, and these caps are only a guard against enormous folders.
  property int browseDirLimit: 120
  property int browseFileLimit: 240
  // Browsing is deliberate navigation, so the listing is not narrowed the way a
  // search is: `--no-ignore` brings back .gitignore'd entries (node_modules/,
  // dist/, build/) and symlinks are included. Hidden dotfiles stay hidden, which
  // is what a file manager shows by default too.
  property bool browseShowsIgnored: true
  readonly property string browseLabel: root.browseRoot ? root.shortPath(root.browseRoot) + "/" : ""

  // ---- Window-list cache ----
  // hyprctl clients answers in milliseconds and windows do not change between
  // keystrokes, so one answer is filtered in JS for a second instead of being
  // asked for again. Emptied at every open, because windows may have come and
  // gone while the launcher was closed.
  property string winClientsJson: ""
  property double winClientsAt: 0
  property int winClientsTtlMs: 1000
  // Hard ceiling for showing ROWS out of that cache. The TTL above only decides
  // whether a fetch is needed; this one decides whether the rows on screen may
  // still be derived from it at all. Without it a spawn that fails without
  // reporting (exactly how a missing binary behaves) would leave stale windows
  // listed for the rest of the session.
  property int winClientsMaxAgeMs: 10000

  // ---- Capability probe (one subprocess per shell start) ----
  // A missing binary is otherwise invisible: a Process whose command cannot be
  // found does not even emit onExited, so the tier it powers is silently empty.
  // One `command -v` pass learns which tiers can work, and a hint row says so.
  property var binaries: ({ fd: true, hyprctl: true, wlcopy: true, wlpaste: true, baloo: true, focus: true })
  property bool binariesProbed: false
  // Set when the watchdog drops a probe: its half-read answer must not be
  // applied, because "=0" means "tier disabled".
  property bool binProbeDropped: false

  // ---- Frecency decay ----
  // A hit is worth half as much after a month, so last month's binge stops
  // outranking today's daily driver. The cap applies to the DECAYED count, so a
  // favourite can still outrank an equal match but never dominate a band.
  readonly property double frecencyHalfLifeMs: 30 * 24 * 60 * 60 * 1000

  // Shared application engine (entries, hidden filters, icons, launch,
  // removal), owned by the shell and also used by the standalone launcher.
  readonly property var appLibrary: root.shell ? root.shell.appLibrary : null
  property bool deleteConfirmOpen: false
  property var deleteTarget: null
  onOpenedChanged: if (!opened) { deleteConfirmOpen = false; deleteTarget = null }
  // Bound to the central [menu] section in shell.toml via Color.qml.
  // Each color already includes its alpha companion (composed in the
  // singleton), so consumers can drop them straight into a Rectangle.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property color selectedBorder: Color.menu.selectedBorder
  property var selectedBorderSpec: Border.surfaceSpec("menu", "selected-border", selectedBorder, 0)
  readonly property real rowReservedBorderLeft: Border.left(selectedBorderSpec)
  readonly property real rowReservedBorderRight: Border.right(selectedBorderSpec)
  readonly property int cornerRadius: Style.cornerRadius
  property int contentMargin: Style.spacing.panelPadding
  property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  property int contentSpacing: Style.spacing.md
  property int baseRowHeight: Math.max(Style.space(50), Style.font.body + Style.spacing.rowPaddingX * 2)
  property int detailRowHeight: Math.max(Style.space(58), Style.font.body + Style.font.caption + Style.spacing.rowPaddingX * 2)
  // How much of the first hidden row stays visible at the fold — enough to
  // read as a cut-off row rather than a bottom border.
  property int rowPeek: Math.round(baseRowHeight * 0.55)
  property int rowSpacing: Style.spacing.xs
  property int dividerHeight: Style.space(17)
  // Sections that draw a hairline above their first row. The height math and
  // the section delegate both read THIS list: two copies of it drifted apart
  // silently (a divider the delegate drew but the height did not count), so a
  // new block is added in exactly one place now.
  readonly property var dividerSections: ({
    "folders": true, "files": true, "content": true, "windows": true, "web": true
  })
  function hasDivider(section) { return root.dividerSections[section] === true }
  property int layoutSerial: 0
  property int cardWidth: Math.min(root.dmenuActive ? Style.space(root.dmenuWidth) : ((root.activeMenu === "trigger.capture.screenrecord" || root.activeMenu === "style.font") ? Style.space(520) : Style.space(300)), panel.width - Style.gapsOut * 2)
  property int visibleRowsHeight: root.dmenuActive ? dmenuRowListHeight(layoutSerial, displayModel.count, filterText) : rowListHeight(layoutSerial, displayModel.count, filterText)
  property int cardHeight: root.dmenuActive
    ? Math.min(contentMargin * 2 + headerHeight + (mode === "input" ? 0 : contentSpacing + visibleRowsHeight), panel.height - Style.gapsOut * 2)
    : Math.min(contentMargin * 2 + headerHeight + contentSpacing + visibleRowsHeight, panel.height - Style.gapsOut * 2)

  function finishRequest(selection) {
    if (!root.requestActive || !root.doneFile) {
      root.opened = false
      return
    }

    var activeSelectionFile = root.selectionFile
    var activeDoneFile = root.doneFile
    root.requestActive = false
    root.selectionFile = ""
    root.doneFile = ""

    if (selection === null || selection === undefined || activeSelectionFile === "") {
      // No selection, or a caller that named a done file but no selection
      // file: a `printf ... > ''` redirection would fail at runtime and the
      // selection would silently never land.
      resultProc.command = ["bash", "-c", ": > " + Util.shellQuote(activeDoneFile)]
    } else {
      resultProc.command = ["bash", "-c", "printf '%s\\n' " + Util.shellQuote(selection) + " > " + Util.shellQuote(activeSelectionFile) + "; : > " + Util.shellQuote(activeDoneFile)]
    }
    resultProc.running = true
  }

  function runAction(action) {
    var command = String(action || "")
    if (!command) return

    var summon = MenuModel.summonAction(command)
    if (summon && root.shell && root.shell.summon(summon.id, summon.payload)) return

    Util.execDetached(command)
  }

  // Menu rows only surface their detail while a search is narrowing them;
  // dmenu rows carry caller-supplied subtext that must always be visible.
  function rowHeightForDetail(detail) {
    return (root.filterText || root.dmenuActive) && detail ? root.detailRowHeight : root.baseRowHeight
  }

  // Height the card can devote to rows before running off the screen — or
  // past the frozen top edge once a search has pinned the card in place.
  // Uses panel.cardTop rather than effectiveCardTop: the centered top is
  // derived from the card height, which this value feeds.
  function availableRowsHeight() {
    var top = panel.cardTop >= 0 ? panel.cardTop : Style.gapsOut
    var available = panel.height - top - Style.gapsOut - root.contentMargin * 2 - root.headerHeight - root.contentSpacing
    // The starting menu sets the ceiling along with the offset: drilling into
    // a longer submenu scrolls behind the fold instead of growing the card.
    if (panel.maxRowsHeight >= 0) available = Math.min(available, panel.maxRowsHeight)
    // A card that swallows the whole screen reads as a page, not a menu.
    return Math.min(available, Math.round(panel.height * 0.7))
  }

  // When every row fits, the list gets its full height. When they don't,
  // the card must end mid-row: a clipped row is what tells the eye there is
  // more below the fold, so never come out even on a row boundary.
  function foldedListHeight(totals, available) {
    var count = totals.length
    if (count === 0) return root.baseRowHeight
    if (totals[count - 1] <= available) return totals[count - 1]

    var peek = root.rowPeek
    var full = 0
    while (full < count && totals[full] <= available) full++
    while (full > 1 && totals[full - 1] + root.rowSpacing + peek > available) full--
    if (full < 1) return Math.max(available, root.baseRowHeight)

    return totals[full - 1] + root.rowSpacing + peek
  }

  function rowListHeight(_serial, _count, _filter) {
    if (displayModel.count === 0) return root.baseRowHeight

    var totals = []
    var total = 0
    var previousSection = ""

    for (var i = 0; i < displayModel.count; i++) {
      var row = displayModel.get(i)
      if (i > 0) total += root.rowSpacing
      if (i > 0 && root.hasDivider(row.section) && previousSection !== row.section) total += root.dividerHeight
      total += root.rowHeightForDetail(row.detail)
      previousSection = row.section
      totals.push(total)
    }

    return foldedListHeight(totals, availableRowsHeight())
  }

  function dmenuRowListHeight(_serial, _count, _filter) {
    if (root.mode === "input") return 0
    if (displayModel.count === 0) return root.baseRowHeight

    var available = availableRowsHeight()
    if (root.dmenuMaxHeight > 0) available = Math.min(available, Style.space(root.dmenuMaxHeight))

    var totals = []
    var total = 0
    for (var i = 0; i < displayModel.count; i++) {
      if (i > 0) total += root.rowSpacing
      total += root.rowHeightForDetail(displayModel.get(i).detail)
      totals.push(total)
    }

    return foldedListHeight(totals, available)
  }

  function item(id) {
    return root.items[id] || null
  }

  // ------------------------------------------------------------------
  // JSONC → normalized item array. Mirrors the bash bin's jq pipeline so
  // the on-disk authoring format stays untouched.
  // ------------------------------------------------------------------

  function parseMenuJsonc(raw) {
    return MenuModel.parseMenuJsonc(raw)
  }

  // Merge defaults + user extension. Later entries override earlier ones
  // on a per-key basis (so the user can tweak label/icon/action without
  // re-declaring the whole row).
  function rebuildItemsFromSources() {
    var mergedMenu = MenuModel.mergeMenuSources(root.defaultMenuItems, root.userMenuItems)
    root.providerRevision += 1
    root.providersLoaded = ({})
    root.providerQueue = []
    root.items = mergedMenu.items
    root.itemOrder = mergedMenu.itemOrder
    root.rowsLoaded = true
    root.evaluateGuards()
    if (root.opened) {
      root.rebuildDisplay()
      if (!root.dmenuActive) {
        if (root.filterText.trim() && !root.browseRoot) root.loadProvidersForSearch()
        else root.loadProviderForMenu(root.activeMenu)
      }
    }
  }

  // Each known provider is a tiny bash one-liner that enumerates a list and
  // emits one tab-delimited row per item: `label\tvalue\tcurrent`. The shell
  // turns those into menu items children of `menuId`. A `volatile` provider
  // re-runs every time its submenu is entered, so a font installed since the
  // shell started shows up without restarting it.
  readonly property var providers: ({
    "fonts": {
      script: "current=$(omarchy-font-current 2>/dev/null); omarchy-font-list 2>/dev/null | while read -r f; do [[ -z $f ]] && continue; printf '%s\\t%s\\t%s\\n' \"$f\" \"$f\" \"$current\"; done",
      icon: "",
      volatile: true,
      actionFor: function(value) { return "omarchy-font-set " + Util.shellQuote(value) }
    },
    "power-profiles": {
      script: "current=$(powerprofilesctl get 2>/dev/null); omarchy-powerprofiles-list 2>/dev/null | while read -r p; do [[ -z $p ]] && continue; printf '%s\\t%s\\t%s\\n' \"$p\" \"$p\" \"$current\"; done",
      icon: "\udb81\udc0b",
      actionFor: function(value) { return "omarchy-powerprofiles-set autodetect " + Util.shellQuote(value) }
    }
  })

  function slugify(value) {
    return MenuModel.slugify(value)
  }

  // The apps provider is QML-native: rows come from the shared AppLibrary
  // (DesktopEntries) instead of a bash enumeration, so they carry image
  // icons, launch feedback, and uninstall support like the launcher.
  function mergeAppRows() {
    if (!root.appLibrary) return

    var rows = root.appLibrary.sortedEntries("")
    var appRows = []
    for (var j = 0; j < rows.length; j++) {
      var entry = rows[j].entry
      var appId = String(entry.id || "")
      if (!appId) continue
      var subtext = root.appLibrary.entrySubtext(entry)
      var aliases = subtext ? [subtext] : []
      try {
        if (entry.keywords && typeof entry.keywords.join === "function") aliases = aliases.concat(entry.keywords)
      } catch (e) { }
      appRows.push({
        id: "apps." + appId,
        parent: "apps",
        kind: "app",
        icon: "",
        appIcon: String(entry.icon || ""),
        appId: appId,
        label: root.appLibrary.entryName(entry),
        title: "",
        target: "",
        description: subtext,
        action: "",
        provider: "",
        aliases: aliases,
        when: "",
        checked: "",
        disabled: "",
        order: 0
      })
    }

    var merged = MenuModel.mergeAppRows(root.items, root.itemOrder, appRows)
    root.items = merged.items
    root.itemOrder = merged.itemOrder
    if (root.opened) root.rebuildDisplay()
  }

  function startProviderForMenu(id) {
    var entry = root.item(id)
    if (!entry || !entry.provider || root.providersLoaded[id]) return
    if (entry.provider === "apps") {
      root.providersLoaded[id] = true
      root.mergeAppRows()
      return
    }
    var spec = root.providers[entry.provider]
    if (!spec) return

    root.providersLoaded[id] = true
    providerProc.menuId = id
    providerProc.providerKey = entry.provider
    providerProc.revision = root.providerRevision
    providerProc.collected = ""
    providerProc.command = ["bash", "-lc", spec.script]
    providerProc.running = true
    providerProcWatchdog.restart()
  }

  function mergeProviderRows(rows, menuId, providerKey) {
    var spec = root.providers[providerKey]
    if (!spec) return
    var lines = String(rows || "").split("\n")
    var providerRows = []
    var takenIds = ({})
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (!line) continue
      var parts = line.split("\t")
      var label = parts[0] || ""
      var value = parts[1] || parts[0] || ""
      var current = parts[2] || ""
      if (!label) continue
      // Distinct values can slugify alike — Fira Code and Fira-Code both give
      // fira-code — and a repeated id is dropped, which would silently lose a
      // row from the list. Nudge it until it is the row's own.
      var rowId = menuId + "." + root.slugify(value)
      while (takenIds[rowId]) rowId += "-"
      takenIds[rowId] = true

      providerRows.push({
        id: rowId,
        parent: menuId,
        kind: "action",
        icon: (value === current) ? "✓" : (spec.icon || ""),
        label: label,
        title: "",
        target: "",
        description: "",
        action: spec.actionFor(value),
        provider: "",
        aliases: [],
        when: "",
        checked: "",
        disabled: "",
        order: 0
      })
    }
    var merged = MenuModel.swapProviderRows(root.items, root.itemOrder, menuId, providerRows)
    root.items = merged.items
    root.itemOrder = merged.itemOrder
    if (root.opened) root.rebuildDisplay()
  }

  function startNextProvider() {
    if (providerProc.running) return

    while (root.providerQueue.length > 0) {
      var id = root.providerQueue.shift()
      var entry = root.item(id)
      if (!entry || !entry.provider || root.providersLoaded[id]) continue

      root.startProviderForMenu(id)
      return
    }
  }

  // Entering a submenu is the one moment a volatile list is worth paying for
  // again: it may have been reshaped by the last pick from it. Search doesn't
  // invalidate, or every keystroke would restart the same enumeration.
  function invalidateVolatileProvider(id) {
    var entry = root.item(id)
    var spec = entry && entry.provider ? root.providers[entry.provider] : null
    if (spec && spec.volatile) root.providersLoaded[id] = false
  }

  // ---- File/folder search ---------------------
  // One reused Process runs fd in two chained phases (dirs, then files). The
  // serial bumped at every launch invalidates results of an older query; a
  // query queued while a run is in flight preempts the chain from its top.
  function requestFileSearch() {
    var query = root.filterText.trim()
    if (root.dmenuActive) { root.clearFileSearch(); return }
    // Browsing is exempt from the two-character floor and the "=" gate: an
    // empty filter there means "list this folder", which is the whole point.
    if (!root.browseRoot && (query.length < 2 || root.answerQuery(query) === "forced")) {
      root.clearFileSearch()
      return
    }
    // Rows on screen belong to the last launched query. Keep them while it
    // stays compatible — one a prefix of the other, so both forward typing
    // and backspace ride the debounce smoothly — and drop them the moment
    // the edit can only have made them wrong (replacement, mid-word fix).
    var stored = root.fileSearchQuery
    if ((root.fileDirRows.length > 0 || root.fileFileRows.length > 0) && stored
        && query.indexOf(stored) !== 0 && stored.indexOf(query) !== 0) {
      root.clearFileSearch()
    }
    fileSearchTimer.restart()
    // Baloo is the slowest tier (measured ~38 ms against a live index) and the
    // least sensitive to a keystroke, so it gets its own longer debounce
    // instead of riding the 180 ms file timer.
    contentSearchTimer.restart()
  }

  function clearFileSearch() {
    fileSearchTimer.stop()
    contentSearchTimer.stop()
    root.fileSearchPending = ""
    root.fileSearchSerial += 1
    root.fileSearchPhase = ""
    root.fileSearchQuery = ""
    root.fileDirRows = []
    root.fileFileRows = []
    root.winSearchPending = ""
    root.fileContentRows = []
    root.contentRowsQuery = ""
    root.contentSearchPending = ""
  }

  function startFileSearch() {
    var query = root.filterText.trim()
    if (!root.opened || root.dmenuActive) { root.clearFileSearch(); return }
    if (!root.browseRoot && query.length < 2) { root.clearFileSearch(); return }
    // No fd, no spawn: the probe already answered, and a failed start is silent.
    if (root.binaries.fd === false) return
    if (fileSearchProc.running) { root.fileSearchPending = query; return }
    root.launchFileSearch("dirs", query)
  }

  // fd's own cap bounds the walk, so it has to be generous enough for the
  // ranking to mean something: a cap of 12 handed back twelve substring hits
  // from the first directories the walk reached while better prefix matches
  // sat further down the tree, unseen. The tier cap then trims to what shows.
  // With the tier cap off, keep the pre-pack caps — the switch means "old
  // look", not "no cap at all".
  function fdResultLimit(isDir) {
    // A browse listing is the folder's own contents: the cap is a guard against
    // enormous directories here, not a ranking device.
    if (root.browseRoot) return isDir ? root.browseDirLimit : root.browseFileLimit
    // The tier cap is the pre-pack one when the pack is not capping at all, so
    // "no cap" still means the old numbers rather than every match fd can find.
    // With capFileTier on, fd always gets the generous cap even when no
    // redirect is possible: the ranking needs candidates to rank (a cap of 12
    // handed back twelve substring hits while better prefix matches sat further
    // down the tree, unseen), and the display cap below trims to the pre-pack
    // limit with a row that says so.
    if (!root.capFileTier) return isDir ? root.uncappedFolderLimit : root.uncappedFileLimit
    return isDir ? 20 : 40
  }

  // Why a block was cut short. A configured command whose binary the probe
  // could not find is a real misconfiguration and says so; a machine with a
  // file manager that has no search to hand a query to is not a fault, so the
  // row just states what was shown.
  function overflowDetail(total, shown, isDir) {
    // fd stops at --max-results, so a block that came back exactly full is "N or
    // more": printing the bare number would claim a precision fd never had.
    var counted = total >= root.fdResultLimit(isDir === true) ? total + "+" : String(total)
    if (root.fileManagerSearchCommand !== "" && !root.fileManagerRedirects)
      return root.fileManagerBinary + " not found — showing " + shown + " of " + counted
    return "Showing " + shown + " of " + counted + " — no file manager search available"
  }

  function launchFileSearch(phase, query) {
    root.fileSearchSerial += 1
    fileSearchProc.serial = root.fileSearchSerial
    fileSearchProc.collected = ""
    root.fileSearchPhase = phase
    root.fileSearchQuery = query
    // Absolute fd path: a bare name would be resolved through PATH (verified),
    // but the absolute one cannot pick up a different fd from a shell profile.
    // --fixed-strings + --ignore-case keep the query literal and matches
    // case-insensitive; fd matches on the basename, skips hidden and
    // gitignored paths by default, and marks directories with a trailing "/".
    var target = root.browseRoot ? root.browseRoot : Quickshell.env("HOME")
    var argv = ["/usr/bin/fd", "--absolute-path", "--fixed-strings", "--ignore-case"]
    // One level only while browsing: a query there filters the listing instead
    // of turning the folder into a second search root.
    if (root.browseRoot) {
      argv.push("--max-depth", "1")
      if (root.browseShowsIgnored) argv.push("--no-ignore")
      // A listing the user asked to see should not hide symlinks. fd reports
      // them as their own type, so they land in the file block; a symlinked
      // folder therefore opens rather than browsing — fd cannot tell them apart
      // without a stat, and the dir phase must stay directories-only.
      if (phase !== "dirs") argv.push("--type", "symlink")
    }
    argv.push("--max-results", String(root.fdResultLimit(phase === "dirs")))
    argv.push("--type", phase === "dirs" ? "directory" : "file")
    // An empty pattern matches everything, which is what a browse listing wants.
    argv.push("--", query, target)
    fileSearchProc.command = argv
    fileSearchProc.running = true
    fileSearchWatchdog.restart()
  }

  readonly property var fileGlyphs: ({
    ".mp3": "󰈌", ".flac": "󰈌", ".ogg": "󰈌", ".m4a": "󰈌", ".wav": "󰈌",
    ".png": "󰋩", ".jpg": "󰋩", ".jpeg": "󰋩", ".gif": "󰋩", ".svg": "󰋩",
    ".mp4": "󰎔", ".mkv": "󰎔", ".webm": "󰎔", ".mov": "󰎔",
    ".pdf": "󰈔", ".txt": "󰈢", ".md": "󰈢", ".zip": "󰀪"
  })

  function fileGlyphFor(name, isDir) {
    if (isDir) return "󰉋"
    var dot = name.lastIndexOf(".")
    if (dot < 0) return "󰈟"
    return root.fileGlyphs[name.substring(dot).toLowerCase()] || "󰈟"
  }

  // Emits the FULL delegate role set — the delegate's required properties all
  // bind; one missing role = a broken row. Glyphs are precomputed by the
  // caller (isDir is not a row role). `swatch` is empty except on colour
  // answers, where the delegate paints it as a chip.
  function actionRow(kind, icon, label, detail, target, score, section, appId) {
    return {
      itemId: kind + "." + target, disabled: false, kind: kind, icon: icon,
      iconFont: "", appIcon: "", appId: appId || "", label: label,
      target: target, detail: detail, path: "", childCount: 0, action: "",
      provider: "", score: score, section: section, swatch: "", isFolder: false
    }
  }

  // Every file-tier row's detail leads with WHAT KIND of match it is, then the
  // path: "folder · ~/Documents", "file · ~/Documents", "content · ~/Documents".
  // The folder/file split can be switched off (one merged block) and the
  // recents/places tier always mixes the two, so the word is the one thing that
  // says which is which — and it survives the detail line's right-side elision
  // because it sits at the front.
  function pathDetail(kind, dirPart) { return kind + "  ·  " + dirPart }

  function fileRowFor(line, isDir, query) {
    var path = String(line || "")
    if (!path) return null
    // fd marks directories with a trailing slash. Strip it, or the basename
    // (text after the LAST slash) parses as empty and every folder row is
    // silently dropped.
    if (path.length > 1 && path.charAt(path.length - 1) === "/") path = path.slice(0, -1)
    var slash = path.lastIndexOf("/")
    var name = slash >= 0 ? path.substring(slash + 1) : path
    if (!name) return null
    var dirPart = slash > 0 ? path.substring(0, slash) : "/"
    var home = Quickshell.env("HOME")
    // Prefix AND boundary: /home/ravi2 must not display as ~2/...
    if (dirPart.indexOf(home) === 0 && (dirPart.length === home.length || dirPart.charAt(home.length) === "/"))
      dirPart = "~" + dirPart.substring(home.length)
    var lowerName = name.toLowerCase()
    var needle = query.toLowerCase()
    var score = lowerName === needle ? 0 : (lowerName.indexOf(needle) === 0 ? 10 : 30)
    var depth = 0
    for (var c = 0; c < path.length; c++) if (path.charAt(c) === "/") depth += 1
    // Clamp the depth term: unclamped, a 40-slash path would reach the Baloo
    // content band (31000) and rank below content rows.
    return {
      itemId: "file." + path, parent: "root", kind: "file",
      icon: root.fileGlyphFor(name, isDir), label: name, target: path,
      detail: root.pathDetail(isDir ? "folder" : "file", dirPart),
      score: score * 1000 + Math.min(depth, 20) * 25, isDir: isDir,
      swatch: "", isFolder: isDir
    }
  }

  // ---- Folder browsing ----------------------------
  // Browsing reuses the whole file tier on a different root: entering a folder
  // clears the filter and re-runs the same two-phase chain one level deep, so
  // the folder/file blocks, the divider and the ranking all behave exactly as
  // they do in a search. Only the tier cap and its redirect rows step aside —
  // a listing is not a search.
  function shortPath(path) {
    var p = String(path || "")
    var home = Quickshell.env("HOME")
    if (p.indexOf(home) === 0 && (p.length === home.length || p.charAt(home.length) === "/"))
      p = "~" + p.substring(home.length)
    return p || "/"
  }

  function parentPathOf(path) {
    var p = String(path || "")
    var slash = p.lastIndexOf("/")
    return slash <= 0 ? "/" : p.substring(0, slash)
  }

  function isFolderRow(row) {
    return !!row && row.kind === "file" && row.isFolder === true && !!row.target
  }

  function browseInto(path) {
    var target = String(path || "")
    if (!target) return false
    panel.freezeCardTop()
    root.browseRoot = target
    // The filter belongs to the search, not to the folder.
    root.filterText = ""
    root.clearFileSearch()
    root.selectedIndex = 0
    root.cursorPinned = false
    root.cursorActive = true
    root.disarmPointer()
    // A browse listing is a discrete action, not a keystream: start it now
    // instead of riding the 180 ms search debounce (typing inside the browse
    // still debounces — it arrives through setFilter).
    root.startFileSearch()
    root.rebuildDisplay()
    Qt.callLater(function() { if (displayModel.count > 0) root.revealCursor() })
    return true
  }

  function browseUp() {
    if (!root.browseRoot) return false
    panel.freezeCardTop()
    var home = Quickshell.env("HOME")
    // $HOME (or /) is the top of the browse: going up from there resumes the
    // normal search instead of escaping to /.
    if (root.browseRoot === home || root.browseRoot === "/") {
      root.browseRoot = ""
      root.filterText = ""
      root.clearFileSearch()
      root.selectedIndex = 0
      root.cursorPinned = false
      root.rebuildDisplay()
      return true
    }
    return root.browseInto(root.parentPathOf(root.browseRoot))
  }

  // Right/Tab on the highlighted row: a folder (or the ".." row) is entered,
  // anything else is left to the caller. This is what makes Right mean "show me
  // what is inside" instead of "open this folder in the file manager".
  function enterHighlightedFolder() {
    if (!root.cursorActive || root.selectedIndex < 0 || root.selectedIndex >= displayModel.count) return false
    var row = displayModel.get(root.selectedIndex)
    if (row.kind === "up") return root.browseUp()
    if (!root.isFolderRow(row)) return false
    return root.browseInto(row.target)
  }

  function browseUpRow(section) {
    var atHome = root.browseRoot === Quickshell.env("HOME") || root.browseRoot === "/"
    var parent = root.parentPathOf(root.browseRoot)
    return {
      itemId: "browse.up", disabled: false, kind: "up", icon: "󰉋", iconFont: "",
      appIcon: "", appId: "", label: "..",
      // At the top of the browse this row leaves browse mode, so it says that
      // rather than naming a parent it will not visit.
      target: atHome ? "" : parent,
      detail: atHome ? "Back to search" : root.shortPath(parent),
      path: "", childCount: 0, action: "",
      provider: "", score: 0, section: section, swatch: "", isFolder: true
    }
  }

  // One dimmed, unselectable row naming something the user should know but
  // cannot act on from here (a missing tool, a capped listing). `section` lets
  // it close the block it belongs to; "" keeps it out of every block.
  function hintRow(text, detail, section) {
    return {
      itemId: "hint." + text, disabled: true, kind: "hint", icon: "", iconFont: "",
      appIcon: "", appId: "", label: text, target: "",
      detail: detail || "Install it to enable that tier", path: "", childCount: 0,
      action: "", provider: "", score: 0, section: section || "", swatch: "", isFolder: false
    }
  }

  // Tiers that answer NOTHING when their tool is absent. A file manager is
  // deliberately not one of them: without one (or without one that can search)
  // the file tier still works, it just shows its rows instead of redirecting —
  // so it must not keep the shell re-probing on every open.
  function anyTierMissing() {
    return root.binaries.fd === false || root.binaries.hyprctl === false
      || root.binaries.baloo === false || root.binaries.wlpaste === false
      || root.binaries.wlcopy === false || root.binaries.focus === false
  }

  // ---- Calculator tier ---------------------
  // "=<expression>" turns the launcher into a calculator: the result is the
  // top row and Enter copies it to the clipboard (wl-copy). Pure JS
  // recursive descent — no shell, no subprocess, instant on every keystroke.

  function calcTokenize(src) {
    var tokens = []
    var i = 0
    while (i < src.length) {
      var ch = src.charAt(i)
      if (ch === " " || ch === "\t") { i += 1; continue }
      if ((ch >= "0" && ch <= "9") || ch === ".") {
        var num = ""
        while (i < src.length && ((src.charAt(i) >= "0" && src.charAt(i) <= "9") || src.charAt(i) === ".")) {
          num += src.charAt(i)
          i += 1
        }
        if (num === "." || num.split(".").length > 2) return null
        tokens.push({ type: "num", value: Number(num) })
        continue
      }
      if ((ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z")) {
        var id = ""
        while (i < src.length && ((src.charAt(i) >= "a" && src.charAt(i) <= "z")
            || (src.charAt(i) >= "A" && src.charAt(i) <= "Z")
            || (src.charAt(i) >= "0" && src.charAt(i) <= "9") || src.charAt(i) === "_")) {
          id += src.charAt(i)
          i += 1
        }
        tokens.push({ type: "id", value: id })
        continue
      }
      if ("+-*/%^(),".indexOf(ch) >= 0) { tokens.push({ type: ch }); i += 1; continue }
      return null
    }
    return tokens
  }

  function calcEvaluate(src) {
    var tokens = calcTokenize(src)
    if (!tokens || tokens.length === 0) return null
    var pos = 0
    var parenDepth = 0

    function peek() { return pos < tokens.length ? tokens[pos] : null }
    function take() { return pos < tokens.length ? tokens[pos++] : null }
    function isOp(t, op) { return t && t.type === op }

    var functions = ({
      sqrt: Math.sqrt, abs: Math.abs, sin: Math.sin, cos: Math.cos,
      tan: Math.tan, asin: Math.asin, acos: Math.acos, atan: Math.atan,
      ln: Math.log, log: Math.log10, exp: Math.exp, floor: Math.floor,
      ceil: Math.ceil, round: Math.round, min: Math.min, max: Math.max
    })
    var constants = ({ pi: Math.PI, e: Math.E, tau: 2 * Math.PI })

    function parseAdd() {
      var v = parseMul()
      if (v === null) return null
      while (isOp(peek(), "+") || isOp(peek(), "-")) {
        var op = take().type
        var r = parseMul()
        if (r === null) return null
        v = op === "+" ? v + r : v - r
      }
      return v
    }
    function parseMul() {
      var v = parseUnary()
      if (v === null) return null
      while (isOp(peek(), "*") || isOp(peek(), "/") || isOp(peek(), "%")) {
        var op = take().type
        var r = parseUnary()
        if (r === null) return null
        v = op === "*" ? v * r : (op === "/" ? v / r : v % r)
      }
      return v
    }
    function parseUnary() {
      if (isOp(peek(), "-")) { take(); var v = parseUnary(); return v === null ? null : -v }
      if (isOp(peek(), "+")) { take(); return parseUnary() }
      return parsePow()
    }
    function parsePow() {
      var base = parseAtom()
      if (base === null) return null
      if (isOp(peek(), "^")) {
        take()
        var exponent = parseUnary()
        if (exponent === null) return null
        return Math.pow(base, exponent)
      }
      return base
    }
    function parseAtom() {
      var t = take()
      if (!t) return null
      if (t.type === "num") return t.value
      if (t.type === "(") {
        // Depth budget: every level costs several stack frames, and a
        // multi-kilobyte "((((…" used to be able to overflow the JS stack
        // straight through rebuildDisplay. 64 is far beyond any real
        // expression; deeper input simply fails to "no answer".
        parenDepth += 1
        if (parenDepth > 64) return null
        var v = parseAdd()
        parenDepth -= 1
        if (v === null || !isOp(take(), ")")) return null
        return v
      }
      if (t.type === "id") {
        var name = String(t.value).toLowerCase()
        if (isOp(peek(), "(")) {
          take()
          var args = []
          if (!isOp(peek(), ")")) {
            var first = parseAdd()
            if (first === null) return null
            args.push(first)
            while (isOp(peek(), ",")) {
              take()
              var nextArg = parseAdd()
              if (nextArg === null) return null
              args.push(nextArg)
            }
          }
          if (!isOp(take(), ")")) return null
          var fn = functions[name]
          if (!fn) return null
          var result = fn.apply(null, args)
          return isFinite(result) ? result : null
        }
        var constant = constants[name]
        return constant !== undefined ? constant : null
      }
      return null
    }

    var out = parseAdd()
    if (out === null || pos !== tokens.length) return null
    return isFinite(out) ? out : null
  }

  function calcFormat(value) {
    if (value === null || !isFinite(value)) return ""
    if (Math.abs(value) < 1e21 && Math.round(value) === value) return String(value)
    return String(Number(value.toPrecision(12)))
  }

  // ---- Shared answer classification ---------------------
  // ONE policy, stated once: an explicit leading "=" is calc-EXCLUSIVE
  // (suppresses fd/web/windows/content); every auto-detected class coexists
  // with ALL tiers — including windows. The classes are mutually exclusive
  // by construction, so exactly one answer row can ever show.
  // NOTE: / inside a character class is legal ECMAScript (live-verified).
  function calcCandidate(query) {
    var q = String(query || "").trim()
    if (!q) return ""
    if (q.charAt(0) === "=") return q.substring(1).trim()
    // A date is not arithmetic. "2026-10-21" has a digit and a "-", so the
    // auto-detect used to accept it — and the calculator then read it as
    // 2026 - 10 - 21 and answered 1995, with the answer row claiming it.
    // Year-first (2026-10-21, 2026/10/21, 2026.10.21) and year-last
    // (10-21-2026) shapes are rejected before the calculator sees them; an
    // explicit "=" still computes them, because the user asked for it.
    if (/^\d{4}[-/.]\d{1,2}(?:[-/.]\d{1,2})?$/.test(q)) return ""
    if (/^\d{1,2}[-/.]\d{1,2}[-/.]\d{4}$/.test(q)) return ""
    if (/[0-9]/.test(q) && /[+\-*/%^(]/.test(q)) return q
    return ""
  }

  // "" = normal. "forced" = leading "=" (calc-exclusive, EVEN IF IT FAILS TO
  // PARSE — "=hello" must not run fd on the literal or grow a web row).
  // "calc" = auto-detected math that parses (coexists with all tiers);
  // "conv", "color" and "date" coexist the same way, and the classes are
  // mutually exclusive by construction, so exactly one answer row can show.
  //
  // ONE pass answers all of it: the caller gets the mode plus the answer it
  // already computed, instead of every consumer re-running the parser. The
  // result is memoised per query text — the async tiers each ask "is this
  // forced?", then the rebuild asks again for the row; all of them read this.
  property string classifiedQuery: ""
  property var classifiedResult: null

  function classifyQuery(query) {
    var q = String(query || "").trim()
    if (root.classifiedResult !== null && root.classifiedQuery === q) return root.classifiedResult

    var out = { mode: "", calcExpr: "", calcValue: null, conv: "", color: null }
    if (q) {
      if (q.charAt(0) === "=") {
        // Forced still computes: "=2+2" must SHOW its answer (Enter copies it);
        // only the other tiers are suppressed. "=hello" parses to nothing and
        // stays answer-free — which is what keeps fd/web off the literal.
        out.mode = "forced"
        var forcedExpr = root.calcCandidate(q)
        // Belt and braces over the depth budget: a throw must never escape the
        // classification into a rebuild — "no answer" is the failure mode.
        var forcedValue = null
        try { forcedValue = forcedExpr ? root.calcEvaluate(forcedExpr) : null } catch (e) { forcedValue = null }
        if (forcedValue !== null) { out.calcExpr = forcedExpr; out.calcValue = forcedValue }
      } else {
        var expr = root.calcCandidate(q)
        var value = null
        try { value = expr ? root.calcEvaluate(expr) : null } catch (e) { value = null }
        var conv = root.convertCandidate(q)
        var color = root.colorAnswers ? root.colorCandidate(q) : null
        if (value !== null) { out.mode = "calc"; out.calcExpr = expr; out.calcValue = value }
        else if (conv !== "") { out.mode = "conv"; out.conv = conv }
        else if (color) { out.mode = "color"; out.color = color }
        else if (root.isDateTimeQuery(q)) out.mode = "date"
      }
    }

    root.classifiedQuery = q
    root.classifiedResult = out
    return out
  }

  // The cheap "is this query an answer at all?" the async tiers gate on. It now
  // shares the single classification rather than restating the policy.
  function answerQuery(query) {
    return root.classifyQuery(query).mode
  }

  // Flipping the colour tier changes the answer set — drop the memo.
  onColorAnswersChanged: root.classifiedResult = null

  // ---- Color answers (pure JS) ---------------------------
  // "#rgb", "#rgba", "#rrggbb" and "#rrggbbaa" (any case) answer with the
  // rgb() and hsl() spellings; Enter copies the normalized hex.
  function colorCandidate(query) {
    var q = String(query || "").trim()
    var m = /^#([0-9a-fA-F]{3,8})$/.exec(q)
    if (!m) return null
    var hex = m[1]
    if (hex.length !== 3 && hex.length !== 4 && hex.length !== 6 && hex.length !== 8) return null
    if (hex.length <= 4) hex = hex.replace(/./g, function(c) { return c + c })
    return {
      hex: "#" + hex.toLowerCase(),
      r: parseInt(hex.substring(0, 2), 16),
      g: parseInt(hex.substring(2, 4), 16),
      b: parseInt(hex.substring(4, 6), 16),
      a: hex.length === 8 ? parseInt(hex.substring(6, 8), 16) / 255 : 1,
      // The query spelled an alpha channel, so the detail keeps spelling it even
      // when it works out to 1 (#ffffffff is not #ffffff).
      hasAlpha: hex.length === 8
    }
  }

  // QColor — and therefore a QML `color` property — reads an 8-digit hex string
  // as #AARRGGBB (Qt's own order, not CSS's), and rejects 4-digit shorthand
  // outright. Painting a swatch from the hex string therefore shows the wrong
  // colour (opaque navy for "#ff000080", nothing at all for "#f008"), so the
  // chip is built from components instead.
  function hexToColor(hex) {
    var h = String(hex || "").replace("#", "")
    // Shorthand covers both #rgb and #rgba — expanding only the 3-digit form
    // leaves every #rgba query with no chip at all.
    if (h.length === 3 || h.length === 4) h = h.replace(/./g, function(c) { return c + c })
    if (h.length !== 6 && h.length !== 8) return "transparent"
    return Qt.rgba(parseInt(h.substring(0, 2), 16) / 255,
                   parseInt(h.substring(2, 4), 16) / 255,
                   parseInt(h.substring(4, 6), 16) / 255,
                   h.length === 8 ? parseInt(h.substring(6, 8), 16) / 255 : 1)
  }

  // rgb(255,0,0)  ·  hsl(0,100%,50%) — the CSS spellings, alpha spelled out
  // whenever the query carried one.
  function colorDetail(color) {
    var rgb = "rgb(" + color.r + "," + color.g + "," + color.b + ")"
    if (color.hasAlpha)
      rgb = "rgba(" + color.r + "," + color.g + "," + color.b + ","
        + Math.round(color.a * 100) / 100 + ")"

    var r = color.r / 255, g = color.g / 255, b = color.b / 255
    var max = Math.max(r, g, b), min = Math.min(r, g, b)
    var l = (max + min) / 2
    var h = 0, s = 0
    if (max !== min) {
      var d = max - min
      s = l > 0.5 ? d / (2 - max - min) : d / (max + min)
      if (max === r) h = (g - b) / d + (g < b ? 6 : 0)
      else if (max === g) h = (b - r) / d + 2
      else h = (r - g) / d + 4
      h = h / 6
    }

    return rgb + "  ·  hsl(" + Math.round(h * 360) + "," + Math.round(s * 100) + "%,"
      + Math.round(l * 100) + "%)"
  }

  // ---- Unit converter (pure JS) --------------------
  // ONE merged byte table (SI and IEC keys together — "1 gb in mib" is
  // well-defined and must convert). Every category checks that BOTH units
  // belong to it; a cross-category pair converts nothing. "b" is BYTES only
  // (no bits). Speed has no "ms" — milliseconds already own it in time.
  readonly property var unitTables: ({
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
  readonly property var unitAliases: ({
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
    celsius: "c", fahrenheit: "f", kelvin: "k", "°c": "c", "°f": "f", "°k": "k"
  })

  function normalizeUnit(token) {
    var u = String(token || "")
    if (u === "km/h") u = "kmh"
    else if (u === "m/s") u = "mps"
    var alias = root.unitAliases[u]
    return alias || u
  }

  function unitCategory(unit) {
    for (var category in root.unitTables) {
      if (root.unitTables[category].hasOwnProperty(unit)) return category
    }
    return ""
  }

  // "" = not a conversion. Returns the query's own unit spellings so the row
  // detail reads back what was typed.
  function convertCandidate(query) {
    var q = String(query || "").trim().toLowerCase()
    if (!q) return ""
    // Sign and exponent are part of a number, not a typo: "-10 c in f" is the
    // case a temperature converter exists for, and "1e9 b in gb" is how byte
    // counts are usually written. The captured text stays verbatim so the row
    // can read back exactly what was typed.
    var m = /^([+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)\s*([a-z°µ/]+)\s+(?:in|to|en|as)\s+([a-z°µ/]+)$/.exec(q)
    if (!m) return ""
    var value = Number(m[1])
    if (!isFinite(value)) return ""
    var from = root.normalizeUnit(m[2])
    var to = root.normalizeUnit(m[3])
    var catFrom = root.unitCategory(from)
    var catTo = root.unitCategory(to)
    if (!catFrom || !catTo || catFrom !== catTo) return ""
    var result
    if (catFrom === "temp") {
      var celsius = from === "c" ? value : (from === "f" ? (value - 32) * 5 / 9 : value - 273.15)
      result = to === "c" ? celsius : (to === "f" ? celsius * 9 / 5 + 32 : celsius + 273.15)
    } else {
      var table = root.unitTables[catFrom]
      result = value * table[from] / table[to]
    }
    if (!isFinite(result)) return ""
    return { value: result, fromValue: m[1], fromText: m[2], toText: m[3] }
  }

  // Date/time answers ("date", "today", "time", "now", "heure") share the
  // calculator's answer slot — Enter copies what is shown.
  function isDateTimeQuery(query) {
    var lower = String(query || "").trim().toLowerCase()
    return lower === "date" || lower === "today" || lower === "time"
      || lower === "now" || lower === "heure"
  }

  // ---- Baloo content tier ---------------------
  // baloosearch6 answers in ~20 ms against the live index; a no-match is
  // empty stdout + exit 0. Same pending pattern as the fd and window runs.
  function startContentSearch() {
    var query = root.filterText.trim()
    if (!root.opened || root.dmenuActive || root.browseRoot || query.length < 2
        || root.answerQuery(query) === "forced") return
    // A missing baloosearch6 is already known: skip the spawn the watchdog
    // would otherwise have to clean up on every keystroke.
    if (root.binaries.baloo === false) return
    if (contentProc.running) { root.contentSearchPending = query; return }
    root.launchContentSearch(query)
  }

  function launchContentSearch(query) {
    contentProc.collected = ""
    contentProc.query = query
    // -l 24, not 8: -l 8 starves after dedupe (live-measured: 8 → 2 unique
    // paths, 24 → 6); final rows cap at 8 in contentRowsFor.
    contentProc.command = ["/usr/bin/baloosearch6", "-l", "24", query]
    contentProc.running = true
    contentWatchdog.restart()
  }

  // Baloo's index lags moves and deletes — a stale hit used to rank a dead
  // path. Rows are capped at 8, so one tiny existence check settles them
  // before anything is shown (same protocol as the recents liveness pass).
  function launchContentLiveness(rows, query) {
    var paths = []
    for (var i = 0; i < rows.length; i++) paths.push(rows[i].target)
    contentLivenessProc.collected = ""
    contentLivenessProc.pendingRows = rows
    contentLivenessProc.query = query
    contentLivenessProc.command = ["/usr/bin/bash", "-c",
      'for p in "$@"; do if [[ -e "$p" ]]; then printf "f%s\\n" "$p"; fi; done',
      "bash"].concat(paths)
    contentLivenessProc.running = true
    contentLivenessWatchdog.restart()
  }

  function contentRowsFor(raw) {
    var lines = String(raw || "").split("\n")
    var rows = []
    var seen = ({})
    for (var i = 0; i < lines.length && rows.length < 8; i++) {
      var path = lines[i].trim()
      if (!path || path.charAt(0) !== "/") continue
      // baloosearch6 can list a directory with a trailing slash; strip it or
      // the basename parses empty and the row is silently dropped.
      if (path.length > 1 && path.charAt(path.length - 1) === "/") path = path.slice(0, -1)
      if (seen[path]) continue
      seen[path] = true
      var slash = path.lastIndexOf("/")
      var name = slash >= 0 ? path.substring(slash + 1) : path
      if (!name) continue
      var dirPart = slash > 0 ? path.substring(0, slash) : "/"
      var home = Quickshell.env("HOME")
      // Prefix AND boundary, like fileRowFor/shortPath/dirPartFor: a Baloo hit
      // under /home/ravi2 must not display as ~2/...
      if (dirPart.indexOf(home) === 0 && (dirPart.length === home.length || dirPart.charAt(home.length) === "/"))
        dirPart = "~" + dirPart.substring(home.length)
      rows.push(root.actionRow("file", root.fileGlyphFor(name, false), name,
        root.pathDetail("content", dirPart), path, 31000, "", ""))
    }
    return rows
  }

  // ---- Recent documents + Dolphin places ---------------------
  // Both sources are trusted local files but parsed by pure regex attribute
  // extraction only — no XML engine, no DOCTYPE/ENTITY processing anywhere.
  // XML-unescape the href BEFORE percent-decoding (17 of ~300 hrefs carry
  // entities; decoding first would corrupt them into dead paths).
  // fromCodePoint THROWS above 0x10FFFF (a corrupted or hostile ref like
  // &#x110000;), and a lone surrogate is not a character any path can hold —
  // through parseRecents' per-entry catch a throw would drop the whole entry.
  // Drop just the entity instead.
  function xmlCodePoint(cp) {
    if (!isFinite(cp) || cp < 0 || cp > 0x10FFFF
        || (cp >= 0xD800 && cp <= 0xDFFF)) return ""
    return String.fromCodePoint(cp)
  }

  // ONE pass: every entity — numeric (&#xE9; / &#233;) and the named five —
  // decodes exactly once. A sequential chain re-scans its own output and
  // double-decodes (&#x26;lt; corrupted to "<" by the &lt; pass; &amp;lt;
  // eaten by an early &amp;) — a single alternation never rescans.
  function unescapeXml(value) {
    return String(value).replace(
      /&#x([0-9a-fA-F]+);|&#([0-9]+);|&lt;|&gt;|&quot;|&apos;|&amp;/g,
      function(entity, hex, dec) {
        if (hex !== undefined) return root.xmlCodePoint(parseInt(hex, 16))
        if (dec !== undefined) return root.xmlCodePoint(parseInt(dec, 10))
        if (entity === "&amp;") return "&"
        if (entity === "&lt;") return "<"
        if (entity === "&gt;") return ">"
        if (entity === "&quot;") return "\""
        return "'"
      })
  }

  function dirPartFor(path) {
    var slash = path.lastIndexOf("/")
    var dirPart = slash > 0 ? path.substring(0, slash) : "/"
    var home = Quickshell.env("HOME")
    if (dirPart.indexOf(home) === 0 && (dirPart.length === home.length || dirPart.charAt(home.length) === "/"))
      dirPart = "~" + dirPart.substring(home.length)
    return dirPart
  }

  function parseRecents(raw) {
    var entries = []
    var re = /<bookmark\b[^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/bookmark>/g
    var match
    while ((match = re.exec(String(raw || ""))) !== null) {
      try {
        var href = root.unescapeXml(match[1])
        if (href.indexOf("file://") !== 0) continue
        var path = decodeURIComponent(href.substring(7))
        if (!path || path.indexOf("/Trash/") >= 0) continue
        // The liveness report is a line protocol — a newline inside a path
        // would corrupt it into junk keys, so such entries are dropped.
        if (path.indexOf("\n") >= 0) continue
        var slash = path.lastIndexOf("/")
        var name = slash >= 0 ? path.substring(slash + 1) : path
        if (!name) continue
        var titleMatch = /<title>([\s\S]*?)<\/title>/.exec(match[2])
        // `modified` lives in the opening tag — the full match can contain
        // other timestamps in the metadata children.
        var openingTag = match[0].substring(0, match[0].indexOf(">") + 1)
        var modifiedMatch = /modified="([^"]*)"/.exec(openingTag)
        entries.push({
          path: path, name: name,
          title: titleMatch ? root.unescapeXml(titleMatch[1].trim()) : "",
          dirPart: root.dirPartFor(path),
          modified: modifiedMatch ? modifiedMatch[1] : ""
        })
      } catch (e) { }
    }
    // File order is NOT chronological — this sort is load-bearing (newest
    // first wins the top slots).
    entries.sort(function(a, b) {
      if (a.modified === b.modified) return 0
      return a.modified < b.modified ? 1 : -1
    })
    return entries
  }

  function parsePlaces(raw) {
    var entries = []
    var re = /<bookmark\b[^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/bookmark>/g
    var match
    while ((match = re.exec(String(raw || ""))) !== null) {
      try {
        var href = root.unescapeXml(match[1])
        if (href.indexOf("file://") !== 0) continue
        var path = decodeURIComponent(href.substring(7))
        if (!path || path.indexOf("/Trash/") >= 0) continue
        if (path.indexOf("\n") >= 0) continue
        var slash = path.lastIndexOf("/")
        var name = slash >= 0 ? path.substring(slash + 1) : path
        if (!name) continue
        // Places titles live in the <title> child — a basename fallback
        // would show "ravi" for Home.
        var titleMatch = /<title>([\s\S]*?)<\/title>/.exec(match[2])
        entries.push({
          path: path, name: name,
          title: titleMatch ? root.unescapeXml(titleMatch[1].trim()) : "",
          dirPart: root.dirPartFor(path)
        })
      } catch (e) { }
    }
    return entries
  }

  // GTK bookmarks — the sidebar Nautilus (Omarchy's file manager), Thunar and
  // the GTK file chooser all share, and the only places file a non-KDE machine
  // has. Plain text, one entry per line: "URI[ Label]", the URI percent-encoded
  // and the label (which may contain spaces) optional. GTK keeps it at
  // gtk-3.0/bookmarks even in GTK4, so one path covers both.
  function parseGtkBookmarks(raw) {
    var lines = String(raw || "").split("\n")
    var entries = []
    var seen = ({})
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (!line || line.charAt(0) === "#") continue
      var space = line.indexOf(" ")
      var uri = space >= 0 ? line.substring(0, space) : line
      var title = space >= 0 ? line.substring(space + 1).trim() : ""
      // Only local paths: an smb:// or mtp:// place has no fd-browsable path.
      if (uri.indexOf("file://") !== 0) continue
      var path = ""
      try { path = decodeURIComponent(uri.substring(7)) } catch (e) { continue }
      // A bookmarked folder is written with or without the trailing slash;
      // strip it or the basename parses as empty and the entry is dropped.
      if (path.length > 1 && path.charAt(path.length - 1) === "/") path = path.slice(0, -1)
      if (!path || path.indexOf("\n") >= 0 || seen[path]) continue
      var slash = path.lastIndexOf("/")
      var name = slash >= 0 ? path.substring(slash + 1) : path
      if (!name) continue
      seen[path] = true
      entries.push({
        path: path, name: name, title: title, dirPart: root.dirPartFor(path)
      })
    }
    return entries
  }

  // Dolphin places and GTK bookmarks are two sources for ONE tier, and either
  // file may be missing, so both are held raw and merged whenever either lands.
  function mergePlacesEntries() {
    root.placesEntries = root.parsePlaces(root.placesXbelRaw)
      .concat(root.parseGtkBookmarks(root.gtkBookmarksRaw))
  }


  // Recents (≤5, newest first) then places (≤3), matched on title or
  // basename, only paths the liveness pass proved exist. Until that pass
  // lands, NO recent rows are shown — never a dead one.
  // The block's order is POSITIONAL, not score-driven: a match that PREFIXES
  // the label or the basename claims the limited slots first ("log" leads
  // with log.md, not service-logout.oga); substring-only matches fill what is
  // left. rebuildDisplay concatenates the blocks as-is — each fd block sorts
  // within itself and no cross-block score comparison ever happens — so band
  // values here would be dead data, and the block itself simply leads the
  // file tier whenever this tier is on.
  function recentBandRows(entries, limit, lower, seen) {
    var leads = []
    var subs = []
    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i]
      if (!root.recentsLive[entry.path]) continue
      if (seen[entry.path]) continue
      var label = entry.title || entry.name
      var lowerLabel = label.toLowerCase()
      var lowerName = entry.name.toLowerCase()
      if (lower && lowerLabel.indexOf(lower) < 0 && lowerName.indexOf(lower) < 0) continue
      seen[entry.path] = true
      // A recent/place entry can be a folder too: it says so in its detail and
      // Right-arrow browses it like any other folder row.
      var isFolder = root.liveDirs[entry.path] === true
      var row = root.actionRow("file",
        root.fileGlyphFor(entry.name, isFolder),
        label, root.pathDetail(isFolder ? "folder" : "file", entry.dirPart), entry.path, 0, "", "")
      row.isFolder = isFolder
      if (!lower || lowerLabel.indexOf(lower) === 0 || lowerName.indexOf(lower) === 0) {
        if (leads.length < limit) leads.push(row)
      } else if (subs.length < limit) {
        subs.push(row)
      }
    }
    for (var s = 0; s < subs.length && leads.length < limit; s++) leads.push(subs[s])
    return leads
  }

  function recentPlaceRows(query) {
    if (!root.recentsLanded) return []
    var lower = String(query || "").toLowerCase()
    var seen = ({})
    return root.recentBandRows(root.recentsEntries, 5, lower, seen)
      .concat(root.recentBandRows(root.placesEntries, 3, lower, seen))
  }

  function refreshRecentSources() {
    if (!root.showRecentRows) return
    recentsFile.reload()
    placesFile.reload()
    gtkBookmarksFile.reload()
    // All three reloads land within milliseconds; one liveness pass covers them.
    recentsSyncTimer.restart()
  }

  function startLivenessCheck() {
    // The pass exists only for the recents/places tier: with that off there is
    // nothing to verify, so no subprocess is spawned either.
    if (!root.showRecentRows) return
    if (livenessProc.running) { root.livenessPending = true; return }
    var paths = []
    var seen = ({})
    // recentsEntries is modified-DESC sorted — the cap keeps the newest.
    var recents = root.recentsEntries.length > 400 ? root.recentsEntries.slice(0, 400) : root.recentsEntries
    for (var i = 0; i < recents.length; i++) {
      if (!seen[recents[i].path]) { seen[recents[i].path] = true; paths.push(recents[i].path) }
    }
    for (var p = 0; p < root.placesEntries.length; p++) {
      if (!seen[root.placesEntries[p].path]) {
        seen[root.placesEntries[p].path] = true
        paths.push(root.placesEntries[p].path)
      }
    }
    if (paths.length === 0) {
      root.recentsLive = ({})
      root.liveDirs = ({})
      root.recentsLanded = true
      if (root.opened && !root.dmenuActive) root.rebuildDisplay()
      return
    }
    // ≤400 paths ≈ 24 KB argv, safe. The d/f prefix doubles as the dir flag
    // for row glyphs.
    livenessProc.collected = ""
    livenessProc.command = ["/usr/bin/bash", "-c",
      'for p in "$@"; do if [[ -d "$p" ]]; then printf "d%s\\n" "$p"; elif [[ -e "$p" ]]; then printf "f%s\\n" "$p"; fi; done',
      "bash"].concat(paths)
    livenessProc.running = true
    livenessWatchdog.restart()
  }

  // Frecency hit count for a key (files: absolute path; windows:
  // "class:" + class), capped — a frequently opened item can only ever
  // outrank, never dominate. 0 until the state file has been adopted.
  function frecencyCount(key) {
    if (!root.frecencyLoaded) return 0
    var rec = root.frecency[key]
    if (!rec || !rec.c) return 0
    // Decay on read: no schema change, and an old binge fades instead of pinning
    // a row to the top forever. rec.t is Date.now() at the last recorded hit.
    var age = Date.now() - (rec.t || 0)
    var hits = age > 0 ? rec.c * Math.pow(0.5, age / root.frecencyHalfLifeMs) : rec.c
    return Math.min(hits, 10)
  }

  // Rounded, so the boost stays on the same 25-point grid the ranking was tuned
  // around — that grid is what keeps a favourite inside its own score band.
  function frecencyBoost(key) {
    return Math.round(root.frecencyCount(key) * 25)
  }

  // FileView semantics (live-verified): a MISSING path fires ONLY
  // onLoadFailed — the gate must open on BOTH signals or frecency never
  // records on a fresh machine.
  function adoptFrecency(raw) {
    // Only records shaped {c: number, t: number} may enter. recordFrecency's
    // eviction sort and frecencyCount's decay dereference every value blind,
    // and recordFrecency runs BEFORE openPath on Enter — one null in a
    // hand-edited or crashed-mid-write state file would otherwise throw there
    // and swallow the open with the menu already closed.
    var next = ({})
    var parsed = null
    try { parsed = JSON.parse(raw || "{}") } catch (e) { parsed = null }
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
      for (var key in parsed) {
        var rec = parsed[key]
        if (!rec || typeof rec !== "object") continue
        var c = Number(rec.c)
        if (!isFinite(c) || c < 0) continue
        var t = Number(rec.t)
        next[key] = { c: c, t: isFinite(t) ? t : 0 }
      }
    }
    root.frecency = next
    root.frecencyLoaded = true
  }

  // No-op until frecencyLoaded — a pre-load activation would otherwise write
  // {} over history. setText creates the file AND parent dirs; no shell, no
  // quoting.
  function recordFrecency(key) {
    if (!root.frecencyLoaded || !key) return
    var next = ({})
    for (var existing in root.frecency) next[existing] = root.frecency[existing]
    var rec = next[key] || { c: 0, t: 0 }
    next[key] = { c: (rec.c || 0) + 1, t: Date.now() }
    var keys = Object.keys(next)
    if (keys.length > 300) {
      keys.sort(function(x, y) { return (next[x].t || 0) - (next[y].t || 0) })
      while (keys.length > 300) delete next[keys.shift()]
    }
    root.frecency = next
    frecencyFile.setText(JSON.stringify(next))
  }

  // ---- Open-windows tier ---------------------
  // hyprctl clients -j runs per search keystroke (same debounce as fd).
  // Focus happens through the ravi-window-focus wrapper: Wave-7 lua
  // dispatch only — legacy focuswindow text parse-errors, and a missing
  // window returns rc=0 with a warning, so the script matches the "ok"
  // string instead of exit codes.
  function startWindowSearch() {
    var query = root.filterText.trim()
    if (!root.opened || root.dmenuActive || root.browseRoot || query.length < 2
        || root.answerQuery(query) === "forced") return
    if (root.binaries.hyprctl === false) return
    // Rows whose Enter can only be a silent no-op are worse than none: without
    // the focus wrapper the whole tier stays off (the probe reports it).
    if (root.binaries.focus === false) return
    // Windows do not change between keystrokes: a cached answer is filtered
    // here instead of spawning hyprctl again.
    if (root.winClientsJson && (Date.now() - root.winClientsAt) < root.winClientsTtlMs) {
      if (root.opened && !root.dmenuActive) root.rebuildDisplay()
      return
    }
    if (winSearchProc.running) { root.winSearchPending = query; return }
    root.launchWindowSearch(query)
  }

  function launchWindowSearch(query) {
    winSearchProc.collected = ""
    winSearchProc.query = query
    winSearchProc.command = ["/usr/bin/hyprctl", "clients", "-j"]
    winSearchProc.running = true
    winSearchWatchdog.restart()
  }

  function windowRowsFor(raw, query) {
    var clients = []
    try { clients = JSON.parse(raw || "[]") || [] } catch (e) { clients = [] }
    var needle = String(query || "").toLowerCase()
    var candidates = []
    for (var i = 0; i < clients.length; i++) {
      var c = clients[i]
      var title = String(c.title || "")
      var cls = String(c.class || "")
      var initial = String(c.initialClass || "")
      if (title.toLowerCase().indexOf(needle) < 0
          && cls.toLowerCase().indexOf(needle) < 0
          && initial.toLowerCase().indexOf(needle) < 0) continue
      var ws = c.workspace || {}
      var wsName = String(ws.name || "")
      var wsId = Number(ws.id)
      if (!isFinite(wsId)) wsId = 0
      // Hyprland names scratchpads "special:<name>" and numbers them below zero.
      // Matching the bare word used to hide any real workspace whose name merely
      // contained it — "special-projects" is somebody's actual workspace.
      if (wsName.indexOf("special:") === 0 || wsId < 0) continue
      // The mapped field exists on this compositor (probed): an unmapped
      // client is not a window the user can go to.
      if (c.mapped === false) continue
      var address = String(c.address || "")
      if (!address) continue
      candidates.push({
        title: title, cls: cls, wsId: wsId,
        wsLabel: wsName || String(wsId), address: address
      })
    }
    // Base order: frecency-boosted classes first (decayed and capped), then
    // workspace ascending, then title alpha. The boost is computed once per
    // candidate rather than once per comparison.
    for (var bi = 0; bi < candidates.length; bi++)
      candidates[bi].boost = root.frecencyBoost("class:" + candidates[bi].cls)
    candidates.sort(function(a, b) {
      if (a.boost !== b.boost) return b.boost - a.boost
      if (a.wsId !== b.wsId) return a.wsId - b.wsId
      var titleA = a.title.toLowerCase()
      var titleB = b.title.toLowerCase()
      if (titleA !== titleB) return titleA.localeCompare(titleB)
      return a.address.localeCompare(b.address)
    })
    var rows = []
    var cap = Math.min(candidates.length, 8)
    for (var j = 0; j < cap; j++) {
      var win = candidates[j]
      rows.push(root.actionRow("window", "󰓞", win.title || win.cls,
        win.cls + "  ·  workspace " + win.wsLabel, win.address, 9000 + j, "", win.cls))
    }
    return rows
  }

  function loadProviderForMenu(id) {
    var entry = root.item(id)
    if (!entry || !entry.provider || root.providersLoaded[id]) return

    // Native providers don't touch providerProc, so they never need to queue.
    if (entry.provider === "apps") {
      root.startProviderForMenu(id)
      return
    }

    if (providerProc.running) {
      if (root.providerQueue.indexOf(id) < 0) root.providerQueue = root.providerQueue.concat([id])
      return
    }

    root.startProviderForMenu(id)
  }

  function loadProvidersForSearch() {
    var active = root.item(root.activeMenu) ? root.activeMenu : "root"

    for (var i = 0; i < root.itemOrder.length; i++) {
      var entry = root.item(root.itemOrder[i])
      if (!entry || !entry.provider || root.providersLoaded[entry.id]) continue
      if (active !== "root" && entry.id !== active && !root.isDescendantOf(entry.id, active)) continue

      root.loadProviderForMenu(entry.id)
    }
  }

  function depthFor(id) {
    return MenuModel.depthFor(root.items, id)
  }

  function pathFor(id) {
    return MenuModel.pathFor(root.items, id)
  }

  function parentPathFor(id) {
    return MenuModel.parentPathFor(root.items, id)
  }

  function isDescendantOf(id, ancestorId) {
    return MenuModel.isDescendantOf(root.items, id, ancestorId)
  }

  function childCount(id) {
    return MenuModel.childCount(root.items, root.itemOrder, id)
  }

  // Guarded items are hidden when their `when:` evaluates false. Static
  // submenus are also hidden when none of their descendants are visible;
  // provider-backed menus stay visible because their rows load on demand.
  function isVisible(entry) {
    return MenuModel.isVisible(root.items, root.itemOrder, root.whenResults, entry)
  }

  // Label with the ✓ marker baked in when `checked:` or `disabled:` evaluated
  // truthy.
  function labelFor(entry) {
    return MenuModel.labelFor(entry, root.checkedResults, root.disabledResults)
  }

  function searchableToken(value) {
    return MenuModel.searchableToken(value)
  }

  function leafIdFor(id) {
    return MenuModel.leafIdFor(id)
  }

  function nameSearchText(entry) {
    return MenuModel.nameSearchText(entry)
  }

  function termInSearchWords(term, text) {
    return MenuModel.termInSearchWords(term, text)
  }

  function descriptionTextMatches(query, text) {
    return MenuModel.descriptionTextMatches(query, text)
  }

  // Rows whose `disabled:` evaluated truthy stay listed but dimmed, and the
  // cursor steps over them.
  function isDisabled(entry) {
    return MenuModel.isDisabled(root.disabledResults, entry)
  }

  // A disabled row earns its place in the submenu it belongs to, where the
  // list around it is the point. Search is a list of what you can do, so it
  // leaves them out.
  function matchesQuery(entry, query) {
    return MenuModel.matchesQuery(entry, query, root.isVisible(entry) && !root.isDisabled(entry))
  }

  function searchScore(entry, query) {
    return MenuModel.searchScore(root.items, entry, query)
  }

  function displayRow(entry, detail, score, section) {
    var row = MenuModel.displayRow(root.items, root.itemOrder, root.checkedResults, root.disabledResults, entry, detail, score, section)
    // Every row the delegate renders carries the swatch role; menu rows never
    // use it, but a missing role breaks the binding that reads it. Menu rows
    // are never folders either.
    row.swatch = ""
    row.isFolder = false
    return row
  }

  function rowSelectable(index) {
    if (index < 0 || index >= displayModel.count) return false
    return !displayModel.get(index).disabled
  }

  // First selectable row at or past `from`, continuing in the direction of
  // travel and wrapping. -1 when every row is disabled, which leaves the menu
  // with no cursor at all rather than one parked on a row Enter won't run.
  function nextSelectable(from, direction) {
    var count = displayModel.count
    if (count === 0) return -1

    var step = direction < 0 ? -1 : 1
    var index = ((from % count) + count) % count
    for (var i = 0; i < count; i++) {
      if (root.rowSelectable(index)) return index
      index = (index + step + count) % count
    }

    return -1
  }

  // Park the cursor on a selectable row after the rows underneath it changed.
  // A menu with nothing selectable in it -- every app in it already installed
  // -- shows no cursor at all, and grows one the moment a row can take it.
  function settleCursor() {
    var target = root.nextSelectable(root.selectedIndex, 1)
    root.selectedIndex = target >= 0 ? target : 0
    root.cursorActive = target >= 0
  }

  function rebuildDmenuDisplay() {
    displayModel.clear()

    if (root.mode === "input") {
      layoutSerial += 1
      return
    }

    var query = root.filterText.trim().toLowerCase()
    for (var i = 0; i < root.dmenuOptions.length; i++) {
      // An option is "<label>", "<glyph>\t<label>", or
      // "<glyph>\t<label>\t<subtext>". The glyph never comes back with the
      // selection; the subtext renders under the label, filters alongside it,
      // and returns with the selection as a stable key for same-named rows.
      var parts = String(root.dmenuOptions[i] || "").split("\t")
      var icon = parts.length > 1 ? parts.shift() : ""
      var label = parts.shift() || ""
      var detail = parts.join("\t")
      if (query && label.toLowerCase().indexOf(query) < 0
          && detail.toLowerCase().indexOf(query) < 0) continue
      displayModel.append({
        itemId: "dmenu." + i,
        disabled: false,
        kind: "dmenu",
        icon: icon,
        iconFont: "",
        appIcon: "",
        appId: "",
        label: label,
        target: "",
        detail: detail,
        path: "",
        childCount: 0,
        action: "",
        provider: "",
        score: i,
        section: "",
        swatch: "",
        isFolder: false
      })
    }

    layoutSerial += 1

    if (displayModel.count === 0) selectedIndex = 0
    else if (selectedIndex >= displayModel.count) selectedIndex = displayModel.count - 1
    else if (selectedIndex < 0) selectedIndex = 0

    Qt.callLater(function() {
      if (displayModel.count > 0) root.revealCursor()
    })
  }

  function rebuildDisplay() {
    // A stale date row must never survive a rebuild: the tick only runs while
    // this flag is up, so every rebuild path (search, dmenu, menu) clears it
    // and only the date branch re-arms it.
    root.dateRowShowing = false
    if (root.dmenuActive) {
      root.rebuildDmenuDisplay()
      return
    }

    // Async tiers append below the cursor row, but recents can insert above it
    // — remember what the cursor is on by identity so the rebuild can re-find
    // it instead of sliding the selection onto a different row. Only a row the
    // user actually moved to is worth following: an implicit cursor (typing
    // parks it on row 0) followed by identity is how the highlight used to end
    // up on the LAST row — before fd lands, row 0 is the web-search row, and
    // that row moves to the bottom the moment results arrive.
    var anchorId = root.cursorPinned && root.cursorActive && root.selectedIndex >= 0
      && root.selectedIndex < displayModel.count ? displayModel.get(root.selectedIndex).itemId : ""

    displayModel.clear()

    if (!root.rowsLoaded) return

    var active = root.item(root.activeMenu) ? root.activeMenu : "root"
    root.activeMenu = active
    var rows = []
    var query = root.filterText.trim()
    var browsing = root.browseRoot !== ""
    // ONE classification for the whole rebuild — the answer row, the "forced"
    // gate on the file tier and the web row all read this object. Browsing is a
    // listing, not a query: no filter there is an "answer", so the object stays
    // empty and every answer decision below falls through.
    var answer = browsing
      ? ({ mode: "", calcExpr: "", calcValue: null, conv: "", color: null })
      : root.classifyQuery(query)

    if (query || browsing) {
      var matchRows = []

      // ONE matches block: app rows and menu rows sort together by score, with
      // no hairline in between. The old split ("rows of the menu you are in"
      // versus "rows from somewhere deeper") read as two unrelated groups, and
      // it left app rows in a block of their own. An app you can launch still
      // outranks a menu row of equal match — that tiebreak is what matters.
      if (!browsing) {
        for (var i = 0; i < root.itemOrder.length; i++) {
          var entry = root.item(root.itemOrder[i])
          if (!entry || entry.id === "root") continue
          if (!root.isDescendantOf(entry.id, active)) continue
          if (!root.matchesQuery(entry, query)) continue
          matchRows.push(root.displayRow(entry, root.parentPathFor(entry.id), root.searchScore(entry, query)))
        }
        matchRows.sort(function(a, b) {
          if (a.score !== b.score) return a.score - b.score
          return a.path.localeCompare(b.path)
        })
      }
      rows = matchRows

      // Windows tier: open windows matching the query sit
      // between the menu matches and the file tier. Qt sections require
      // contiguity — one contiguous block, no divider above a first row.
      // Rows come from the cached JSON and THIS query, so a failed or killed
      // hyprctl run can never leave rows that matched an older filter on
      // screen. Windows answer a search, so a folder listing leaves them out.
      // A cache older than the ceiling counts as absent (fail-closed).
      //
      // The window tier waits for a SECOND character, like the file and
      // content tiers do. It used to answer from the warm cache as soon as
      // the filter was one character long, so backing "ab" down to "a"
      // listed up to eight windows matched on a single letter.
      var winFresh = root.winClientsJson !== ""
        && (Date.now() - root.winClientsAt) < root.winClientsMaxAgeMs
      var winRows = (browsing || answer.mode === "forced" || !winFresh
        || query.length < 2 || root.binaries.focus === false)
        ? [] : root.windowRowsFor(root.winClientsJson, query)
      if (winRows.length > 0) {
        var winSection = rows.length > 0 ? "windows" : ""
        for (var wi = 0; wi < winRows.length; wi++) {
          var winRow = winRows[wi]
          rows.push(root.actionRow(winRow.kind, winRow.icon, winRow.label,
            winRow.detail, winRow.target, winRow.score, winSection, winRow.appId))
        }
      }

      // File/folder tier: recents/places lead (their own positional block at
      // the head of the tier), then folders, then files, then Baloo content hits —
      // every tier deduped by target, recents winning. The row shape mirrors
      // displayRow's output with target kept as the real path — displayRow
      // would overwrite it with itemId.
      var recents = (!root.showRecentRows || browsing || answer.mode === "forced")
        ? [] : root.recentPlaceRows(query)
      var seenTargets = ({})
      for (var rp = 0; rp < recents.length; rp++) seenTargets[recents[rp].target] = true

      var folderHits = []
      for (var di = 0; di < root.fileDirRows.length; di++) {
        if (seenTargets[root.fileDirRows[di].target]) continue
        seenTargets[root.fileDirRows[di].target] = true
        folderHits.push(root.fileDirRows[di])
      }
      var fileHits = []
      for (var fi = 0; fi < root.fileFileRows.length; fi++) {
        if (seenTargets[root.fileFileRows[fi].target]) continue
        seenTargets[root.fileFileRows[fi].target] = true
        fileHits.push(root.fileFileRows[fi])
      }
      var contentHits = []
      // Only rows that answer THIS query: a failed or killed run keeps the last
      // good set, and that set must not be shown under a newer filter.
      if (!browsing && root.contentRowsQuery === query) {
        for (var ci = 0; ci < root.fileContentRows.length; ci++) {
          if (seenTargets[root.fileContentRows[ci].target]) continue
          seenTargets[root.fileContentRows[ci].target] = true
          contentHits.push(root.fileContentRows[ci])
        }
      }

      // Effective score = stored score minus the decayed, capped frecency boost:
      // score bands are ≥1000 apart, so the maximum boost (250) can jump ~10
      // same-band ranks yet never cross a band. The boost is computed once per
      // row before the sort rather than once per comparison, and the sort returns
      // a new array so the stored hits (which live in fileDirRows and friends)
      // are never stamped with ranking state.
      var sortHits = function(hits) {
        var boosts = []
        for (var b = 0; b < hits.length; b++) boosts.push(root.frecencyBoost(hits[b].target))
        var order = []
        for (var o = 0; o < hits.length; o++) order.push(o)
        order.sort(function(x, y) {
          var effX = hits[x].score - boosts[x]
          var effY = hits[y].score - boosts[y]
          if (effX !== effY) return effX - effY
          if (hits[x].isDir !== hits[y].isDir) return hits[x].isDir ? -1 : 1
          var labelX = hits[x].label.toLowerCase()
          var labelY = hits[y].label.toLowerCase()
          if (labelX !== labelY) return labelX.localeCompare(labelY)
          return hits[x].target.localeCompare(hits[y].target)
        })
        var sorted = []
        for (var k = 0; k < order.length; k++) sorted.push(hits[order[k]])
        return sorted
      }
      folderHits = sortHits(folderHits)
      fileHits = sortHits(fileHits)
      contentHits = sortHits(contentHits)

      // The cap trims AFTER the sort, so the five that stay are the best five.
      // A block that lost rows earns a redirect row that hands the query to the
      // file manager's own search — the sixth entry, and only when there is a
      // sixth match to speak of. A browse listing is exempt from both.
      //
      // Cap and redirect are ONE decision: the cap exists to make room for the
      // redirect row. With nothing to hand the query to (a file manager that
      // cannot search from the command line, or a configured command whose
      // binary is missing) the tier is not cut at all — it falls back to the
      // pre-pack caps, so results are shown rather than silently dropped, and
      // the hint below says what is not available instead of nagging about it.
      var redirects = root.fileManagerRedirects
      var folderLimit = !browsing && root.capFileTier && redirects
        ? root.fileTierLimit : root.uncappedFolderLimit
      var fileLimit = !browsing && root.capFileTier && redirects
        ? root.fileTierLimit : root.uncappedFileLimit
      var folderTotal = folderHits.length
      var fileTotal = fileHits.length
      // fd stops at --max-results, so a block that came back exactly full may
      // have been truncated even when nothing was cut for display. That only
      // happens when the DISPLAY cap IS the fd cap — the capFileTier:false
      // mode, where the block holds 6 folders / 12 files. A full block there
      // used to be reported as an ordinary count with no hint at all, so the
      // extra matches on disk were simply not accounted for.
      var folderSaturated = !browsing && folderTotal >= root.fdResultLimit(true)
      var fileSaturated = !browsing && fileTotal >= root.fdResultLimit(false)
      var folderCut = !browsing && (folderTotal > folderLimit || folderSaturated)
      var fileCut = !browsing && (fileTotal > fileLimit || fileSaturated)
      var folderOverflow = folderCut && redirects
      var fileOverflow = fileCut && redirects
      if (folderCut) folderHits = folderHits.slice(0, folderLimit)
      if (fileCut) fileHits = fileHits.slice(0, fileLimit)
      if (!browsing && root.capFileTier && contentHits.length > root.contentTierLimit)
        contentHits = contentHits.slice(0, root.contentTierLimit)

      // Rows were cut and there is nowhere to hand the rest: the block ends
      // with a row that says how many were shown (and, when a command was
      // configured, that its binary is missing) rather than losing them
      // silently. Pushed with the block, not before it — an "out of room" row
      // that arrives before the rows it describes reads as a different tier.

      var pushHitRows = function(hits, section) {
        for (var h = 0; h < hits.length; h++) {
          var hit = hits[h]
          rows.push({
            itemId: hit.itemId,
            disabled: false,
            kind: "file",
            icon: hit.icon,
            iconFont: "",
            appIcon: "",
            appId: "",
            label: hit.label,
            target: hit.target,
            detail: hit.detail,
            path: "",
            childCount: 0,
            action: "",
            provider: "",
            score: hit.score,
            section: section,
            swatch: "",
            // fd rows carry isDir, recents carry isFolder from the liveness pass.
            isFolder: hit.isFolder === true || hit.isDir === true
          })
        }
      }

      // One section per block — the section value is what draws the hairline,
      // so folders and files only read as two blocks while the split is on. A
      // browse listing opens with its ".." row, in the folder block, and both
      // blocks then follow the split switch exactly as a search does.
      if (recents.length > 0) pushHitRows(recents, rows.length > 0 ? "files" : "")
      if (browsing || folderHits.length > 0 || folderOverflow) {
        var folderSection = browsing ? ""
          : (rows.length > 0 ? (root.separateFolderRows ? "folders" : "files") : "")
        if (browsing) rows.push(root.browseUpRow(folderSection))
        pushHitRows(folderHits, folderSection)
        if (folderOverflow) rows.push(root.moreRow("folders", query, folderSection))
        else if (folderCut) rows.push(root.hintRow("More folders matched",
          root.overflowDetail(folderTotal, folderLimit, true), folderSection))
      }
      if (fileHits.length > 0 || fileOverflow || fileCut || contentHits.length > 0) {
        var fileSection = browsing ? (root.separateFolderRows ? "files" : "")
          : (rows.length > 0 ? "files" : "")
        pushHitRows(fileHits, fileSection)
        if (fileOverflow) rows.push(root.moreRow("files", query, fileSection))
        else if (fileCut) rows.push(root.hintRow("More files matched",
          root.overflowDetail(fileTotal, fileLimit, false), fileSection))
        // Baloo hits are a different KIND of match — the query was found inside
        // the file, not in its name — so they are always their own block: the
        // hairline is what stops three of them being read as three more files
        // continuing past the "More files…" row (which is exactly what they
        // looked like sitting in the file block, unmarked, with their "· content"
        // detail elided away by a long path). `separateFolderRows` is not
        // consulted: that switch is about folders versus files — turning a
        // different tier back into an unmarked tail of the file block is not a
        // "look", it is the bug.
        pushHitRows(contentHits, rows.length > 0 ? "content" : "")
      }

      // fd caps a browse listing too, far higher than a search. A full block is
      // the only signal that the cap was reached, and saying so beats dropping
      // entries silently.
      if (browsing) {
        // fd stops at --max-results, so a block that came back exactly full is
        // indistinguishable from one that was truncated. Say "up to" instead of
        // claiming entries were dropped.
        var hitFolderCap = folderHits.length >= root.browseDirLimit
        var hitFileCap = fileHits.length >= root.browseFileLimit
        if (hitFolderCap || hitFileCap) {
          var capCount = hitFolderCap ? root.browseDirLimit : root.browseFileLimit
          var capNoun = hitFolderCap ? (capCount === 1 ? "folder" : "folders")
                                     : (capCount === 1 ? "file" : "files")
          rows.push(root.hintRow("Showing up to " + capCount + " " + capNoun,
            "Open the folder in the file manager to see everything"))
        }
      }

      // Answer row (calculator, converter, colour, date/time): "=expression"
      // answers forcibly and suppresses every other tier; auto-detected answers
      // coexist with files/windows below. Enter copies the result. `answer` is
      // this query's single classification pass — nothing here parses again.
      if (answer.mode === "calc" || (answer.mode === "forced" && answer.calcValue !== null)) {
        rows.unshift({
          itemId: "calc.result",
          disabled: false,
          kind: "calc",
          icon: "",
          iconFont: "",
          appIcon: "",
          appId: "",
          label: root.calcFormat(answer.calcValue),
          target: root.calcFormat(answer.calcValue),
          detail: (query.charAt(0) === "=" ? "= " : "") + answer.calcExpr + "  ·  Enter copies",
          path: "",
          childCount: 0,
          action: "",
          provider: "",
          score: 0,
          section: "",
          swatch: "",
          isFolder: false
        })
      } else if (answer.mode === "conv") {
        var conv = answer.conv
        rows.unshift({
          itemId: "calc.result",
          disabled: false,
          kind: "calc",
          icon: "",
          iconFont: "",
          appIcon: "",
          appId: "",
          label: root.calcFormat(conv.value) + " " + conv.toText,
          target: root.calcFormat(conv.value),
          detail: conv.fromValue + " " + conv.fromText + "  ·  Enter copies",
          path: "",
          childCount: 0,
          action: "",
          provider: "",
          score: 0,
          section: "",
          swatch: "",
          isFolder: false
        })
      } else if (answer.mode === "color") {
        // The chip shows the colour, the label is the
        // normalized hex, the detail spells out both CSS forms, Enter copies
        // the hex.
        rows.unshift({
          itemId: "color.result",
          disabled: false,
          kind: "calc",
          icon: "",
          iconFont: "",
          appIcon: "",
          appId: "",
          label: answer.color.hex,
          target: answer.color.hex,
          detail: root.colorDetail(answer.color) + "  ·  Enter copies",
          path: "",
          childCount: 0,
          action: "",
          provider: "",
          score: 0,
          section: "",
          swatch: answer.color.hex,
          isFolder: false
        })
      } else if (answer.mode === "date") {
        var timeLike = ["time", "now", "heure"].indexOf(query.trim().toLowerCase()) >= 0
        root.dateRowFormat = timeLike ? "hh:mm:ss" : "dddd, d MMMM yyyy"
        root.dateRowShowing = true
        var stamped = Qt.formatDateTime(new Date(), root.dateRowFormat)
        rows.unshift({
          itemId: "calc.result",
          disabled: false,
          kind: "calc",
          icon: "",
          iconFont: "",
          appIcon: "",
          appId: "",
          label: stamped,
          target: stamped,
          detail: "Enter copies",
          path: "",
          childCount: 0,
          action: "",
          provider: "",
          score: 0,
          section: "",
          swatch: "",
          isFolder: false
        })
      }

      // A tier whose tool is missing is silent by nature (a Process that cannot
      // start never even reports). Say so once, as a dimmed row the cursor
      // steps over, and only while searching — pushed BEFORE the web row, so
      // "web search is always last" stays true with a notice on screen. A file
      // manager with no CLI search is NOT missing software — the capped blocks
      // report that themselves (see overflowDetail), so it is not listed here.
      if (!browsing && root.binariesProbed) {
        var gone = []
        if (root.binaries.fd === false) gone.push("fd (file search)")
        if (root.binaries.hyprctl === false) gone.push("hyprctl (window switching)")
        if (root.binaries.focus === false) gone.push("ravi-window-focus (window focusing)")
        if (root.binaries.baloo === false) gone.push("baloosearch6 (content search)")
        if (root.binaries.wlpaste === false) gone.push("wl-paste (clipboard paste)")
        if (root.binaries.wlcopy === false) gone.push("wl-copy (copy actions)")
        if (root.binaries.kdeopen === false && root.binaries.gio === false
            && root.binaries.xdgopen === false) gone.push("kde-open/gio/xdg-open (opening files)")
        if (gone.length > 0) rows.push(root.hintRow("Missing: " + gone.join(", ")))
      }

      // Web-search fallback: always the last row, so a
      // query the machine can't answer is one Enter away from the browser. A
      // folder listing is not a query, so it has none.
      if (!browsing && answer.mode !== "forced" && query.length >= 2) {
        rows.push({
          itemId: "web.search",
          disabled: false,
          kind: "web",
          icon: "",
          iconFont: "",
          appIcon: "",
          appId: "",
          label: "Search the web for \u201C" + query + "\u201D",
          target: "https://duckduckgo.com/?q=" + root.safeEncodeURIComponent(query),
          detail: "DuckDuckGo",
          path: "",
          childCount: 0,
          action: "",
          provider: "",
          score: 0,
          section: rows.length > 0 ? "web" : "",
          swatch: "",
          isFolder: false
        })
      }
    } else {
      for (var j = 0; j < root.itemOrder.length; j++) {
        var child = root.item(root.itemOrder[j])
        if (!child || child.parent !== active) continue
        if (!root.isVisible(child)) continue
        rows.push(root.displayRow(child, child.description, child.order))
      }

      // DesktopEntries can reorder its values when an application starts.
      // Keep the Apps menu alphabetical independently of provider refreshes.
      if (active === "apps") {
        rows.sort(function(a, b) {
          var aLabel = String(a.label || "").toLowerCase()
          var bLabel = String(b.label || "").toLowerCase()
          if (aLabel < bLabel) return -1
          if (aLabel > bLabel) return 1
          var aId = String(a.itemId || "")
          var bId = String(b.itemId || "")
          if (aId < bId) return -1
          if (aId > bId) return 1
          return 0
        })
      }
    }

    for (var k = 0; k < rows.length; k++) displayModel.append(rows[k])
    layoutSerial += 1

    // Unpinned means the user has not chosen a row: keep the highlight on the
    // first result as the tiers land, instead of dragging it down with a row
    // that moved. A pinned cursor is re-found by identity below.
    if (!root.cursorPinned) root.selectedIndex = 0
    root.settleCursor()

    // The row the cursor sat on keeps it even when the rebuild moved it.
    if (anchorId) {
      for (var an = 0; an < displayModel.count; an++) {
        if (displayModel.get(an).itemId === anchorId) { root.selectedIndex = an; break }
      }
    }

    Qt.callLater(function() {
      if (displayModel.count > 0) root.revealCursor()
    })
  }

  // Contain alone parks the cursor row flush with the viewport edge, hiding
  // the neighbor entirely and losing the fold affordance. Keep the next
  // hidden row peeking past the cursor in the direction of travel.
  function revealCursor() {
    if (displayModel.count === 0) return
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)

    var item = resultList.itemAtIndex(root.selectedIndex)
    if (!item) return

    var reach = root.rowPeek + root.rowSpacing
    if (root.selectedIndex < displayModel.count - 1) {
      var maxY = Math.max(resultList.originY, resultList.originY + resultList.contentHeight - resultList.height)
      var overhang = item.y + item.height + reach - (resultList.contentY + resultList.height)
      if (overhang > 0) resultList.contentY = Math.min(resultList.contentY + overhang, maxY)
    }
    if (root.selectedIndex > 0) {
      var underhang = resultList.contentY - (item.y - reach)
      if (underhang > 0) resultList.contentY = Math.max(resultList.contentY - underhang, resultList.originY)
    }
  }

  // ---- Clipboard paste ----
  // Quickshell 0.2.1 has no clipboard API, so the filter is fed by wl-paste —
  // the same wl-clipboard package the copy actions already need. A clipboard
  // owner that never answers would hang the read invisibly, hence the watchdog.
  function pasteFromClipboard() {
    // dmenu prompts paste too: setFilter() rebuilds the dmenu list, so the only
    // thing the old exclusion achieved was a consumed Ctrl+V that did nothing.
    if (!root.opened) return false
    if (root.binaries.wlpaste === false) return false
    if (clipPasteProc.running) return true
    clipPasteProc.collected = ""
    // --type text/plain: without it an image clipboard hands over raw bytes,
    // which the sanitizer below would happily turn into mojibake in the
    // filter — and the README promises images paste nothing. A clipboard with
    // no text offer makes wl-paste exit non-zero, landing on the silent-return
    // path in onExited below, which is exactly that promise kept.
    clipPasteProc.command = ["/usr/bin/wl-paste", "--no-newline", "--type", "text/plain"]
    clipPasteProc.running = true
    pasteWatchdog.restart()
    return true
  }

  // A launcher filter is one line: keep the paste's first line, drop control
  // characters and cap the length, so dropping a document in cannot fill the
  // query with something unreadable — or un-deletable one keypress at a time.
  function insertPastedText(raw) {
    var text = String(raw || "")
    text = text.split("\n")[0].replace(/[\u0000-\u001f\u007f]/g, "").trim()
    if (!text) return false
    // The cap counts CODE POINTS. A UTF-16-unit cap can cut a surrogate pair
    // in half, and the lone surrogate that survives then makes the web row's
    // encodeURIComponent throw — which aborted the rebuild AFTER the row
    // model was cleared, so the list came up empty and every later keystroke
    // threw again.
    if (root.codePoints(text).length > 200) text = root.codePoints(text).slice(0, 200).join("")
    root.setFilter(root.filterText ? root.filterText + text : text)
    return true
  }

  // The characters of a string, counted by CODE POINT rather than by UTF-16
  // code unit.
  //
  // QML's JS engine splits surrogate pairs where a standard engine does not:
  // Array.from("😀").length is 2 here and 1 in V8. So a check written with
  // Array.from() refuses an emoji outright, and a cap written with
  // .length/.substring() can cut a pair in half and leave a lone surrogate —
  // which then makes encodeURIComponent() throw, aborting the rebuild with
  // the row model already cleared. This walks the string by hand so the
  // behaviour is the same in every engine.
  function codePoints(text) {
    var s = String(text || "")
    var out = []
    var i = 0
    while (i < s.length) {
      var c = s.charCodeAt(i)
      var low = i + 1 < s.length ? s.charCodeAt(i + 1) : 0
      // A high surrogate followed by a LOW surrogate is one astral character.
      // A high surrogate followed by anything else is a lone one: it stays a
      // single unit, so it is not merged with — and hidden behind — the
      // character after it.
      var step = (c >= 0xD800 && c <= 0xDBFF && low >= 0xDC00 && low <= 0xDFFF) ? 2 : 1
      out.push(s.substring(i, i + step))
      i += step
    }
    return out
  }

  // encodeURIComponent throws URIError on a lone surrogate. The filter can
  // still hold one if the clipboard handed us a broken string, so the web
  // row's URL is built defensively: a query that cannot be encoded loses only
  // the units that cannot be encoded, instead of taking the whole rebuild down
  // with it.
  function safeEncodeURIComponent(value) {
    var text = String(value === undefined || value === null ? "" : value)
    try {
      return encodeURIComponent(text)
    } catch (e) {
      // Strip only the LONE surrogates. A blanket /[\uD800-\uDFFF]/g strip
      // would also delete both halves of every valid pair, turning an emoji
      // in the same query into nothing.
      var parts = root.codePoints(text)
      var kept = []
      for (var i = 0; i < parts.length; i++) {
        var unit = parts[i].charCodeAt(0)
        if (parts[i].length === 1 && unit >= 0xD800 && unit <= 0xDFFF) continue
        kept.push(parts[i])
      }
      try {
        return encodeURIComponent(kept.join(""))
      } catch (e2) {
        // Cannot happen once the lone units are gone; a URL builder must never
        // throw, though, so the row degrades to an empty query instead.
        return ""
      }
    }
  }

  // The whole key decision tree in one callable place. Keys.onPressed cannot be
  // invoked from outside (it is a signal handler), so the handler is a two-line
  // shell around this and the tree can be exercised directly. Returns true when
  // the key was consumed. Order matters: Ctrl+Enter and Right-on-a-folder are
  // checked before the plain activate branch.
  function handleKey(key, modifiers, text) {
    var event = { key: key, modifiers: modifiers, text: text }

    if (key === Qt.Key_Delete) {
      root.requestDeleteSelected()
    } else if (key === Qt.Key_Escape) {
      if (root.filterText) root.setFilter("")
      else root.cancel()
    } else if (Util.editsFilter(event, root.filterText)) {
      root.setFilter(Util.editedFilter(event, root.filterText))
    } else if (key === Qt.Key_C && (modifiers & (Qt.ControlModifier | Qt.MetaModifier))) {
      // Ctrl+C — or Super+C, which the Hyprland bind
      // `SUPER, C, sendshortcut, , CTRL, C` delivers as Ctrl+C while the
      // launcher holds the keyboard: the keyboard twin of right-clicking a
      // file/folder row (copy the path, show the pill near the row). Dmenu
      // rows are not file rows, so the chord does nothing there — but it is
      // still consumed: there is nothing else for Ctrl+C to mean inside the
      // launcher, and an unconsumed chord leaks to the focus chain.
      root.copyHighlightedPath()
    } else if ((key === Qt.Key_V && (modifiers & (Qt.ControlModifier | Qt.MetaModifier)) !== 0)
               || (key === Qt.Key_Insert && (modifiers & Qt.ShiftModifier) !== 0)) {
      // Ctrl+V — or Shift+Insert, the classic X11 paste. The launcher has no
      // text field, so the clipboard is read and appended to the filter.
      root.pasteFromClipboard()
    } else if ((key === Qt.Key_Backspace || key === Qt.Key_Left) && !root.filterText) {
      root.goBack()
    } else if (key === Qt.Key_Up) {
      root.select(-1)
    } else if (key === Qt.Key_Down) {
      root.select(1)
    } else if (key === Qt.Key_PageUp) {
      root.select(-6)
    } else if (key === Qt.Key_PageDown) {
      root.select(6)
    } else if ((key === Qt.Key_Return || key === Qt.Key_Enter)
               && (modifiers & Qt.ControlModifier) && !root.dmenuActive
               && root.cursorActive && displayModel.count > 0) {
      // Reveal the picked file row's containing folder (secondary action);
      // any other row activates like plain Return.
      var revealRow = displayModel.get(root.selectedIndex)
      if (revealRow && revealRow.kind === "file" && revealRow.target) {
        var slashAt = revealRow.target.lastIndexOf("/")
        // Revealing is still acting on that file, so it counts exactly like
        // plain Enter does — otherwise the learning signal depends on which
        // key you happened to press.
        root.recordFrecency(revealRow.target)
        applySerial = requestSerial
        opened = false
        filterText = ""
        root.clearFileSearch()
        // Revealing opens the FOLDER that holds the row.
        root.openFolder(slashAt > 0 ? revealRow.target.substring(0, slashAt) : "/")
      } else {
        root.activateIndex(root.selectedIndex)
      }
    } else if ((key === Qt.Key_Right || key === Qt.Key_Tab || key === Qt.Key_Backtab)
               && !root.dmenuActive && root.enterHighlightedFolder()) {
      // Right or Tab on a folder row shows what is inside it — the folder
      // becomes the list, no click or second step. On anything else Right keeps
      // its old meaning (activate), handled below. Shift+Tab arrives from Qt
      // as Key_Backtab and follows the same rules.
    } else if (key === Qt.Key_Tab || key === Qt.Key_Backtab) {
      // Nothing to browse (or a dmenu): Tab is still consumed. Leaving it
      // unhandled hands it to Qt's focus traversal, which moves focus off the
      // key catcher and silently kills typing until the launcher is reopened.
      // Key_Backtab (Shift+Tab) used to match no branch at all and fall
      // through unconsumed — the same stranding, one modifier away.
    } else if (key === Qt.Key_Return || key === Qt.Key_Enter || key === Qt.Key_Right) {
      if (root.dmenuActive) {
        if (root.mode === "input") root.applyDmenuSelection(root.filterText)
        else if (displayModel.count > 0) root.activateIndex(root.cursorActive ? root.selectedIndex : 0)
      } else if (root.cursorActive) root.activateIndex(root.selectedIndex)
      else root.settleCursor()
    } else if (text && root.codePoints(text).length === 1
               && text.codePointAt(0) >= 32 && text.codePointAt(0) !== 127
               && (modifiers & (Qt.ControlModifier | Qt.MetaModifier)) === 0) {
      // Anything that is not a Ctrl/Meta shortcut types: Shift for capitals and
      // AltGr/Alt for the level-3 characters an international layout keeps there
      // (#, @, ~, brackets …), which the old No/Shift-only test silently ate.
      // Counted in CODE POINTS so a surrogate pair (emoji, one keypress on
      // some layouts) is one character, not a refused length-2 string. The
      // count uses codePoints() rather than Array.from(): in this engine
      // Array.from() splits surrogate pairs (an emoji came back as 2), so the
      // emoji was refused — and, being unhandled, it also leaked to the focus
      // chain instead of being typed.
      // Keys that produce no text (function keys, Alt+Tab) never reach here, so
      // no shortcut is hijacked. Known limitation, deliberately left: a layout
      // that delivers AltGr AS Ctrl+Alt (rather than GroupSwitchModifier) is
      // still refused, because accepting Ctrl+Alt would swallow every Ctrl+Alt
      // shortcut on layouts that do not use it for typing. On Wayland/XKB the
      // group switch arrives as GroupSwitchModifier, so this is theoretical.
      root.setFilter(root.filterText + text)
    } else {
      return false
    }
    return true
  }

  function select(delta) {
    if (displayModel.count === 0) return

    root.disarmPointer()
    var from = cursorActive ? selectedIndex + delta : (delta < 0 ? displayModel.count - 1 : 0)
    var target = root.nextSelectable(from, delta)
    if (target < 0) return

    cursorActive = true
    cursorPinned = true
    selectedIndex = target
    revealCursor()
  }

  function setFilter(nextFilter) {
    panel.freezeCardTop()
    root.filterText = nextFilter
    root.selectedIndex = 0
    root.cursorPinned = false
    root.cursorActive = root.mode !== "input"
    root.disarmPointer()
    root.requestFileSearch()
    if (!root.dmenuActive && root.filterText.trim() && !root.browseRoot) root.loadProvidersForSearch()
    root.rebuildDisplay()
  }

  function setActiveMenu(id, pushHistory, fromPointer) {
    panel.freezeCardTop()
    if (!root.item(id)) id = "root"
    if (pushHistory && id !== root.activeMenu) root.navStack = root.navStack.concat([root.activeMenu])
    root.activeMenu = id
    root.browseRoot = ""
    root.filterText = ""
    root.clearFileSearch()
    root.selectedIndex = 0
    root.cursorPinned = false
    root.cursorActive = true
    if (fromPointer) pointerGate.allowInitialSample()
    else root.disarmPointer()
    root.rebuildDisplay()
    root.invalidateVolatileProvider(id)
    root.loadProviderForMenu(id)
  }

  function goBack() {
    // In a folder, "back" means up one level; from $HOME it resumes the search.
    if (root.browseRoot) return root.browseUp()
    if (root.activeMenu === "root") return false

    if (root.navStack.length > 0) {
      var previous = root.navStack[root.navStack.length - 1]
      root.navStack = root.navStack.slice(0, root.navStack.length - 1)
      root.setActiveMenu(previous, false)
      return true
    }

    var active = root.item(root.activeMenu)
    root.setActiveMenu((active && active.parent) ? active.parent : "root", false)
    return true
  }

  function activateIndex(index, fromPointer) {
    if (root.deleteConfirmOpen) return
    if (root.dmenuActive) {
      if (root.mode === "input") {
        root.applyDmenuSelection(root.filterText)
        return
      }
      if (index < 0 || index >= displayModel.count) return
      var picked = displayModel.get(index)
      root.applyDmenuSelection(picked.detail ? picked.label + "\t" + picked.detail : picked.label)
      return
    }

    if (!root.rowSelectable(index)) return

    var row = displayModel.get(index)
    if (row.kind === "up") {
      root.browseUp()
      return
    }
    if (row.kind === "menu" || row.kind === "link") {
      root.setActiveMenu(row.target || row.itemId, true, fromPointer)
    } else if (row.kind === "app") {
      var appId = row.appId
      var label = row.label
      applySerial = requestSerial
      opened = false
      filterText = ""
      root.clearFileSearch()
      if (root.appLibrary) root.appLibrary.launch(appId, label)
    } else if (row.kind === "file") {
      applySerial = requestSerial
      opened = false
      filterText = ""
      root.clearFileSearch()
      root.recordFrecency(row.target)
      // A folder is the file manager's job; a file is the desktop's default
      // application's (see openFolder/openPath).
      if (row.isFolder === true) root.openFolder(row.target)
      else root.openPath(row.target)
    } else if (row.kind === "window") {
      // Focus runs through a Process so the outcome is observable: the
      // wrapper exits non-zero when the window is gone, and frecency only
      // records a focus that actually happened.
      var winKey = "class:" + row.appId
      if (focusProc.running) root.focusPending = { address: row.target, key: winKey }
      else root.launchWindowFocus(row.target, winKey)
      applySerial = requestSerial
      opened = false
      filterText = ""
      root.clearFileSearch()
    } else if (row.kind === "calc") {
      // Every answer copy confirms itself and the row STAYS: the pill is
      // drawn inside the card, so closing in the same breath would hide the
      // confirmation the instant it appeared. Enter again re-copies; Esc or
      // a click outside dismisses. (Maths and conversions used to copy
      // silently and close — the owner's physical pass called that a bug:
      // feedback beats silence.)
      var answerCopied = root.copyToClipboard(row.target)
      root.showToast(answerCopied
        ? (row.itemId === "color.result" ? "Color copied!" : "Copied!")
        : "wl-copy is missing — result not copied", root.rowAnchorY(index))
    } else if (row.kind === "more") {
      // The capped tier ran out of room: hand the query to the file manager.
      applySerial = requestSerial
      opened = false
      filterText = ""
      root.clearFileSearch()
      root.openFileManagerSearch(row.target)
    } else if (row.kind === "web") {
      applySerial = requestSerial
      opened = false
      filterText = ""
      root.clearFileSearch()
      // An opener that is actually installed: xdg-open first, then whatever
      // the file chain would use. A hardcoded xdg-open died silently on a
      // machine without it, and the "Missing:" notice never fired for it.
      var webOpener = root.webOpenCommand
      if (webOpener === "") {
        Util.execDetached("notify-send -u normal " + Util.shellQuote("Nothing can open the browser")
          + " " + Util.shellQuote("No opener was found (xdg-open / kde-open / gio) — install one and search again."))
      } else {
        Util.execArgv(String(webOpener).trim().split(/\s+/).concat([row.target]))
      }
    } else {
      root.applySelected(row.itemId, row.action)
    }
  }

  function requestDeleteSelected() {
    if (!root.cursorActive || root.selectedIndex < 0 || root.selectedIndex >= displayModel.count) return
    var row = displayModel.get(root.selectedIndex)
    if (!row || row.kind !== "app") return
    root.deleteTarget = { appId: row.appId, label: row.label }
    deleteConfirm.selectedIndex = 1
    root.deleteConfirmOpen = true
  }

  function cancelDelete() {
    root.deleteConfirmOpen = false
    root.deleteTarget = null
    deleteConfirm.selectedIndex = 1
    root.disarmPointer()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function confirmDelete() {
    var target = root.deleteTarget
    root.deleteConfirmOpen = false
    root.deleteTarget = null
    if (!target) return
    root.cancel()
    if (root.appLibrary) root.appLibrary.remove(target.appId, target.label)
  }

  function applyDmenuSelection(value) {
    applySerial = requestSerial
    opened = false
    filterText = ""
    root.clearFileSearch()
    root.finishRequest(value)
  }

  function applySelected(id, action) {
    if (!id) { cancel(); return }

    applySerial = requestSerial
    opened = false
    filterText = ""
    root.clearFileSearch()
    root.runAction(action)
  }

  function cancel() {
    if (root.dmenuActive) root.finishRequest(null)
    opened = false
    filterText = ""
    root.browseRoot = ""
    root.clearFileSearch()
  }

  function openExistingMenu(initialMenu) {
    requestSerial += 1
    mode = "menu"
    requestActive = false
    selectionFile = ""
    doneFile = ""
    activeMenu = root.item(initialMenu) ? initialMenu : "root"
    navStack = []
    browseRoot = ""
    filterText = ""
    // Windows may have come and gone while the launcher was closed.
    root.winClientsJson = ""
    root.winClientsAt = 0
    root.clearFileSearch()
    selectedIndex = 0
    cursorPinned = false
    cursorActive = true
    root.disarmPointer()
    root.evaluateGuards()
    // Recents/places: re-parse + re-check liveness on every open; until the
    // check lands, no recent rows are shown.
    root.recentsLanded = false
    root.refreshRecentSources()
    // A tool installed since the shell started is picked up without a restart —
    // but only re-probe when something was actually missing, so the common case
    // costs nothing, and never while a probe is already in flight.
    if (!binProbe.running && (!root.binariesProbed || root.anyTierMissing())) root.probeBinaries()
    opened = true
    rebuildDisplay()
    invalidateVolatileProvider(activeMenu)
    loadProviderForMenu(activeMenu)
    // The shell may start before first-install packages have finished placing
    // their icons. Refresh here even when the desktop entry list did not change.
    if (root.appLibrary) root.appLibrary.refreshIcons()

    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function openDmenu(payload) {
    requestSerial += 1
    mode = payload.mode === "input" ? "input" : "select"
    dmenuPrompt = String(payload.prompt || (mode === "input" ? "Input" : "Select"))
    dmenuOptions = Array.isArray(payload.options) ? payload.options : []
    selectionFile = String(payload.selectionFile || "")
    doneFile = String(payload.doneFile || "")
    requestActive = !!doneFile
    // A non-numeric width parses to NaN, which an int property stores as 0 —
    // a degenerate card. Non-numeric or absent values fall back to defaults.
    var payloadWidth = Number(payload.width)
    dmenuWidth = isFinite(payloadWidth) && payloadWidth > 0 ? Math.max(1, Math.round(payloadWidth)) : 300
    var payloadHeight = Number(payload.maxHeight)
    dmenuMaxHeight = isFinite(payloadHeight) && payloadHeight > 0 ? Math.round(payloadHeight) : 0
    activeMenu = "root"
    navStack = []
    browseRoot = ""
    filterText = ""
    root.clearFileSearch()
    selectedIndex = 0
    cursorPinned = false
    cursorActive = mode !== "input"
    root.disarmPointer()
    opened = true
    rebuildDisplay()

    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  // The capability probe runs once, at shell start.
  Component.onCompleted: {
    root.probeBinaries()
    // Opt into the overlay's post-close geometry hold, so the card's 200 ms
    // fade-out can play before the surface parks to 1x1. The hold is opt-in
    // because it keeps the surface fullscreen AND contentItem visible, which
    // would leave an opaque scrim on screen for consumers that draw one
    // without binding it to `shown` (the emoji picker, the clipboard history,
    // the reminder flow, the wifi-QR panel).
    //
    // Guarded, because in plugin mode the overlay is the STOCK one, which has
    // no hideHoldMs property: reading an unknown property yields undefined
    // (it does not throw), so the assignment is simply skipped and the
    // surface collapses immediately — the plugin's documented behaviour.
    try {
      if (panel.hideHoldMs !== undefined) panel.hideHoldMs = 280
    } catch (e) {
      // An overlay without the hold property: nothing to opt into.
    }
  }

  ListModel { id: displayModel }

  // ----------------------------------------------------------- route surface
  //
  // The menu is opened through the standard plugin lifecycle:
  // `omarchy-shell shell summon omarchy.menu '{"menu":"system"}'`.
  // Callers may pass a real id (`system`, `setup.power`) or an alias declared
  // in JSONC (`power`, `reminder-set`). Unknown strings fall through to the
  // id-as-route behavior so misspellings still attempt to open the literal id.
  function resolveRoute(input) {
    return MenuModel.resolveRoute(root.items, root.itemOrder, input)
  }

  function openRoute(initialMenu) {
    var id = root.resolveRoute(initialMenu)
    var entry = root.items[id]
    // If the resolved id is an action (i.e. the user invoked an alias for
    // a leaf, e.g. `omarchy menu summon screenrecord-stop`), run it directly
    // instead of opening an action with no children.
    if (entry && entry.kind === "action" && entry.action) {
      root.cancel()
      root.runAction(entry.action)
      return "ok"
    }
    // If it's a link (a redirect to another menu), follow the link.
    if (entry && entry.kind === "link" && entry.target) id = entry.target
    root.openExistingMenu(id)
    return "ok"
  }

  function disarmPointer() {
    pointerGate.reset()
  }

  // One clipboard sink for every copy action (Enter on an answer row, Ctrl+C
  // or right-click on a file row) — the command is configurable in one place.
  // execDetached, NOT an exit-code-checked Process: wl-copy blocks until
  // another application takes the clipboard over, so the spawn has to outlive
  // the menu — a Process would sit "running" until the next copy. What keeps
  // this honest instead is the probe: without binaries.wlcopy the callers
  // below refuse to claim success.
  function copyToClipboard(text) {
    if (!text) return false
    if (root.binariesProbed && root.binaries.wlcopy === false) return false
    Util.execDetached("printf %s " + Util.shellQuote(text) + " | " + root.clipboardCommand)
    return true
  }

  // Right-click (or Ctrl+C on the highlighted row) copies a file/folder row's
  // absolute path and confirms with a toast. Fires directly — no context menu,
  // and only file rows: apps, windows, answers, redirect and web rows do
  // nothing. `anchorY` is the row's top edge in card coordinates, so the pill
  // can sit just above the row the user acted on.
  function copyRowPath(path, anchorY) {
    if (!path) return
    var y = anchorY === undefined ? -1 : anchorY
    // A missing wl-copy must not produce a "Path copied!" lie — the pill is
    // the only feedback this action has.
    if (!root.copyToClipboard(path)) {
      root.showToast("wl-copy is missing — nothing copied", y)
      return
    }
    root.showToast("Path copied!", y)
  }

  // Card-space y of a row that is currently laid out; -1 (dock at the top of the
  // card) when it is not, which is also what a click passes when unknown.
  function rowAnchorY(index) {
    var item = resultList.itemAtIndex(index)
    return item ? item.mapToItem(card, 0, 0).y : -1
  }

  // Ctrl+C / Super+C on the highlighted row: the keyboard twin of the
  // right-click above. Returns false when the highlighted row has no path to
  // copy — the caller still consumes the chord, since there is nothing else for
  // Ctrl+C to mean inside the launcher.
  function copyHighlightedPath() {
    if (!root.cursorActive || root.selectedIndex < 0 || root.selectedIndex >= displayModel.count) return false
    var row = displayModel.get(root.selectedIndex)
    if (!row || row.kind !== "file" || !row.target) return false
    root.copyRowPath(row.target, root.rowAnchorY(root.selectedIndex))
    return true
  }

  // The confirmation pill carries no payload — the clipboard already has the
  // value, and a second line of it only made the pill harder to read. It sits
  // just above the row it confirms (a -1 anchor falls back to the top of the
  // card, for a row that is not laid out yet), never over it.
  // An OPAQUE version of the theme's translucent highlight: the pill used to be
  // `selectedBackground` (alpha 0.08) and read straight through on busy
  // backgrounds. Compositing it over the card colour keeps the same tone with
  // alpha forced to 1.
  function opaqueOver(base, overlay) {
    var a = overlay.a
    return Qt.rgba(base.r * (1 - a) + overlay.r * a,
                   base.g * (1 - a) + overlay.g * a,
                   base.b * (1 - a) + overlay.b * a, 1)
  }

  function showToast(text, anchorY) {
    root.toastText = text || "Path copied!"
    var margin = Style.space(8)
    var top = anchorY >= 0 ? anchorY - pathCopiedToast.height - margin : margin
    root.toastY = Math.max(margin, Math.min(top, card.height - pathCopiedToast.height - margin))
    pathCopiedToast.opacity = 1
    pathCopiedHide.restart()
  }

  // ---- Opening a file (Enter / Ctrl+Enter reveal) ----
  // EMPTY = AUTO: the opener belonging to the DETECTED file manager, because
  // that is the one resolver the user actually sees and configures. `xdg-open`
  // is not a safe default on a machine with KDE apps: it goes through GLib,
  // which classified a .md as text/plain and handed it to LibreOffice Writer,
  // while Dolphin/KService knew the same file as text/markdown and opened it in
  // Obsidian — one keystroke here, two different applications. kde-open IS that
  // same resolver, so the launcher and the file manager now agree. (The web row
  // is a URL, not a file, and stays on xdg-open.)
  property string fileOpenCommand: ""
  // First candidate whose binary the probe found wins. The order follows the
  // detected file manager: KDE's own opener for Dolphin, GIO for the GTK ones,
  // and the generic fallback otherwise.
  function fileOpenOrder() {
    if (root.fileManagerDetected === "dolphin") return ["kde-open", "gio open", "xdg-open"]
    if (root.fileManagerDetected === "nautilus" || root.fileManagerDetected === "thunar"
        || root.fileManagerDetected === "nemo" || root.fileManagerDetected === "pcmanfm")
      return ["gio open", "xdg-open", "kde-open"]
    return ["xdg-open", "gio open", "kde-open"]
  }
  function openerAvailable(binary) {
    // Fail open until the probe answers, like every other gate.
    if (!root.binariesProbed) return true
    var key = binary === "kde-open" ? "kdeopen" : (binary === "xdg-open" ? "xdgopen" : binary)
    return root.binaries[key] !== false
  }
  readonly property string fileOpenCommandEffective: {
    if (root.fileOpenCommand !== "") return root.fileOpenCommand
    var order = root.fileOpenOrder()
    for (var i = 0; i < order.length; i++) {
      if (root.openerAvailable(String(order[i]).split(/\s+/)[0])) return order[i]
    }
    return "xdg-open"
  }
  // The web row opens a URL, not a file. xdg-open is the right tool for a
  // URL, but it is not installed everywhere, and a row that dies silently
  // is worse than one that says why: the "Missing:" notice only fires when
  // ALL THREE openers are gone, so a lone missing xdg-open took the web
  // search row down without a word. The URL row therefore picks the first
  // opener that is actually present, xdg-open first.
  readonly property string webOpenCommand: {
    if (root.openerAvailable("xdg-open")) return "xdg-open"
    var order = root.fileOpenOrder()
    for (var i = 0; i < order.length; i++) {
      if (root.openerAvailable(String(order[i]).split(/\s+/)[0])) return order[i]
    }
    return ""
  }
  // Opens a path the way this desktop opens it. The path is an ARGUMENT, never
  // spliced into a command string, so a filename cannot be read as shell code.
  function openPath(path) {
    var target = String(path || "")
    if (!target) return
    // With no resolver at all the spawn would be a closed menu and nothing
    // else — the menu is already closed here, so a notification is the only
    // channel left.
    //
    // A CONFIGURED opener is the user's explicit choice and is exempt: it
    // works whether or not kde-open / gio / xdg-open are installed, so
    // reporting "nothing can open files" while a working opener sits in
    // fileOpenCommand was wrong — the configured command was never run.
    if (root.fileOpenCommand === "" && root.binariesProbed && root.binaries.kdeopen === false
        && root.binaries.gio === false && root.binaries.xdgopen === false) {
      Util.execDetached("notify-send -u normal " + Util.shellQuote("Nothing can open files")
        + " " + Util.shellQuote("No opener was found (kde-open / gio / xdg-open) — install one and search again."))
      return
    }
    Util.execArgv(String(root.fileOpenCommandEffective || "xdg-open").trim().split(/\s+/).concat([target]))
  }

  // A FOLDER goes straight to the detected file manager instead. "Open this
  // folder" means the file manager, and a generic resolver cannot be trusted
  // with a directory: measured here, xdg-open and gio open hand a folder to
  // Dolphin, but kde-open — which IS right for files — opens it in Gwenview,
  // because Gwenview also claims inode/directory. Only the file managers known
  // to take a path this way are used; anything else falls back to openPath. An
  // explicitly configured fileOpenCommand wins for folders too, so one setting
  // still means one behaviour.
  readonly property string folderOpenBinary: {
    var known = ["dolphin", "nautilus", "thunar", "nemo", "pcmanfm", "files"]
    return known.indexOf(root.fileManagerDetected) >= 0 ? root.fileManagerDetected : ""
  }
  function openFolder(path) {
    var target = String(path || "")
    if (!target) return
    if (root.fileOpenCommand === "" && root.folderOpenBinary) {
      Util.execArgv([root.folderOpenBinary, target])
      return
    }
    root.openPath(target)
  }

  // The capped tier's "more" rows hand the query to the file manager's own
  // search. EVERY "%1" becomes the query as a shell-INERT token — percent-
  // encoded, with the six characters encodeURIComponent still lets through
  // (' ! ( ) * ~) encoded as well, so only [A-Za-z0-9-_.%] remain. Such a
  // token is safe spliced into any quoting context (the built-in dolphin
  // command carries %1 inside its own single quotes, where a shellQuote'd
  // word would break containment and a bare ( or ) was a bash syntax error),
  // and a command with no %1 gets it as a trailing argument instead of
  // silently dropping the query — this row's whole purpose is the handover.
  function searchQueryToken(query) {
    return root.safeEncodeURIComponent(query).replace(/[!'()*~]/g, function(ch) {
      return "%" + ch.charCodeAt(0).toString(16).toUpperCase()
    })
  }

  function openFileManagerSearch(query) {
    var q = String(query || "").trim()
    if (!q || !root.fileManagerCommand) return
    var token = root.searchQueryToken(q)
    Util.execDetached(root.fileManagerCommand.indexOf("%1") >= 0
      ? root.fileManagerCommand.split("%1").join(token)
      : root.fileManagerCommand + " " + token)
  }

  // The sixth slot of a capped block. `kind` is "folders" or "files"; both hand
  // the same query to the file manager, and the label says which side ran out
  // of room.
  function moreRow(kind, query, section) {
    return {
      itemId: "more." + kind,
      disabled: false,
      kind: "more",
      icon: "",
      iconFont: "",
      appIcon: "",
      appId: "",
      label: kind === "folders" ? "More folders…" : "More files…",
      target: query,
      detail: "File manager search for \u201C" + query + "\u201D",
      path: "",
      childCount: 0,
      action: "",
      provider: "",
      score: 0,
      section: section,
      swatch: "",
      isFolder: false
    }
  }

  // Enter on a window row focuses through the wrapper Process; frecency is
  // recorded only on success, and a dead window says so via notification —
  // the menu is already closed, so an in-panel toast would never be seen.
  function launchWindowFocus(address, frecencyKey) {
    focusProc.frecencyKey = frecencyKey
    focusProc.command = [Quickshell.env("HOME") + "/.local/bin/ravi-window-focus", address]
    focusProc.running = true
    // Arm the watchdog. Without this the timer that is supposed to kill a
    // wedged focus run was never started: a hung ravi-window-focus kept the
    // single focus slot occupied, every later Enter silently overwrote the
    // one pending slot, and window focusing stayed dead until the shell was
    // restarted. Every other Process here arms its watchdog at launch.
    focusWatchdog.restart()
  }

  function selectFromPointer(index, item, mouse) {
    if (!pointerGate.moved(item, mouse)) return
    if (!root.rowSelectable(index)) return
    root.cursorActive = true
    root.cursorPinned = true
    root.selectedIndex = index
  }

  // ---- Capability probe ----
  // One `command -v` pass per shell start (see `binaries`). Without it a missing
  // binary is indistinguishable from a tier that simply found nothing: a Process
  // whose command cannot be found never even reports an exit.
  //
  // The file manager is DETECTED rather than assumed: the pack ships on Omarchy,
  // whose file manager is Nautilus, and a hardcoded `dolphin` probe made every
  // capped search end in a "dolphin is missing" nag there. The candidate names
  // arrive as ARGUMENTS, never interpolated into the script, and the first one
  // present wins (a configured command's own binary is candidate zero).
  function fileManagerProbeNames() {
    var names = []
    var custom = String(root.fileManagerSearchCommand || "").trim().split(/\s+/)[0] || ""
    if (custom) names.push(custom)
    for (var i = 0; i < root.fileManagerCandidates.length; i++) {
      var name = String(root.fileManagerCandidates[i] || "")
      if (name && names.indexOf(name) < 0) names.push(name)
    }
    return names
  }

  function probeBinaries() {
    binProbe.collected = ""
    // The answer has to describe what the TIERS do: they call absolute paths
    // (/usr/bin/fd, …), so an executable on PATH alone is not enough and an
    // absolute path with no PATH entry is. The file manager is launched by name,
    // so PATH is the right probe for it — the check covers both everywhere.
    binProbe.command = ["bash", "-c",
      // check_abs: the tier tools are spawned by ABSOLUTE path (/usr/bin/fd …),
      // so the check covers exactly that path — a /usr/sbin or PATH-only
      // install must NOT pass (the probe would green-light a tier whose every
      // spawn then fails). check: launched by name (openers, file managers),
      // so PATH is the right probe there.
      'check_abs() { if [[ -x "/usr/bin/$1" ]]; '
      + 'then echo "$2=1"; else echo "$2=0"; fi; }\n'
      + 'check() { if [[ -x "/usr/bin/$1" ]] || [[ -x "/usr/sbin/$1" ]] || command -v "$1" >/dev/null 2>&1; '
      + 'then echo "$2=1"; else echo "$2=0"; fi; }\n'
      + 'check_abs fd fd\ncheck_abs hyprctl hyprctl\ncheck_abs wl-copy wlcopy\ncheck_abs wl-paste wlpaste\n'
      + 'check_abs baloosearch6 baloo\n'
      + 'if [[ -x "$HOME/.local/bin/ravi-window-focus" ]]; then echo "focus=1"; else echo "focus=0"; fi\n'
      + 'check kde-open kdeopen\ncheck gio gio\ncheck xdg-open xdgopen\n'
      + 'fm=""\nfor candidate in "$@"; do\n'
      + '  if [[ -x "/usr/bin/$candidate" ]] || [[ -x "/usr/sbin/$candidate" ]] || command -v "$candidate" >/dev/null 2>&1; '
      + 'then fm="$candidate"; break; fi\n'
      + 'done\necho "fm=$fm"\n',
      "bash"].concat(root.fileManagerProbeNames())
    root.binProbeDropped = false
    binProbe.running = true
    binProbeWatchdog.restart()
  }

  Process {
    id: binProbe
    property string collected: ""
    stdout: SplitParser {
      onRead: function(data) { binProbe.collected += data + "\n" }
    }
    onExited: function(exitCode, exitStatus) {
      binProbeWatchdog.stop()
      // A dropped probe answered nothing: keep the fail-open defaults rather
      // than report working tools as missing.
      if (root.binProbeDropped) { root.binProbeDropped = false; return }
      // A probe that died organically answered only part of the question;
      // applying its partial output would mark working tools missing and
      // switch their tiers off. Fail open, same rule as the guard batch.
      if (exitCode !== 0 || exitStatus !== 0) {
        console.warn("[launcher] capability probe exited " + exitCode + "/" + exitStatus + " — keeping the fail-open defaults")
        return
      }
      var next = ({ fd: false, hyprctl: false, wlcopy: false, wlpaste: false,
                    baloo: false, focus: false, kdeopen: false, gio: false, xdgopen: false })
      var lines = binProbe.collected.split("\n")
      for (var i = 0; i < lines.length; i++) {
        var eq = lines[i].indexOf("=")
        if (eq <= 0) continue
        var name = lines[i].substring(0, eq)
        var value = lines[i].substring(eq + 1)
        // `fm` answers with a NAME (the first file manager found), not a 0/1:
        // the name is what picks the "more" row's command, and "" means none.
        // It is not part of `binaries` — a file manager is not a tier that goes
        // silent without it (see anyTierMissing).
        if (name === "fm") {
          root.fileManagerDetected = value
          continue
        }
        // The script already emits tier keys; the mapping is belt and braces.
        var key = name === "wl-copy" ? "wlcopy" : (name === "baloosearch6" ? "baloo" : name)
        next[key] = value === "1"
      }
      root.binaries = next
      root.binariesProbed = true
      if (root.opened) root.rebuildDisplay()
    }
  }

  // The probe is `command -v` a few times — microseconds. It gets a watchdog
  // anyway, but a dropped one must not be applied: half an answer would mark
  // working tools as missing.
  Timer {
    id: binProbeWatchdog
    interval: 4000
    onTriggered: if (binProbe.running) {
      console.warn("[launcher] capability-probe watchdog fired — keeping the fail-open defaults")
      root.binProbeDropped = true
      binProbe.running = false
    }
  }

  Process {
    id: providerProc
    property string menuId: ""
    property string providerKey: ""
    property string collected: ""
    property int revision: 0
    stdout: SplitParser {
      onRead: function(data) { providerProc.collected += data + "\n" }
    }
    onExited: {
      providerProcWatchdog.stop()
      if (providerProc.revision === root.providerRevision) {
        root.mergeProviderRows(providerProc.collected, providerProc.menuId, providerProc.providerKey)
        if (root.filterText.trim() && !root.browseRoot) root.loadProvidersForSearch()
      }
      root.startNextProvider()
    }
  }

  // A provider script that blocks (fonts or power profiles shelling out to
  // something wedged) would otherwise leave the id marked loaded forever and the
  // queue stalled behind it. Invalidating the run drops the half-read list, and
  // clearing the loaded flag lets the next visit try again.
  Timer {
    id: providerProcWatchdog
    interval: 4000
    onTriggered: if (providerProc.running) {
      console.warn("[launcher] provider watchdog fired — provider script wedged over 4s")
      root.providerRevision += 1
      root.providersLoaded[providerProc.menuId] = false
      providerProc.running = false
    }
  }

  Timer {
    id: fileSearchTimer
    interval: 180
    onTriggered: {
      root.startFileSearch()
      root.startWindowSearch()
    }
  }

  // Baloo gets its own, longer debounce: it is the slowest tier (measured
  // ~38 ms against a live index) and the least sensitive to one more keystroke.
  Timer {
    id: contentSearchTimer
    interval: 300
    onTriggered: root.startContentSearch()
  }

  Process {
    id: fileSearchProc
    property int serial: 0
    // String accumulation, not an array: in-place writes into a QML var
    // property are occasionally dropped by the engine (see MenuModel.js),
    // and a dropped search line is a silently missing result.
    property string collected: ""
    stdout: SplitParser {
      onRead: function(data) { fileSearchProc.collected += data + "\n" }
    }
    onExited: function(exitCode, exitStatus) {
      fileSearchWatchdog.stop()
      // A newer query queued mid-run preempts the chain from the top: its
      // predecessor's results are never stored and the dirs phase restarts.
      if (root.fileSearchPending) {
        var nextQuery = root.fileSearchPending
        root.fileSearchPending = ""
        root.launchFileSearch("dirs", nextQuery)
        return
      }
      if (fileSearchProc.serial !== root.fileSearchSerial) return

      var phase = root.fileSearchPhase
      var query = root.fileSearchQuery
      // Killed or failed fd: a partial walk is not an answer (the watchdog
      // route is the serial bump above; this covers every other death). Clear
      // the phase's rows rather than keep the previous query's, and do not
      // chain — the next keystroke restarts the tier clean.
      if (exitCode !== 0 || exitStatus !== 0) {
        console.warn("[launcher] fd exited " + exitCode + "/" + exitStatus + " — dropping file-search rows")
        if (phase === "dirs") root.fileDirRows = []
        else root.fileFileRows = []
        if (root.opened && !root.dmenuActive) root.rebuildDisplay()
        return
      }
      var hits = []
      var lines = fileSearchProc.collected.split("\n")
      for (var i = 0; i < lines.length; i++) {
        var row = root.fileRowFor(lines[i], phase === "dirs", query)
        if (row) hits.push(row)
      }
      if (phase === "dirs") root.fileDirRows = hits
      else root.fileFileRows = hits
      if (root.opened && !root.dmenuActive) root.rebuildDisplay()
      // Chaining stops when the menu is gone: the pending second phase has
      // nothing left to render, and the next open restarts the tier clean.
      if (phase === "dirs" && root.opened) root.launchFileSearch("files", query)
    }
  }

  // fd answers in milliseconds; four seconds means the walk is wedged — a stale
  // network mount is the usual cause, and without this every later keystroke
  // would only queue a pending query that never runs. The serial is bumped
  // before the kill so the partial output cannot land as the answer.
  Timer {
    id: fileSearchWatchdog
    interval: 4000
    onTriggered: if (fileSearchProc.running) {
      console.warn("[launcher] file-search watchdog fired — fd wedged over 4s")
      root.fileSearchSerial += 1
      fileSearchProc.running = false
    }
  }

  Process {
    id: resultProc
    onExited: {
      if (root.applySerial === root.requestSerial)
        root.opened = false
    }
  }

  Process {
    id: focusProc
    property string frecencyKey: ""
    // Set by the watchdog before its kill: a killed run verifies nothing, so
    // neither the frecency hit nor the "window not found" note may fire.
    property bool dropped: false
    onExited: function(exitCode, exitStatus) {
      focusWatchdog.stop()
      var dropped = focusProc.dropped
      focusProc.dropped = false
      if (!dropped) {
        if (exitCode === 0 && exitStatus === 0) {
          root.recordFrecency(focusProc.frecencyKey)
        } else {
          // The wrapper cannot tell a dead window from an unsupported
          // compositor dialect, and this message is the only channel the user
          // gets — so it names both instead of blaming the window.
          Util.execDetached("notify-send -u normal " + Util.shellQuote("Window not found")
            + " " + Util.shellQuote("It may have closed — or this Hyprland build lacks the lua dispatch the focus helper needs."))
        }
      }
      if (root.focusPending) {
        var next = root.focusPending
        root.focusPending = null
        root.launchWindowFocus(next.address, next.key)
      }
    }
  }

  // ravi-window-focus is one hyprctl round-trip; 4 s means something is
  // wedged. Every other Process here has this guard — without it a hung run
  // would leave the single focus slot occupied and every later Enter queued
  // in focusPending forever.
  Timer {
    id: focusWatchdog
    interval: 4000
    onTriggered: if (focusProc.running) {
      console.warn("[launcher] window-focus watchdog fired — ravi-window-focus wedged over 4s")
      focusProc.dropped = true
      focusProc.running = false
    }
  }

  Process {
    id: clipPasteProc
    property string collected: ""
    stdout: SplitParser {
      onRead: function(data) { clipPasteProc.collected += data + "\n" }
    }
    onExited: function(exitCode, exitStatus) {
      pasteWatchdog.stop()
      // A non-text clipboard (an image) or a dead owner is not an error worth
      // reporting: nothing was pasted, which is what the user sees anyway.
      if (exitCode !== 0 || exitStatus !== 0) return
      root.insertPastedText(clipPasteProc.collected)
    }
  }

  Timer {
    id: pasteWatchdog
    interval: 2000
    onTriggered: if (clipPasteProc.running) {
      console.warn("[launcher] paste watchdog fired — wl-paste did not answer in 2s")
      clipPasteProc.running = false
    }
  }

  // Re-renders an on-screen date/time answer every second, so what the row
  // shows is always what Enter will copy. Ticks only while a date answer is
  // actually displayed (see dateRowShowing) — otherwise the timer is parked.
  // repeat: true is load-bearing: without it the Timer fires ONCE per start
  // and only the rebuild storm from the async tiers landing re-arms it — the
  // clock froze after a second or two once they settled.
  Timer {
    id: dateTick
    interval: 1000
    repeat: true
    running: root.opened && root.dateRowShowing
    onTriggered: {
      for (var i = 0; i < displayModel.count; i++) {
        if (displayModel.get(i).itemId === "calc.result") {
          var stamped = Qt.formatDateTime(new Date(), root.dateRowFormat)
          displayModel.set(i, { label: stamped, target: stamped })
          break
        }
      }
    }
  }

  Process {
    id: winSearchProc
    property string collected: ""
    property string query: ""
    stdout: SplitParser {
      onRead: function(data) { winSearchProc.collected += data + "\n" }
    }
    onExited: function(exitCode, exitStatus) {
      winSearchWatchdog.stop()
      // A newer query queued mid-run relaunches from the top; the older
      // run's output is never stored.
      if (root.winSearchPending) {
        var nextQuery = root.winSearchPending
        root.winSearchPending = ""
        root.launchWindowSearch(nextQuery)
        return
      }
      if (winSearchProc.query !== root.filterText.trim()) return
      // Killed or failed: a half-read JSON dump is not an answer, and the cache
      // it would have replaced is dropped with it — a broken hyprctl must not
      // leave stale windows listed for the rest of the session.
      if (exitCode !== 0 || exitStatus !== 0) {
        root.winClientsJson = ""
        root.winClientsAt = 0
        if (root.opened && !root.dmenuActive) root.rebuildDisplay()
        return
      }
      root.winClientsJson = winSearchProc.collected
      root.winClientsAt = Date.now()
      if (root.opened && !root.dmenuActive) root.rebuildDisplay()
    }
  }

  Timer {
    id: winSearchWatchdog
    interval: 4000
    // hyprctl clients answers in milliseconds; 4 s means something is wedged.
    onTriggered: if (winSearchProc.running) {
      console.warn("[launcher] window-search watchdog fired — hyprctl clients wedged over 4s")
      winSearchProc.running = false
    }
  }

  Process {
    id: contentProc
    property string collected: ""
    property string query: ""
    stdout: SplitParser {
      onRead: function(data) { contentProc.collected += data + "\n" }
    }
    onExited: function(exitCode, exitStatus) {
      contentWatchdog.stop()
      if (root.contentSearchPending) {
        var nextQuery = root.contentSearchPending
        root.contentSearchPending = ""
        root.launchContentSearch(nextQuery)
        return
      }
      if (contentProc.query !== root.filterText.trim()) return
      // baloosearch6 exits 0 on a clean no-match; a killed run's partial
      // output must not pose as the index's answer — keep the last set.
      if (exitCode !== 0 || exitStatus !== 0) return
      var rows = root.contentRowsFor(contentProc.collected)
      if (rows.length === 0) {
        root.fileContentRows = []
        root.contentRowsQuery = contentProc.query
        if (root.opened && !root.dmenuActive) root.rebuildDisplay()
        return
      }
      if (contentLivenessProc.running) {
        contentLivenessProc.stashedRows = rows
        contentLivenessProc.stashedQuery = contentProc.query
        root.contentLivenessPending = true
        return
      }
      root.launchContentLiveness(rows, contentProc.query)
    }
  }

  Timer {
    id: contentWatchdog
    interval: 4000
    onTriggered: if (contentProc.running) {
      console.warn("[launcher] content watchdog fired — baloosearch6 wedged over 4s")
      contentProc.running = false
    }
  }

  Process {
    id: contentLivenessProc
    property string collected: ""
    property var pendingRows: []
    property var stashedRows: []
    property string stashedQuery: ""
    property string query: ""
    stdout: SplitParser {
      onRead: function(data) { contentLivenessProc.collected += data + "\n" }
    }
    onExited: function(exitCode, exitStatus) {
      contentLivenessWatchdog.stop()
      var live = ({})
      if (exitCode === 0 && exitStatus === 0) {
        var lines = contentLivenessProc.collected.split("\n")
        for (var i = 0; i < lines.length; i++) {
          if (lines[i].charAt(0) === "f") live[lines[i].substring(1)] = true
        }
      }
      // A killed check verifies nothing: show only rows the check confirmed,
      // never Baloo's possibly-stale word alone.
      var rows = []
      for (var r = 0; r < contentLivenessProc.pendingRows.length; r++) {
        if (live[contentLivenessProc.pendingRows[r].target]) rows.push(contentLivenessProc.pendingRows[r])
      }
      root.fileContentRows = rows
      root.contentRowsQuery = contentLivenessProc.query
      if (root.opened && !root.dmenuActive) root.rebuildDisplay()
      if (root.contentLivenessPending) {
        root.contentLivenessPending = false
        root.launchContentLiveness(contentLivenessProc.stashedRows, contentLivenessProc.stashedQuery)
      }
    }
  }

  Timer {
    id: contentLivenessWatchdog
    interval: 4000
    onTriggered: if (contentLivenessProc.running) {
      console.warn("[launcher] content-liveness watchdog fired — existence check wedged over 4s")
      contentLivenessProc.running = false
    }
  }

  Process {
    id: livenessProc
    property string collected: ""
    stdout: SplitParser {
      onRead: function(data) { livenessProc.collected += data + "\n" }
    }
    onExited: function(exitCode, exitStatus) {
      livenessWatchdog.stop()
      // Killed rather than finished (watchdog): a partial live set would
      // mark every unreached path dead — keep the last complete set and
      // land without rows instead. A signal leaves the exit code at 0, so
      // the status is what tells us (same rule as guardProc).
      if (exitCode !== 0 || exitStatus !== 0) {
        root.recentsLanded = true
        if (root.livenessPending) {
          root.livenessPending = false
          root.startLivenessCheck()
        }
        return
      }
      var nextLive = ({})
      var nextDirs = ({})
      var lines = livenessProc.collected.split("\n")
      for (var i = 0; i < lines.length; i++) {
        var line = lines[i]
        if (!line) continue
        if (line.charAt(0) === "d") {
          nextLive[line.substring(1)] = true
          nextDirs[line.substring(1)] = true
        } else if (line.charAt(0) === "f") {
          nextLive[line.substring(1)] = true
        }
      }
      root.recentsLive = nextLive
      root.liveDirs = nextDirs
      root.recentsLanded = true
      if (root.opened && !root.dmenuActive) root.rebuildDisplay()
      // The menu reopened while the check was running — run it again so the
      // rows match what is on screen now (a command change mid-run is
      // silently ignored by Process).
      if (root.livenessPending) {
        root.livenessPending = false
        root.startLivenessCheck()
      }
    }
  }

  Timer {
    id: livenessWatchdog
    interval: 4000
    onTriggered: if (livenessProc.running) {
      console.warn("[launcher] liveness watchdog fired — existence check wedged over 4s")
      livenessProc.running = false
    }
  }

  Timer {
    id: recentsSyncTimer
    interval: 250
    onTriggered: root.startLivenessCheck()
  }

  PointerMoveGate {
    id: pointerGate
    referenceItem: card
  }

  Connections {
    target: root.appLibrary
    function onAppsChanged() {
      if (root.providersLoaded["apps"]) root.mergeAppRows()
    }
  }

  // The JSONC sources are watched so live edits to the default file (or the
  // user extension at ~/.config/omarchy/extensions/omarchy-menu.jsonc) take
  // effect without restarting the shell.
  FileView {
    id: defaultMenuFile
    path: root.defaultMenuPath
    watchChanges: true
    printErrors: false
    onLoaded: { root.defaultMenuItems = root.parseMenuJsonc(text()); root.rebuildItemsFromSources() }
    onLoadFailed: console.warn("[launcher] default menu not found at " + root.defaultMenuPath + " — the launcher will stay empty")
    onFileChanged: reload()
  }

  FileView {
    id: userMenuFile
    path: root.userMenuPath
    watchChanges: true
    printErrors: false
    onLoaded: { root.userMenuItems = root.parseMenuJsonc(text()); root.rebuildItemsFromSources() }
    onLoadFailed: { root.userMenuItems = []; root.rebuildItemsFromSources() }
    onFileChanged: reload()
  }

  // Recents/places sources: re-read at every open (watchChanges false — the
  // reload is explicit), parsed on load. The liveness pass that follows is
  // driven by refreshRecentSources()'s sync timer.
  FileView {
    id: recentsFile
    // Not read at all unless the tier is on: the file is large, and parsing it
    // for rows that will never show is pure work.
    path: root.showRecentRows ? Quickshell.env("HOME") + "/.local/share/recently-used.xbel" : ""
    watchChanges: false
    printErrors: false
    onLoaded: {
      root.recentsEntries = root.parseRecents(text())
      // Re-arm the sync debounce when a parse actually lands, so a slow
      // reload never misses the liveness pass (the 250 ms kick from
      // refreshRecentSources alone could fire before the parse).
      if (root.opened) recentsSyncTimer.restart()
    }
    onLoadFailed: root.recentsEntries = []
  }

  FileView {
    id: placesFile
    path: root.showRecentRows ? Quickshell.env("HOME") + "/.local/share/user-places.xbel" : ""
    watchChanges: false
    printErrors: false
    onLoaded: {
      root.placesXbelRaw = text()
      root.mergePlacesEntries()
      if (root.opened) recentsSyncTimer.restart()
    }
    onLoadFailed: {
      root.placesXbelRaw = ""
      root.mergePlacesEntries()
    }
  }

  // The GTK-side places file (Nautilus/Thunar sidebar). Both files are read and
  // merged: on this machine the Dolphin one exists, on Omarchy only this one.
  FileView {
    id: gtkBookmarksFile
    path: root.showRecentRows ? root.gtkBookmarksPath : ""
    watchChanges: false
    printErrors: false
    onLoaded: {
      root.gtkBookmarksRaw = text()
      root.mergePlacesEntries()
      if (root.opened) recentsSyncTimer.restart()
    }
    onLoadFailed: {
      root.gtkBookmarksRaw = ""
      root.mergePlacesEntries()
    }
  }

  // Frecency state: read once at startup (a missing file opens the gate via
  // onLoadFailed), written atomically by recordFrecency. Single-writer by
  // assumption — the file belongs to the one live shell instance; two
  // quickshell instances would last-writer-wins over each other.
  FileView {
    id: frecencyFile
    path: root.frecencyPath
    printErrors: false
    atomicWrites: true
    onLoaded: root.adoptFrecency(text())
    onLoadFailed: root.adoptFrecency("")
  }

  // ---------------------------------------------------------------- guards
  //
  // `when:` (visibility) and `checked:` (✓ marker) are bash expressions the
  // shell wasn't allowed to evaluate before the perf rewrite. Now the shell
  // batches them into one bash subprocess per (re)load so the open path
  // never has to wait on them.

  property var whenResults: ({})       // id → true|false (allow visibility)
  property var checkedResults: ({})    // id → true|false (show ✓)
  property var disabledResults: ({})   // id → true|false (dim, skip cursor)
  property bool guardsPending: false

  function evaluateGuards() {
    // Process ignores a command change while it is running, and `collected`
    // belongs to the run in flight, so a second evaluation cannot overwrite
    // the first: it would throw away the lines already read and never start.
    // The surviving tail then lands as the whole answer, and every id lost
    // with it goes back to showing, since a `when:` only hides on an explicit
    // false. Wait for the run in flight and evaluate once it lands instead.
    if (guardProc.running) {
      root.guardsPending = true
      return
    }
    root.guardsPending = false

    var script = MenuModel.guardScript(root.items)
    if (!script) {
      root.whenResults = ({})
      root.checkedResults = ({})
      root.disabledResults = ({})
      return
    }
    guardProc.collected = ""
    guardProc.command = ["bash", "-lc", script]
    guardProc.running = true
    guardProcWatchdog.restart()
  }

  Process {
    id: guardProc
    property string collected: ""
    stdout: SplitParser {
      onRead: function(data) { guardProc.collected += data + "\n" }
    }
    onExited: function(exitCode, exitStatus) {
      guardProcWatchdog.stop()
      // A batch that was killed rather than finished has only told us about
      // the rows it reached, and a row whose `when:` went unanswered shows.
      // Keep the last complete set rather than let a half-read one through.
      // A signal leaves the exit code at 0, so the status is what tells us.
      if (exitCode !== 0 || exitStatus !== 0) {
        if (root.guardsPending) Qt.callLater(function() { root.evaluateGuards() })
        return
      }

      var nextWhen = ({})
      var nextChecked = ({})
      var nextDisabled = ({})
      var lines = guardProc.collected.split("\n")
      for (var i = 0; i < lines.length; i++) {
        var line = lines[i].trim()
        if (!line) continue
        var colon = line.lastIndexOf(":")
        if (colon < 0) continue
        var value = line.substring(colon + 1) === "1"
        var rest = line.substring(0, colon)
        var tagAt = rest.lastIndexOf(":")
        if (tagAt < 0) continue
        var id = rest.substring(0, tagAt)
        var tag = rest.substring(tagAt + 1)
        if (tag === "w") nextWhen[id] = value
        else if (tag === "c") nextChecked[id] = value
        else if (tag === "d") nextDisabled[id] = value
      }
      root.whenResults = nextWhen
      root.checkedResults = nextChecked
      root.disabledResults = nextDisabled
      if (root.opened) root.rebuildDisplay()
      // Run the evaluation that had to stand aside. Deferred by a turn so the
      // process is settled before its command is set again.
      if (root.guardsPending) Qt.callLater(function() { root.evaluateGuards() })
    }
  }
  // The guard batch forks a lot (package and command probes). If one of those
  // blocks, rows would simply keep their stale visibility forever, because
  // evaluateGuards() only sets guardsPending while the run is in flight.
  Timer {
    id: guardProcWatchdog
    interval: 4000
    onTriggered: if (guardProc.running) {
      console.warn("[launcher] guard watchdog fired — guard batch wedged over 4s")
      guardProc.running = false
    }
  }

  OverlayWindow {
    id: panel
    shown: root.opened && root.rowsLoaded
    WlrLayershell.namespace: "omarchy-menu"

    // The card opens centered exactly as always. The first search keystroke
    // or submenu move freezes the top line where it currently sits — from
    // then on the card grows and shrinks downward instead of re-centering
    // on every resize, which made the menu jump around. The rows height is
    // frozen at the same moment, so the starting menu also caps how tall the
    // card may grow from there. Opening unfreezes both (resetting on close
    // would re-center the card mid-fade — see open()).
    property int cardTop: -1
    property int maxRowsHeight: -1
    readonly property int centeredTop: Math.max(Style.gapsOut, Math.round((height - root.cardHeight) / 2))
    readonly property int effectiveCardTop: cardTop >= 0 ? cardTop : centeredTop
    function freezeCardTop() {
      if (shown && cardTop < 0) {
        cardTop = effectiveCardTop
        maxRowsHeight = root.visibleRowsHeight
      }
    }
    // The surface stays mapped between opens, so closing is shown going false.
    // Geometry deliberately NOT reset here: the fade-out still plays, and an
    // instant unfreeze would re-center the card mid-fade. open() resets.

    // Fedora port (2026-10-03): the scrim fades in/out here in QML. The
    // compositor's `layers` animation is geometry-only (slide from this
    // surface's top-left anchor) and its fade style changed nothing on
    // 0.56.2, so the transition lives here with the layers animation
    // disabled in hyprland.conf.
    Rectangle {
      anchors.fill: parent
      color: root.scrim
      opacity: panel.shown ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.cancel()
    }

    BorderSurface {
      id: card
      // Fedora port (2026-10-03): the card fades with the scrim (see the
      // Rectangle above).
      opacity: panel.shown ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
      width: root.cardWidth
      height: Math.min(root.cardHeight, panel.height - Style.gapsOut - panel.effectiveCardTop)
      radius: root.cornerRadius
      anchors.horizontalCenter: parent.horizontalCenter
      y: panel.effectiveCardTop
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      // "Path copied!" confirmation for right-click on a file/folder row.
      // A plain Rectangle takes no input, so it never blocks the rows under
      // it while visible.
      Rectangle {
        id: pathCopiedToast
        opacity: 0
        visible: opacity > 0
        z: 30
        width: pathCopiedLabel.implicitWidth + Style.space(28)
        height: Math.max(Style.space(32), pathCopiedLabel.implicitHeight + Style.space(12))
        radius: root.cornerRadius
        // Opaque pill: see opaqueOver(). The border is the accent because the
        // theme's selected-border alpha defaults to 0 (invisible), which would
        // leave a solid pill with nothing to separate it from the card.
        color: root.opaqueOver(root.background, root.selectedBackground)
        border.color: root.selectedText
        border.width: 1
        anchors.horizontalCenter: parent.horizontalCenter
        y: root.toastY
        Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

        Timer {
          id: pathCopiedHide
          interval: 1400
          onTriggered: pathCopiedToast.opacity = 0
        }

        Text {
          id: pathCopiedLabel
          text: root.toastText
          textFormat: Text.PlainText
          anchors.centerIn: parent
          color: root.selectedText
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
      }

      Item {
        id: keyCatcher
        anchors.fill: parent
        z: root.deleteConfirmOpen ? 20 : 0
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          // The delete dialog owns the keyboard while it is up, and it needs the
          // real event (upstream behaviour, untouched).
          if (root.deleteConfirmOpen) {
            if (deleteConfirm.handleKey(event)) event.accepted = true
            return
          }
          if (root.handleKey(event.key, event.modifiers, event.text)) event.accepted = true
        }

        ConfirmDialog {
          id: deleteConfirm

          anchors.fill: parent
          opened: root.deleteConfirmOpen
          z: 10
          message: "Do you want to uninstall " + ((root.deleteTarget && root.deleteTarget.label) || "") + "?"
          confirmText: "Uninstall"
          background: root.background
          foreground: root.foreground
          scrim: root.scrim
          selectedBackground: root.selectedBackground
          selectedText: root.selectedText
          fontFamily: root.fontFamily
          cornerRadius: root.cornerRadius
          onCanceled: root.cancelDelete()
          onConfirmed: root.confirmDelete()
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        Rectangle {
          width: parent.width
          height: root.headerHeight
          radius: root.cornerRadius
          color: "transparent"

          Text {
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.browseRoot
              ? (root.browseLabel + (root.filterText ? "  ›  " + root.filterText : ""))
              : (root.filterText || (root.dmenuActive ? (root.dmenuPrompt + "…") : ((root.item(root.activeMenu) ? (root.item(root.activeMenu).title || root.item(root.activeMenu).label) : "Go") + "…")))
            color: root.foreground
            opacity: root.filterText ? 1 : 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideRight
          }

        }

        Item {
          width: parent.width
          height: root.visibleRowsHeight

          ListView {
            id: resultList
            anchors.fill: parent
            model: displayModel
            clip: true
            spacing: root.rowSpacing
            boundsBehavior: Flickable.StopAtBounds

            section.property: "section"
            section.criteria: ViewSection.FullString
            section.delegate: Item {
              required property string section

              width: ListView.view.width
              height: root.hasDivider(section) ? root.dividerHeight : 0
              visible: root.hasDivider(section)

              Rectangle {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(4)
                anchors.right: parent.right
                anchors.rightMargin: Style.space(4)
                anchors.verticalCenter: parent.verticalCenter
                height: Style.spacing.hairline
                color: Util.alpha(root.foreground, 0.2)
              }
            }

            delegate: BorderSurface {
              id: row
              required property int index
              required property string itemId
              required property string kind
              required property string icon
              required property string iconFont
              required property string appIcon
              required property string appId
              required property string label
              required property string target
              required property string detail
              required property string path
              required property string action
              required property int childCount
              required property bool disabled
              // Colour chip for answer rows; every producer sets it (the id
              // `row` shadows the context role, so it must be declared here).
              required property string swatch

              readonly property bool hasCursor: root.cursorActive && row.index === root.selectedIndex
              readonly property bool isApp: row.kind === "app"
              readonly property bool hasIcon: row.icon.length > 0 || row.isApp || row.swatch.length > 0

              width: ListView.view.width
              height: root.rowHeightForDetail(row.detail)
              // Faded: the row is here to say the software is already
              // installed, not to be picked.
              opacity: row.disabled ? 0.4 : 1
              radius: root.cornerRadius
              color: row.hasCursor ? root.selectedBackground : "transparent"
              borderSpec: row.hasCursor ? root.selectedBorderSpec : Border.none()

              Rectangle {
                visible: false
                width: Style.space(4)
                height: parent.height - Style.space(18)
                radius: Math.min(root.cornerRadius, Style.space(4))
                color: root.selectedBackground
                anchors.left: parent.left
                anchors.leftMargin: root.rowReservedBorderLeft + Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: iconText
                textFormat: Text.PlainText
                visible: row.hasIcon && !row.isApp
                text: row.icon
                color: row.hasCursor ? root.selectedText : root.foreground
                font.family: row.iconFont.length > 0 ? row.iconFont : root.fontFamily
                font.pixelSize: Style.font.iconLarge
                width: Style.space(36)
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                anchors.left: parent.left
                anchors.leftMargin: root.rowReservedBorderLeft + Style.space(8)
                y: contentColumn.y + labelText.y + (labelText.height - height) / 2
              }

              // Colour answers paint the colour itself; the glyph slot keeps
              // its size so the label lines up with every other row.
              Rectangle {
                id: swatchChip
                visible: row.swatch.length > 0
                width: Style.space(18)
                height: Style.space(18)
                radius: Math.min(root.cornerRadius, Style.space(5))
                color: root.hexToColor(row.swatch)
                border.color: Util.alpha(root.foreground, 0.35)
                border.width: 1
                anchors.left: parent.left
                anchors.leftMargin: root.rowReservedBorderLeft + Style.space(8) + (Style.space(36) - width) / 2
                y: contentColumn.y + labelText.y + (labelText.height - height) / 2
              }

              Image {
                id: appIconImage
                visible: row.isApp
                width: Style.font.iconLarge
                height: Style.font.iconLarge
                fillMode: Image.PreserveAspectFit
                // Decode at physical pixels — a logical-size decode leaves
                // PNG icons upscaled and blurry on HiDPI displays.
                sourceSize.width: width * Screen.devicePixelRatio
                sourceSize.height: height * Screen.devicePixelRatio
                source: row.isApp && root.appLibrary ? root.appLibrary.iconSource(row.appIcon) : ""
                asynchronous: true
                anchors.left: parent.left
                anchors.leftMargin: root.rowReservedBorderLeft + Style.space(8) + (Style.space(36) - width) / 2
                y: contentColumn.y + labelText.y + (labelText.height - height) / 2
              }

              Column {
                id: contentColumn
                anchors.left: row.hasIcon ? iconText.right : parent.left
                anchors.leftMargin: row.hasIcon ? Style.space(6) : root.rowReservedBorderLeft + Style.space(18)
                anchors.right: trail.left
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(3)

                Text {
                  id: labelText
                  textFormat: Text.PlainText
                  width: parent.width
                  text: row.label
                  color: row.hasCursor ? root.selectedText : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                  font.weight: Font.Medium
                  elide: Text.ElideRight
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: row.detail
                  visible: (root.filterText || row.kind === "dmenu") && row.detail.length > 0
                  color: root.foreground
                  opacity: 0.52
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }
              }

              Row {
                id: trail
                width: Style.space(14)
                anchors.right: parent.right
                anchors.rightMargin: root.rowReservedBorderRight + Style.space(8)
                y: contentColumn.y + labelText.y + (labelText.height - height) / 2
                spacing: 0

                Text {
                  textFormat: Text.PlainText
                  visible: false
                  text: row.childCount
                  color: root.foreground
                  opacity: 0.45
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  textFormat: Text.PlainText
                  text: row.kind === "menu" || row.kind === "link" ? "›" : ""
                  color: row.hasCursor ? root.selectedText : root.foreground
                  opacity: row.kind === "menu" || row.kind === "link" ? 0.36 : 0
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                  font.weight: Font.Normal
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              MouseArea {
                id: mouseArea
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: row.disabled ? Qt.ArrowCursor : Qt.PointingHandCursor
                onEntered: root.selectFromPointer(row.index, row, {
                  x: mouseArea.mouseX,
                  y: mouseArea.mouseY
                })
                onPositionChanged: function(mouse) {
                  root.selectFromPointer(row.index, row, mouse)
                }
                onClicked: function(mouse) {
                  if (mouse.button === Qt.RightButton) {
                    if (row.kind === "file" && row.target)
                      root.copyRowPath(row.target, mouseArea.mapToItem(card, 0, 0).y)
                    return
                  }
                  if (row.disabled) return
                  root.cursorActive = true
                  root.selectedIndex = row.index
                  root.activateIndex(row.index, true)
                }
              }
            }
          }

          // Scroll scrims. The clipped row already marks the fold at rest;
          // these keep both edges honest once the list has been scrolled,
          // when content hides above the card top as well as below. Strength
          // tracks the distance still hidden past each edge rather than
          // animating on a clock, so a programmatic jump — wrapping from the
          // last row back to the first — lands with the fade already applied.
          Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: Math.min(Style.space(28), parent.height / 2)
            visible: opacity > 0
            opacity: resultList.contentHeight > resultList.height
              ? Math.max(0, Math.min(1, (resultList.contentY - resultList.originY) / height))
              : 0
            gradient: Gradient {
              GradientStop { position: 0; color: root.background }
              GradientStop { position: 1; color: Util.alpha(root.background, 0) }
            }
          }

          Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: Math.min(Style.space(28), parent.height / 2)
            visible: opacity > 0
            opacity: resultList.contentHeight > resultList.height
              ? Math.max(0, Math.min(1, (resultList.originY + resultList.contentHeight - resultList.height - resultList.contentY) / height))
              : 0
            gradient: Gradient {
              GradientStop { position: 0; color: Util.alpha(root.background, 0) }
              GradientStop { position: 1; color: root.background }
            }
          }

          Column {
            anchors.centerIn: parent
            spacing: Style.space(8)
            visible: displayModel.count === 0 && root.mode !== "input"

            Text {
              text: "󰈉"
              color: root.selectedText
              opacity: 0.8
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
              horizontalAlignment: Text.AlignHCenter
              width: Style.space(320)
            }

            Text {
              textFormat: Text.PlainText
              text: root.filterText ? "No matches for “" + root.filterText + "”" : "Nothing here yet"
              color: root.foreground
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              horizontalAlignment: Text.AlignHCenter
              width: Style.space(320)
            }
          }
        }

        Item {
          width: parent.width
          height: 0
        }
      }
    }
  }
}
