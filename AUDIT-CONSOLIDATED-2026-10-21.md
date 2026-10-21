# Omarchy Launcher v2 — Consolidated Audit (both audits, deduplicated)

**Date:** 2026-10-21 16:47 · **Supersedes** `AUDIT-2026-10-21.md` where the two disagree
**Inputs:** Audit A (this agent, 437 executed tests incl. a real Qt6 QML engine) and Audit M (muse, 151 assertions, Node harness)
**Status of every line below:** re-verified by me in this session against the live tree. Provenance marked **[A]**, **[M]**, or **[both]**.

---

> **Status (later the same day):** all twelve defects below are **fixed** in
> commit `721e9b1` (plugin edition) and `f648660` (pack edition), verified by the
> suites described in the commit. This file is the record of the audit, not a list
> of open issues.

## 0. Head-to-head: which audit was better?

**Short answer: close, complementary, with a slight overall edge to Audit A** — but Audit M found the single best *individual* bug of the two (the unarmed focus watchdog), and Audit A got one of its own claims wrong.

| Dimension | Audit A (this agent) | Audit M (muse) |
|---|---|---|
| Unique real bugs found | 10 | 8 |
| Unique finds the other missed | B1, B2, B3(trailing `//`), B5, B6, B7, B8, B9, B10, B11, B12 | focus watchdog, openPath custom opener, web-row opener, 1-char window rows, exact-cap truncation, `file://localhost`, paste surrogate, Baloo dir bypass |
| **Best single find** | B7 (global scrim leak into 4 untouched plugins) | **focusWatchdog never armed** — a genuine bug Audit A missed entirely |
| Factual errors | 1 — over-claimed that `install.sh` "downgrades the live MenuModel.js"; it does **not** on this machine (patch already applied; install.sh is a no-op there and would actually *fix* the stale mirror) | 1 — asserted "the live checkout **and mirror** are byte-identical to the repo files". False: the mirror's `MenuModel.js` is 19 627 B (Oct 12) vs the repo/checkout 21 807 B (Oct 18) |
| Severity calibration | Slightly over-rated the install.sh downgrade risk | Under-rated the paste bug ("cosmetic only" — it actually throws, see §2.3); said "every user-facing feature works", which B2/B5/B10 contradict |
| Methodology strength | **Real Qt6 QML engine** (PySide6 6.11.2), executing the launcher's own function bodies. This is the only way B2 was findable — a Node/V8 harness **structurally cannot** see it | 151 assertions in Node; broader installer matrix (7 fake-HOME scenarios vs my 1 happy path + sandbox); correctly separated upstream-inherited defects |
| Documentation audit | 8 wrong README claims with line refs | Checked tuning tables/ordering/requirements — those genuinely match; missed the prose contradictions |

