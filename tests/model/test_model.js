// Audit harness for omarchy-launcher-v2 MenuModel.js
const path = require("path");
const os = require("os");
const M = require(path.join(__dirname, "..", "..", "files", "MenuModel.js"));

let pass = 0, fail = 0;
const failures = [];
function check(name, cond, detail) {
  if (cond) { pass++; }
  else { fail++; failures.push(name + (detail !== undefined ? "  -> " + JSON.stringify(detail) : "")); }
}
function eq(name, actual, expected) {
  check(name, JSON.stringify(actual) === JSON.stringify(expected), { actual, expected });
}

// ---------------------------------------------------------------- stripJsonc
eq("stripJsonc strips // line comments (the line's newline stays)",
   M.stripJsonc('{\n  // a comment\n  "a": 1\n}'), '{\n  \n  "a": 1\n}');
eq("stripJsonc strips trailing comma",
   M.stripJsonc('{"a":1,}'), '{"a":1}');
eq("stripJsonc keeps // inside a string value",
   M.stripJsonc('{"url":"https://x.io"}'), '{"url":"https://x.io"}');
{
  const raw = '{"a":"x,}","b":2}';
  const out = M.stripJsonc(raw);
  const ok = (() => { try { JSON.parse(out); return true; } catch (e) { return false; } })();
  check("stripJsonc: string value containing ',}' survives", ok, { raw, out });
}
{
  const raw = '{"a":"//not a comment","b":2}';
  const out = M.stripJsonc(raw);
  let ok = true; try { JSON.parse(out); } catch (e) { ok = false; }
  check("stripJsonc: string value starting with // survives", ok, { raw, out });
}
{
  const raw = '{"a":"x,]"}';
  const out = M.stripJsonc(raw);
  let ok = true; try { JSON.parse(out); } catch (e) { ok = false; }
  check("stripJsonc: string value containing ',]' survives", ok, { raw, out });
}
eq("stripJsonc: null/empty input", M.stripJsonc(null), "");
eq("stripJsonc: block comment /* */ IS handled", (() => {
  const out = M.stripJsonc('{/* c */"a":1}');
  let ok = true; try { JSON.parse(out); } catch (e) { ok = false; }
  return ok;
})(), true);

// ---------------------------------------------------------- normalizeAliases
eq("normalizeAliases array", M.normalizeAliases(["a", "", "b"]), ["a", "b"]);
eq("normalizeAliases string", M.normalizeAliases("x"), ["x"]);
eq("normalizeAliases empty string", M.normalizeAliases(""), []);
eq("normalizeAliases undefined", M.normalizeAliases(undefined), []);
eq("normalizeAliases number", M.normalizeAliases(5), []);

// -------------------------------------------------------------- normalizeItem
{
  const n = M.normalizeItem("setup.power", { label: "Power", target: "system" });
  eq("normalizeItem kind=link for target", n.kind, "link");
  eq("normalizeItem kind=action for action", M.normalizeItem("x", { action: "a" }).kind, "action");
  eq("normalizeItem kind=menu default", M.normalizeItem("x", {}).kind, "menu");
  eq("normalizeItem derives parent from dotted id", n.parent, "setup");
  eq("normalizeItem parent of root is empty", M.normalizeItem("root", {}).parent, "");
  eq("normalizeItem explicit parent wins", M.normalizeItem("a.b", { parent: "z" }).parent, "z");
  eq("normalizeItem label defaults to id", M.normalizeItem("a.b", {}).label, "a.b");
  eq("normalizeItem aliases normalised", M.normalizeItem("a", { aliases: "one" }).aliases, ["one"]);
  eq("normalizeItem null raw safe", M.normalizeItem("a", null).id, "a");
}