**Why "slight edge to A":** more high-impact findings (a visual regression across four *other* plugins, a live uninstall that doesn't restore, two editions that are no longer the same product), engine-accurate testing that caught a bug class M's harness could not see, and one fewer false claim.
**Why not a walkover:** M's watchdog catch is real, its exact-cap and `file://localhost` finds are sharper than anything comparable in A, and its installer matrix was broader. Neither audit is safe to use alone.

---

## 1. Verified: every Audit M finding

| # | Muse finding | Verdict | Evidence |
|---|---|---|---|
| M1 | **focus watchdog never armed** | ✅ **CONFIRMED** | `grep focusWatchdog` → only `stop()` at 3297 and `id:` at 3324. No `.restart()` among the 17 restart sites. `launchWindowFocus` (3045-3049) sets `running = true` and nothing arms the timer |
| M2 | custom opener ignored when all stock openers missing | ✅ **CONFIRMED** | `openPath` 2961-2965 returns early on `kdeopen/gio/xdgopen === false` **before** consulting `fileOpenCommandEffective` |
| M3 | web row hardcodes `xdg-open` | ✅ **CONFIRMED** | 2684 `Util.execArgv(["xdg-open", row.target])` — bypasses the opener chain; the "Missing:" notice needs all three gone, so a lone missing `xdg-open` is silent |
| M4 | 1-char queries derive window rows from a warm cache | ✅ **CONFIRMED** | 2019-2023 has no query-length gate; only `startWindowSearch` (1680) requires ≥2. Type `ab`, backspace → window rows for `a` |
| M5 | exact-cap truncation silent in `capFileTier: false` | ✅ **CONFIRMED** | `fdResultLimit` → 6/12; `folderLimit` = 6/12; `folderCut = total > limit` (2113) is false at exactly 6 → no hint. The capped mode reports correctly (`total ≥ 20` → `"20+"`). Sharp finding |
| M6 | `file://localhost/…` → dead relative path | ✅ **CONFIRMED** (executed) | `parseRecents` → `"localhost/home/ravi/Documents/x.txt"`, `absolute: false`. Liveness hides it; the bookmark silently never appears |
| M7 | paste cap splits a surrogate pair | ✅ **CONFIRMED — but under-rated** | Executed: 199 `a` + 😀 → `afterUnits: 200`, last unit `0xD83D` (lone high surrogate). See §2.3: it also **throws** |
| M8 | Baloo dir hits / symlinked folders bypass `openFolder` | ✅ **CONFIRMED** | `contentRowsFor` calls `actionRow(..., false)` → `isFolder:false`; browse puts symlinks in the *file* phase (741). Both then go to `openPath`, which on KDE can land a directory in Gwenview |
| M9 | 9 dead wrapper functions | ✅ **CONFIRMED** | `depthFor, pathFor, childCount, labelFor, searchableToken, leafIdFor, nameSearchText, termInSearchWords, descriptionTextMatches` — each appears only on its own definition line. (`parentPathFor` **is** used at 2003 and is correctly excluded) |
| M10 | 2 permanently-`visible:false` delegate items | ✅ **CONFIRMED** | 4002 and 4105 |
| M11 | `mergeMenuSources` wipes omitted fields | ✅ **CONFIRMED** — also found independently by A |
| M12 | `stripJsonc` only strips line-start `//` | ✅ **CONFIRMED** — A additionally proved a *trailing* `//` (not just `/* */`) empties all 344 entries |
| M13 | shell log has exactly one `[launcher]` line | ✅ **CONFIRMED** | `shell.log` 5.8 MB → `35093: [launcher] guard watchdog fired — guard batch wedged over 4s` |
| M14 | both QML files pass qmllint; a broken control file fails | ✅ **CONFIRMED (fair)** | With Qt6 qmllint + import paths the broken control file emits 3 real diagnostics (`missing-property`, `incompatible-type`, `property-override`). My first attempt used the Qt5 `qmllint 1.0`, which catches nothing — M's method was the right one |
| M15 | patches apply to pristine 821ae58 and reproduce the pack files | ✅ **CONFIRMED** | Both patches `git apply --check` rc=0; the big patch reproduces `Menu.qml` + `OverlayWindow.qml` byte-for-byte |
| M16 | **"live checkout and mirror are byte-identical to the repo files"** | ❌ **FALSE** | `~/.config/quickshell/omarchy/plugins/menu/MenuModel.js` = `7feafc73…`, 19 627 B, **Oct 12**; repo/checkout = `cd1f9587…`, 21 807 B, Oct 18. `quickshell -c omarchy` (PID 2157) loads the mirror → **the running shell is on the pre-guard file.** `Menu.qml` *is* in sync (all three `95b70f04…`) |
| M17 | "past length cap … cosmetic only" | ❌ **Under-rated** | It throws `URIError: malformed URI sequence` — see §2.3 |
| M18 | "README … no drift found" | ⚠️ **Partly true** | The tuning tables, ordering and requirements genuinely match. The *prose* drifts: the plugin README's window-helper claim contradicts the code and the other README; dmenu mode is unreachable in plugin mode (`omarchy-menu-select:89` / `omarchy-menu-input:48` hardcode `omarchy.menu`) |

**Audit M score: 15 of 16 claims confirmed.** Its one factual error is material — it is the basis of its "next step: re-run install.sh to sync the live trees" recommendation, which it framed as a sync rather than a repair.

---

## 2. What Audit A got that Audit M missed (all re-verified today)

### 2.1 The two editions are no longer the same product — and a fresh install loses the guard work
`install.sh` applies only `patches/menu-model-ranking.patch`. `files/MenuModel.js` in the **plugin** carries 62 further lines (the `guardPrelude` FD rewrite + `GUARD_GROUPS = 8` parallel batching) that exist in **no patch and no pack file**.

Measured, real menu, 7 runs each: pack result **173 ms** vs plugin **103 ms** median (1.68×), answers byte-identical (261/261).

> **Correcting my own earlier report:** I wrote that a fresh `install.sh` "downgrades the live `MenuModel.js`". **On this machine it does not** — the ranking patch is already applied, so `install.sh:138-139` takes the "already applied (nothing to do)" branch and the file is untouched. The accurate statement: *on a pristine tree*, the pack's install path produces a `MenuModel.js` without the guard work; on **this** machine `install.sh` is a no-op for that file and would in fact repair the stale mirror (§2.6).

### 2.2 Emoji cannot be typed into the filter
`Menu.qml:2528` uses `Array.from(text).length === 1`. QML's V4 engine splits surrogate pairs:

| engine | `Array.from("😀").length` | `[..."😀"].length` |
|---|---|---|
| V8 / Node | 1 | 1 |
| **QML V4 (what runs)** | **2** | **1** |

So the character is refused, not typed, **and not consumed** — it leaks to the focus chain. The comment above the line claims the opposite. One-character fix: `[...text].length`.

*This is the finding that most justifies A's methodology: a Node harness cannot see it.*

### 2.3 The paste bug is worse than "cosmetic" — it throws and wedges the list
Escalating M7. Verified in the real engine:

```
encodeURIComponent("a" + "\uD83D")  →  THROWS: URIError: malformed URI sequence
```

Path: `insertPastedText` → `setFilter` → `rebuildDisplay` → web row (2336) `"…?q=" + encodeURIComponent(query)` → **throws after `displayModel.clear()`**. The filter keeps the lone surrogate, so **every subsequent keystroke re-throws** and the launcher shows an empty list until Escape. Recoverable, but not cosmetic.

### 2.4 Date-like queries are answered by the calculator with a wrong number
`calcCandidate` (1088) accepts digit + operator, so `2026-10-21` → `2026 - 10 - 21` → **1995**, shown as the top answer row with "Enter copies". Verified: `classifyQuery("2026-10-21").mode === "calc"`, value `1995`.

### 2.5 A hostile menu id kills the entire guard batch
`guardLine` (484-487) splices the id into bash unquoted. With id `evil; touch …; #` the injection **does not execute** (bash refuses to parse), but the batch exits 2 → **every** `when:`/`checked:`/`disabled:` goes unanswered → on a first load `whenResults` is `{}`, `isVisible` only hides on an explicit `false`, and **all ~230 deliberately hidden rows become visible**.

### 2.6 The running shell is on the old `MenuModel.js` (mirror stale)
See M16. `install.sh:150-164` would repair it; it evidently was not re-run after 18 Oct.

### 2.7 The 280 ms overlay hold leaks a scrim into four untouched plugins
`files/OverlayWindow.qml` is shared by 7 plugins; the pack changed it **globally**:

```diff
-    value: window.shown && window.width > 1 && window.height > 1
+    value: window.holdGeometry && window.width > 1 && window.height > 1
-  anchors { top: true; left: true; bottom: shown; right: shown }
+  anchors { top: true; left: true; bottom: holdGeometry; right: holdGeometry }
```

`holdGeometry = shown || hideHold.running` for 280 ms. `Emojis.qml:167`, `Clipboard.qml:321`, `ReminderFlow.qml:102` (`color: root.scrim`, 50 % alpha) and `wifiqr/Panel.qml` (78 % black) have **no `opacity`/`visible` binding** — they relied on `contentItem.visible` going false immediately. Result: the dimming scrim lingers ~280 ms after dismissing the emoji picker, clipboard history, reminder flow or wifi-QR panel. The pack's comment at `OverlayWindow.qml:21-23` asserting the opposite is false.

### 2.8 `uninstall.sh` does not restore this machine
Both live snapshots hold only `Menu.qml` + `OverlayWindow.qml` + mirror copies — **no `MenuModel.js`**. `restore_from_snapshot` only *warns* for a missing file, so the `git checkout` fallback is never reached → **running `uninstall.sh` today leaves the ranking patch applied**. Separately, `git checkout --` restores the **index**, not HEAD.

### 2.9 `install.sh` has no rollback, and can take no backup at all
No `trap`: a failing `install` leaves a half-installed tree (Menu faded, OverlayWindow not) with no diagnostic. And `PACK_STATE` (51-67) never inspects the *checkout's* `MenuModel.js`, so a hand-edited model + an otherwise pack-revision tree → "Already at the pack revision — no new backup taken" and the backup root is never created.

### 2.10 The Baloo tier matches file *names* but is labelled "content"
`baloosearch6 -l 24 <query>` with no `-t` ⇒ default `FileType` = name **or** content. Verified: `baloosearch6 -l 5 "fix-round-plan"` returns a name hit; `-t title` returns nothing. Every row is labelled `content · …` (1362-1363).

---

## 3. Deduplicated master issue list

Ordered by severity. **P1 = fix this week**, P2 = fix soon, P3 = hygiene.

| ID | Issue | Sev | Found by | Fix |
|---|---|---|---|---|
| **P1-1** | Focus watchdog never armed — a wedged focus leaves the tier dead until shell restart | **Med** | M | one line: `focusWatchdog.restart()` in `launchWindowFocus` (3045-3049) |
| **P1-2** | Paste splits a surrogate → `URIError` in `rebuildDisplay` → empty list, every keystroke re-throws | **Med** | M + A | cap on code points: `[...text].slice(0,200).join("")` |
| **P1-3** | 280 ms overlay hold leaks a 50–78 % scrim into Emojis / Clipboard / ReminderFlow / wifi-QR | **Med-High** | A | make the hold opt-in per consumer, or fade those four; correct the false comment at `OverlayWindow.qml:21-23` |
| **P1-4** | Editions diverge: pack's install path yields a `MenuModel.js` 62 lines behind the plugin (1.68× slower guard batch) | **Med-High** | A | ship `files/MenuModel.js` in the pack and `install -Dm644` it |
| **P1-5** | `uninstall.sh` leaves the ranking patch applied (snapshots lack `MenuModel.js`; `git checkout --` = index, not HEAD) | **Med** | A | per-file `git checkout HEAD --` for anything missing from the snapshot |
| **P1-6** | Emoji cannot be typed and is not consumed | **Med** | A | `[...text].length` |
| **P1-7** | `2026-10-21` → calculator answers **1995** | **Med** | A | reject `^\d{4}-\d{2}-\d{2}$`, or require `=` |
| **P2-1** | Custom `fileOpenCommand` ignored when all three stock openers are missing | Low-Med | M | check `fileOpenCommand` before the early return |
| **P2-2** | Guard batch dies entirely on an id containing shell metacharacters | Med (edge) | A | `printf '%s:%s:1\n'` with a quoted id |
| **P2-3** | `install.sh` has no rollback trap | Med | A | `trap` restoring the snapshot on ERR |
| **P2-4** | `PACK_STATE` ignores the checkout's `MenuModel.js` → can take no backup | Low-Med | A | include it in the comparison at 51-67 |
| **P2-5** | Live mirror `MenuModel.js` stale — running shell on the pre-guard file | Med (hygiene) | A | re-run `install.sh` (it repairs the mirror); better, ship the file (§P1-4) |
| **P2-6** | Web row hardcodes `xdg-open`, bypassing the opener chain | Low | M | use `fileOpenCommandEffective` |
| **P2-7** | 1-char queries derive window rows from a warm cache (fd/content need ≥2) | Low | M | add the same length gate at 2019 |
| **P2-8** | Exact-cap truncation silent in `capFileTier:false` | Low | M | treat `total >= limit` as "may be more" in that mode |
| **P2-9** | `file://localhost/…` → dead relative path | Low | M | strip a `localhost` authority |
| **P2-10** | Baloo tier matches names but is labelled "content" | Low | A | `-t text`, or rename the tier |
| **P2-11** | Baloo dir hits / symlinked folders open via the generic resolver (Gwenview trap) | Low | M | `isFolder` from a stat, or route dirs to `openFolder` |
| **P3-1** | `mergeMenuSources` wipes any field a partial override omits (**upstream**) | Med (landmine) | both | merge only supplied keys; **document it** — the in-code comment at 455-457 says the opposite |
| **P3-2** | `stripJsonc` only strips line-start `//`; trailing `//` or `/* */` empties the menu silently (**upstream**) | Med (landmine) | both | string-aware stripper; warn on 0 entries from a non-empty file |
| **P3-3** | 9 dead wrapper functions + 2 `visible:false` items (**upstream**) | Cosmetic | M (both partially) | leave (minimises rebase drift) — or delete deliberately |
| **P3-4** | README drift: plugin window-tier claim, plugin `update` semantics, dmenu unreachable in plugin mode, `validate` needs a dir, "=" exclusivity, symlinks, Esc/pill | Med (docs) | A | rewrite the plugin Requirements/Install prose; correct the shared prose |

**Totals:** 7 P1 · 11 P2 · 4 P3. Of these, **7 are upstream-inherited** (P3-1…P3-3, and they explain themselves); the rest are in the pack.

---

## 4. What both audits agree is *correct*

Recomputed, not taken on trust: every documented arithmetic / conversion / colour example; the
XML-XBEL-GTK parsers (single-pass entity decode, no double-decode); frecency decay, cap and
corrupt-state adoption; the window tier's scratchpad/`mapped` filters; the shell-inert `%1` query
token; the key tree (Ctrl+C/Super+C reachable, Alt+letter types); the selection model; provider-row
merging and id collision handling; the capability probe; both patches applying cleanly to pristine
`821ae58`; and a full `install.sh` → `uninstall.sh` cycle restoring all three files byte-for-byte
(`sha256sum -c` 3/3 OK, `git status` clean).

Live guard batch against the real menu: **261/261 answered, 0 malformed, 198 ms cold / 108 ms warm.**

---

## 5. Next step — the ordered plan

**Do these seven, in this order, in one sitting.** They are independent and each is small.

1. **Arm the watchdog** — `focusWatchdog.restart()` after `focusProc.running = true` in
   `launchWindowFocus`. *(1 line, closes P1-1.)*
2. **Fix the two surrogate bugs together** — `[...text].length` at 2528 and
   `[...text].slice(0,200).join("")` at 2445. Same root cause; test with 199 chars + 😀 and with
   a lone emoji keypress. *(2 lines, closes P1-2 and P1-6.)*
3. **Make the overlay hold opt-in** — add `hideHoldMs: 0` as the default in
   `files/OverlayWindow.qml`, set `280` only on the Menu instance, or give the four scrim
   consumers their own opacity binding. Then correct the comment that claims the hold is
   invisible. *(closes P1-3, the most user-visible defect.)*
4. **Converge the editions** — copy `files/MenuModel.js` into the pack and install it, and
   regenerate the patch. Then re-run `bash install.sh` once to repair the stale mirror. *(closes
   P1-4 and P2-5 together.)*
5. **Repair uninstall** — per-file `git checkout HEAD --` fallback when a snapshot entry is
   missing, plus a `trap` rollback in install. *(closes P1-5, P2-3, P2-4.)*
6. **Stop the calculator eating dates** — reject `^\d{4}-\d{2}-\d{2}$` in `calcCandidate`.
   *(closes P1-7.)*
7. **Fix the cheap P2s** — custom-opener early return, web-row opener, 1-char window gate,
   quoted guard id. *(Four small edits.)*

**Then, separately:** rewrite the plugin README's Requirements/Install prose (P3-4) and add a
short "How your extension file merges" section to both READMEs stating the actual rule —
*an entry replaces the default wholesale; restate every field you want to keep, and aliases do
not accumulate* — because the shipped comment at `Menu.qml:455-457` currently teaches the
opposite and users will lose menu rows following it.

**Definition of done:** `bash -n` on both scripts; the guard batch still answers 261/261; one
`install.sh` → `uninstall.sh` cycle with `sha256sum -c` clean; and a manual pass typing an emoji,
pasting an emoji at the 200-char boundary, `2026-10-21`, and dismissing the emoji picker to
confirm no scrim lingers.

---

*Verification for this consolidation: muse's 16 claims re-checked (15 confirmed, 1 false);
muse's 4 unverified low findings reproduced or statically confirmed; my own B1 claim corrected;
nothing in either project directory or the live omarchy tree modified.*