// -------------------------------------------------------------- parseMenuJsonc
{
  const raw = `{
    // root
    "root": { "label": "Go" },
    "system": { "label": "System", "parent": "root", "aliases": ["sys","os"] },
    "setup.power": { "label": "Power", "parent": "setup", "when": "true" },
  }`;
  const items = M.parseMenuJsonc(raw);
  eq("parseMenuJsonc returns 3 items", items.length, 3);
  eq("parseMenuJsonc root parent", items[0].parent, "");
  eq("parseMenuJsonc alias array", items[1].aliases, ["sys", "os"]);
  eq("parseMenuJsonc invalid json -> []", M.parseMenuJsonc("{bad"), []);
  eq("parseMenuJsonc empty -> []", M.parseMenuJsonc("   "), []);
  eq("parseMenuJsonc array root -> []", M.parseMenuJsonc("[1,2]"), []);
  eq("parseMenuJsonc null -> []", M.parseMenuJsonc(null), []);
  eq("parseMenuJsonc {items:{...}} unwraps", M.parseMenuJsonc('{"items":{"a":{"label":"A"}}}').length, 1);
  eq("parseMenuJsonc {items:[...]} does not unwrap", M.parseMenuJsonc('{"items":[{"label":"A"}]}').length, 0);
  eq("parseMenuJsonc skips scalar entries", M.parseMenuJsonc('{"a":5,"b":{"label":"B"}}').length, 1);
}

// ------------------------------------------------------------ mergeMenuSources
{
  const def = M.parseMenuJsonc('{"root":{"label":"Go"},"system":{"label":"System","parent":"root"}}');
  const usr = M.parseMenuJsonc('{"system":{"label":"My System","parent":"root"},"extra":{"label":"X","parent":"root"}}');
  const m = M.mergeMenuSources(def, usr);
  eq("mergeMenuSources user overrides label", m.items.system.label, "My System");
  eq("mergeMenuSources keeps union", m.itemOrder.length, 3);
  eq("mergeMenuSources order is default-first", m.itemOrder, ["root", "system", "extra"]);
  eq("mergeMenuSources assigns order index", m.items.extra.order, 2);
  const usr2 = M.parseMenuJsonc('{"system":{"aliases":["sys"]}}');
  const m2 = M.mergeMenuSources(def, usr2);
  eq("mergeMenuSources merges field-wise", m2.items.system.label, "System");
  eq("mergeMenuSources merges aliases field", m2.items.system.aliases, ["sys"]);
  const m3 = M.mergeMenuSources([], M.parseMenuJsonc('{"a":{"label":"A"}}'));
  eq("mergeMenuSources synthesises root", m3.itemOrder[0], "root");
  eq("mergeMenuSources root parent empty", m3.items.root.parent, "");
}

// -------------------------------------------------------------- mergeAppRows
{
  const items = { root: { id: "root", kind: "menu", label: "Go", parent: "" },
                 sys:  { id: "sys", kind: "menu", label: "System", parent: "root" } };
  const order = ["root", "sys"];
  const rows = [{ id: "apps.firefox", kind: "app", label: "Firefox", parent: "root" }];
  const m = M.mergeAppRows(items, order, rows);
  eq("mergeAppRows keeps the non-app rows and adds the app row", m.itemOrder, ["root", "sys", "apps.firefox"]);
  eq("mergeAppRows appends app rows", m.itemOrder[2], "apps.firefox");
  eq("mergeAppRows sets order", m.items["apps.firefox"].order, 2);
  const m2 = M.mergeAppRows(items, ["root", "ghost", "sys"], rows);
  eq("mergeAppRows drops orphan ids", m2.itemOrder, ["root", "sys", "apps.firefox"]);
  const itemsWithApp = { root: items.root, "apps.firefox": { id: "apps.firefox", kind: "app", label: "Firefox" } };
  const m3 = M.mergeAppRows(itemsWithApp, ["root", "apps.firefox"], rows);
  eq("mergeAppRows no duplicate app row", m3.itemOrder.filter(i => i === "apps.firefox").length, 1);
  const m4 = M.mergeAppRows(items, order, [rows[0], { id: "apps.firefox", kind: "app", label: "Firefox" }]);
  eq("mergeAppRows dedupes incoming duplicates", m4.itemOrder.filter(i => i === "apps.firefox").length, 1);
  const m5 = M.mergeAppRows(null, null, null);
  eq("mergeAppRows null-safe", m5.itemOrder, []);
}

// ---------------------------------------------------------- swapProviderRows
{
  const items = { root: { id: "root", kind: "menu", label: "Go", parent: "" },
                 p:   { id: "p", kind: "menu", label: "Prov", parent: "root" },
                 prov1: { id: "prov1", kind: "menu", label: "X", parent: "p", providerMenu: "p" } };
  const order = ["root", "p", "prov1"];
  const m = M.swapProviderRows(items, order, "p", [{ id: "prov2", kind: "menu", label: "Y", parent: "p" }]);
  eq("swapProviderRows drops previous provider rows", m.itemOrder.indexOf("prov1"), -1);
  eq("swapProviderRows keeps other rows", m.itemOrder.indexOf("p") > 0, true);
  eq("swapProviderRows adds new row", m.itemOrder.indexOf("prov2") > 0, true);
  eq("swapProviderRows stamps providerMenu", m.items.prov2.providerMenu, "p");
  const m2 = M.swapProviderRows(m.items, m.itemOrder, "other", [{ id: "o1", kind: "menu", label: "O" }]);
  eq("swapProviderRows other provider does not steal rows", m2.itemOrder.indexOf("prov2") > 0, true);
}

// ---------------------------------------------------------------- resolveRoute
{
  const items = {
    root: { id: "root", kind: "menu", label: "Go", parent: "", aliases: [] },
    system: { id: "system", kind: "menu", label: "System", parent: "root", aliases: ["sys"] },
    "setup.power": { id: "setup.power", kind: "menu", label: "Power", parent: "setup", aliases: ["power-menu"] },
    "apps.htop": { id: "apps.htop", kind: "app", label: "htop", parent: "root", aliases: ["system"] }
  };
  const order = ["root", "system", "setup.power", "apps.htop"];
  eq("resolveRoute exact id", M.resolveRoute(items, order, "system"), "system");
  eq("resolveRoute alias", M.resolveRoute(items, order, "sys"), "system");
  eq("resolveRoute go -> root", M.resolveRoute(items, order, "go"), "root");
  eq("resolveRoute menu -> root", M.resolveRoute(items, order, "menu"), "root");
  eq("resolveRoute underscore normalised", M.resolveRoute(items, order, "power_menu"), "setup.power");
  eq("resolveRoute unknown falls through", M.resolveRoute(items, order, "nope"), "nope");
  eq("resolveRoute empty -> root", M.resolveRoute(items, order, ""), "root");
  eq("resolveRoute null -> root", M.resolveRoute(items, order, null), "root");
  const items2 = { root: items.root, "apps.x": { id: "apps.x", kind: "app", label: "X", aliases: ["unique-app-alias"] } };
  eq("resolveRoute app alias does not route", M.resolveRoute(items2, ["root", "apps.x"], "unique-app-alias"), "unique-app-alias");
}

// ------------------------------------------------------------------- slugify
eq("slugify basic", M.slugify("System Settings"), "system-settings");
eq("slugify empty -> item", M.slugify(""), "item");
eq("slugify null -> item", M.slugify(null), "item");
eq("slugify strips accents to hyphen (unicode lossy)", M.slugify("Café Münch"), "caf-m-nch");
eq("slugify trims hyphens", M.slugify("--a--b--"), "a-b");

// --------------------------------------------------- depth / path / ancestry
{
  const items = {
    root: { id: "root", kind: "menu", label: "Go", parent: "" },
    a: { id: "a", kind: "menu", label: "A", parent: "root" },
    b: { id: "b", kind: "menu", label: "B", parent: "a" },
    c: { id: "c", kind: "menu", label: "C", parent: "b" }
  };
  const order = ["root", "a", "b", "c"];
  eq("depthFor root", M.depthFor(items, "root"), 0);
  eq("depthFor a (root's child is depth 0)", M.depthFor(items, "a"), 0);
  eq("depthFor c", M.depthFor(items, "c"), 2);
  eq("pathFor c", M.pathFor(items, "c"), "A › B › C");
  eq("pathFor root", M.pathFor(items, "root"), "");
  eq("parentPathFor c", M.parentPathFor(items, "c"), "A › B");
  eq("parentPathFor root", M.parentPathFor(items, "root"), "");
  eq("isDescendantOf c of a", M.isDescendantOf(items, "c", "a"), true);
  eq("isDescendantOf a of a", M.isDescendantOf(items, "a", "a"), false);
  eq("isDescendantOf c of root", M.isDescendantOf(items, "c", "root"), true);
  eq("childCount a", M.childCount(items, order, "a"), 1);
  eq("childCount root", M.childCount(items, order, "root"), 1);
  eq("childCount leaf", M.childCount(items, order, "c"), 0);
  const cyc = { root: { id: "root", parent: "" }, x: { id: "x", parent: "y" }, y: { id: "y", parent: "x" } };
  check("depthFor cycle does not hang", M.depthFor(cyc, "x") <= 32);
  check("isDescendantOf cycle does not hang", M.isDescendantOf(cyc, "x", "z") === false);
}

// ----------------------------------------------------------------- isVisible
{
  const items = {
    root: { id: "root", kind: "menu", label: "Go", parent: "" },
    parent: { id: "parent", kind: "menu", label: "P", parent: "root" },
    child: { id: "child", kind: "action", label: "C", parent: "parent" },
    empty: { id: "empty", kind: "menu", label: "E", parent: "root" },
    hid: { id: "hid", kind: "action", label: "H", parent: "root", when: "false" }
  };
  const order = ["root", "parent", "child", "empty", "hid"];
  const when = { hid: false };
  eq("isVisible parent with visible child", M.isVisible(items, order, when, items.parent, 0), true);
  eq("isVisible empty menu hidden", M.isVisible(items, order, when, items.empty, 0), false);
  eq("isVisible action visible", M.isVisible(items, order, when, items.child, 0), true);
  eq("isVisible when=false hides", M.isVisible(items, order, when, items.hid, 0), false);
  eq("isVisible when undefined -> visible", M.isVisible(items, order, {}, items.hid, 0), true);
  eq("isVisible null entry", M.isVisible(items, order, when, null, 0), false);
  eq("isVisible depth guard 32", M.isVisible(items, order, when, items.parent, 32), false);
  const linkItems = {
    root: { id: "root", kind: "menu", label: "Go", parent: "" },
    l: { id: "l", kind: "link", label: "L", parent: "root", target: "system" },
    kid: { id: "kid", kind: "action", label: "K", parent: "l" }
  };
  eq("isVisible link finds child by target (target=system)",
     M.isVisible(linkItems, ["root", "l", "kid"], {}, linkItems.l, 0), false);
}

// -------------------------------------------------------------- isDisabled
eq("isDisabled no flag", M.isDisabled({}, { id: "a" }), false);
eq("isDisabled flag + result true", M.isDisabled({ a: true }, { id: "a", disabled: "x" }), true);
eq("isDisabled flag + result false", M.isDisabled({ a: false }, { id: "a", disabled: "x" }), false);
eq("isDisabled flag + no results", M.isDisabled(undefined, { id: "a", disabled: "x" }), false);

// ----------------------------------------------------------------- labelFor
eq("labelFor plain", M.labelFor({ id: "a", label: "A" }, {}, {}), "A");
eq("labelFor checked", M.labelFor({ id: "a", label: "A", checked: "c" }, { a: true }, {}), "A ✓");
eq("labelFor disabled", M.labelFor({ id: "a", label: "A", disabled: "d" }, {}, { a: true }), "A ✓");
eq("labelFor null", M.labelFor(null, {}, {}), "");

// ------------------------------------------------------- searchable helpers
eq("searchableToken dots/dashes", M.searchableToken("a.b-c_d"), "a b c d");
eq("leafIdFor", M.leafIdFor("a.b.c"), "c");
eq("leafIdFor no dot", M.leafIdFor("abc"), "abc");
eq("leafIdFor empty", M.leafIdFor(""), "");
eq("nameSearchText", M.nameSearchText({ id: "a.b", label: "Browser", aliases: ["web stuff"] }), "browser b web stuff");
eq("termInSearchWords exact word", M.termInSearchWords("foo", "a foo b"), true);
eq("termInSearchWords substring is not a word match", M.termInSearchWords("fo", "a foo b"), false);
eq("descriptionTextMatches multi-term", M.descriptionTextMatches("foo bar", "foo and bar"), true);
eq("descriptionTextMatches missing term", M.descriptionTextMatches("foo baz", "foo and bar"), false);

// ---------------------------------------------------------------- matchesQuery
{
  const e = { id: "a.b", label: "System", description: "Manage the system", aliases: ["sys"], kind: "menu" };
  eq("matchesQuery label substring", M.matchesQuery(e, "sys", true), true);
  eq("matchesQuery alias", M.matchesQuery(e, "sys", true), true);
  eq("matchesQuery description word", M.matchesQuery(e, "manage", true), true);
  eq("matchesQuery not visible", M.matchesQuery(e, "sys", false), false);
  eq("matchesQuery root excluded", M.matchesQuery({ id: "root", label: "Go" }, "go", true), false);
  eq("matchesQuery multi-term all must match", M.matchesQuery(e, "system zzz", true), false);
}

// ---------------------------------------------------------------- searchScore
{
  const items = { root: { id: "root", parent: "", label: "Go" } };
  const mk = (id, label, kind, parent) => ({ id, label, kind, parent: parent || "root", order: 0 });
  const app = mk("apps.zen", "Zen Browser", "app");
  const menu = mk("install.zh", "Zen", "menu", "install");
  const sApp = M.searchScore(items, app, "zen");
  const sMenu = M.searchScore(items, menu, "zen");
  check("searchScore: whole-word app outranks exact-labelled submenu", sApp < sMenu, { sApp, sMenu });
  const act = mk("a.screenshot", "Screenshot", "action");
  const cont = mk("a.screenrecord", "Screenrecord", "menu");
  check("searchScore: leaf action outranks submenu container",
        M.searchScore(items, act, "sc") < M.searchScore(items, cont, "sc"),
        { act: M.searchScore(items, act, "sc"), cont: M.searchScore(items, cont, "sc") });
  const pre = mk("a.pre", "Preflight", "action");
  const con = mk("a.con", "Not Preflight", "action");
  check("searchScore: prefix beats contains", M.searchScore(items, pre, "pre") < M.searchScore(items, con, "pre"));
  const exactRoot = mk("a.x", "Zoom", "menu");
  check("searchScore: exact root menu scores (2 + the menu bonus) * 1000", M.searchScore(items, exactRoot, "zoom") === 4*1000, M.searchScore(items, exactRoot, "zoom"));
  const t1 = mk("a.t1", "Same", "action"); t1.order = 1;
  const t2 = mk("a.t2", "Same", "action"); t2.order = 2;
  check("searchScore: order breaks ties", M.searchScore(items, t1, "same") < M.searchScore(items, t2, "same"));
  let threw = false;
  try { M.searchScore(items, { id: "x", kind: "action" }, "x"); } catch (e) { threw = true; }
  check("searchScore: entry without label does not throw (defended)", !threw, threw);
  const s = M.searchScore(items, { id: "y", label: "Y", kind: "action", parent: "root" }, "y");
  check("searchScore: missing order yields a number (defended)", !isNaN(s), s);
}

// --------------------------------------------------------------- displayRow
{
  const items = { root: { id: "root", kind: "menu", label: "Go", parent: "" },
                  a: { id: "a", kind: "menu", label: "A", parent: "root" },
                  kid: { id: "kid", kind: "action", label: "K", parent: "a" } };
  const order = ["root", "a", "kid"];
  const row = M.displayRow(items, order, {}, {}, items.kid, "detail", 5, "sec");
  eq("displayRow itemId", row.itemId, "kid");
  eq("displayRow detail", row.detail, "detail");
  eq("displayRow path", row.path, "A › K");
  eq("displayRow section", row.section, "sec");
  eq("displayRow childCount 0 for action", row.childCount, 0);
  eq("displayRow childCount for menu", M.displayRow(items, order, {}, {}, items.a, "", 0, "").childCount, 1);
  eq("displayRow score 0 kept", M.displayRow(items, order, {}, {}, items.kid, "", 0, "").score, 0);
  eq("displayRow link target used", M.displayRow(items, order, {}, {}, { id: "l", kind: "link", target: "t", label: "L", parent: "root" }, "", 0, "").target, "t");
}

// ------------------------------------------------------------- summonAction
eq("summonAction plain", M.summonAction("omarchy-shell shell summon menu"), { id: "menu", payload: "{}" });
eq("summonAction with payload", M.summonAction("omarchy-shell shell summon menu '{\"a\":1}'"), { id: "menu", payload: '{"a":1}' });
eq("summonAction rejects extra command", M.summonAction("omarchy-shell shell summon menu; rm -rf /"), null);
eq("summonAction rejects chaining", M.summonAction("omarchy-shell shell summon menu && evil"), null);
eq("summonAction rejects backticks", M.summonAction("omarchy-shell shell summon `id`"), null);
eq("summonAction rejects id with slash", M.summonAction("omarchy-shell shell summon a/b"), null);
eq("summonAction rejects id with space", M.summonAction("omarchy-shell shell summon a b"), null);
eq("summonAction payload with quote rejected", M.summonAction("omarchy-shell shell summon m 'a'b'"), null);
eq("summonAction non-string", M.summonAction(null), null);
eq("summonAction empty", M.summonAction(""), null);
eq("summonAction trailing newline rejected", M.summonAction("omarchy-shell shell summon menu\n"), null);

// --------------------------------------------------------------- guardScript
{
  const items = {
    a: { id: "a", when: "true" },
    b: { id: "b", checked: "false" },
    c: { id: "c", disabled: "true" }
  };
  const s = M.guardScript(items);
  const { execFileSync } = require("child_process");
  let out = "";
  try { out = execFileSync("bash", ["-lc", s], { encoding: "utf8", timeout: 30000 }); } catch (e) { out = e.stdout || ""; }
  // b's guard is the literal "false", so it answers 0 — that is the guard working.
  check("guardScript emits w/c/d tags", out.includes("a:w:1") && out.includes("b:c:0") && out.includes("c:d:1"), { out });
  check("guardScript has one group per batch", (s.match(/__omarchy_groups\+=/g) || []).length === 3);
  check("guardScript exits nonzero on group failure", s.includes("((__omarchy_failed == 0))"));
  eq("guardScript empty for no guards", M.guardScript({}), "");
  eq("guardScript empty for null", M.guardScript(null), "");
  const hostile = "evil; touch " + path.join(os.tmpdir(), "omarchy-test-pwned") + "; #";
  const s2 = M.guardScript({ [hostile]: { id: hostile, when: "true" } });
  check("guardScript: the id is QUOTED (no injection surface)", s2.includes("'" + hostile + "'"), s2.slice(-500));
  const s3 = M.guardScript({ x: { id: "x", when: "$(omarchy-default-browser)" } });
  check("guardScript substitutes guard readers", s3.includes("${__omarchy_read_2}"), s3);
  check("guardScript starts reader process substitution", s3.includes("omarchy-default-browser 2>/dev/null"));
}

console.log("\n=== MenuModel.js audit ===");
console.log("passed:", pass, " failed:", fail);
if (failures.length) {
  console.log("\nFAILURES:");
  failures.forEach(f => console.log("  ✗ " + f));
}
process.exit(fail ? 1 : 0);
