// Verification of the MenuModel.js fixes: string-aware JSONC, per-key merge,
// quoted guard id. Run against the REAL menu files on this machine.
const fs = require("fs");
const { execFileSync } = require("child_process");
const path = require("path");
const os = require("os");
const M = require(path.join(__dirname, "..", "..", "files", "MenuModel.js"));

let pass = 0, fail = 0; const F = [];
function check(n, c, d) { if (c) pass++; else { fail++; F.push(n + (d !== undefined ? "  -> " + JSON.stringify(d) : "")); } }
function eq(n, a, e) { check(n, JSON.stringify(a) === JSON.stringify(e), { actual: a, expected: e }); }

console.log("=== A. stripJsonc: string-aware ===");
{
  const cases = [
    ['{"a":1 // trailing\n}', "trailing // comment"],
    ['{"a":1 /* block */}', "block comment"],
    ['{"a":"x,}"}', "comma+brace inside a string"],
    ['{"a":"x,]"}', "comma+bracket inside a string"],
    ['{"a":"//x"}', "double slash inside a string"],
    ['{"a":"/*x*/"}', "block marker inside a string"],
    ['{"a":"https://x.io/p?q=1,2"}', "URL with a comma"],
    ['{"a":"q\\"still a string, }"}', "escaped quote then comma-brace"],
    // The comma is trailing even when a comment sits between it and the brace:
    // this is how people annotate an entry, and missing it emptied the menu.
    ['{"a":1, // note\n}', "trailing comma + line comment"],
    ['{"a":1, /* note */}', "trailing comma + block comment"],
    ['{"a":1, /* a */ // b\n}', "trailing comma + two comments"],
    ['{"a":[1, // c\n]}', "array trailing comma + comment"],
    ['\uFEFF{"a":1}', "a UTF-8 BOM"],
  ];
  for (const [raw, what] of cases) {
    const out = M.stripJsonc(raw);
    let ok = true, val = null;
    try { val = JSON.parse(out); } catch (e) { ok = false; }
    check("stripJsonc handles " + what, ok, { raw, out });
    if (ok && what === "trailing // comment") eq("  ...and the value survives", val.a, 1);
    if (ok && what === "comma+brace inside a string") eq("  ...and the comma survives", val.a, "x,}");
    if (ok && what === "URL with a comma") eq("  ...and the URL survives", val.a, "https://x.io/p?q=1,2");
    if (ok && what === "escaped quote then comma-brace") eq("  ...and the string survives", val.a, 'q"still a string, }');
  }
  // the menu-level regression: one annotated entry must not empty the file
  const pm = M.parseMenuJsonc('{"items":{"a":{"label":"A"}, // note\n}}');
  eq("an annotated trailing comma still yields the entry", pm.length, 1);
  eq("  ...with its label", pm[0].label, "A");
  // a BOM must not empty it either
  eq("a BOM'd file still parses", M.parseMenuJsonc('\uFEFF{"items":{"a":{"label":"A"}}}').length, 1);
  // a malformed file still returns [] — but now says so
  const realWarn = console.warn; let warned = 0;
  console.warn = () => { warned += 1; };
  const bad = M.parseMenuJsonc('{"items":');
  console.warn = realWarn;
  eq("a malformed file returns no items", bad.length, 0);
  eq("  ...and warns exactly once", warned, 1);
  // a line-start comment still goes
  const c = M.stripJsonc('{\n  // full line\n  "a": 1\n}');
  let ok = true; try { JSON.parse(c); } catch (e) { ok = false; }
  check("stripJsonc still removes a full-line comment", ok, { c });
  // block comment spanning lines
  const b = M.stripJsonc('{/* multi\nline */"a":1}');
  let ok2 = true; try { JSON.parse(b); } catch (e) { ok2 = false; }
  check("stripJsonc removes a multi-line block comment", ok2, { b });
}

console.log("\n=== C. per-key merge ===");
{
  const def = M.parseMenuJsonc('{"root":{"label":"Go"},"system":{"label":"System","icon":"I","action":"act","description":"D","when":"w","checked":"c","aliases":["a1"],"parent":"root"}}');
  const usr = M.parseMenuJsonc('{"system":{"aliases":["x"]}}');
  const m = M.mergeMenuSources(def, usr);
  const e = m.items.system;
  console.log("   merged:", JSON.stringify(e));
  eq("per-key: label survives", e.label, "System");
  eq("per-key: icon survives", e.icon, "I");
  eq("per-key: action survives", e.action, "act");
  eq("per-key: description survives", e.description, "D");
  eq("per-key: when survives", e.when, "w");
  eq("per-key: checked survives", e.checked, "c");
  eq("per-key: parent survives", e.parent, "root");
  eq("per-key: kind stays action", e.kind, "action");
  eq("per-key: the written aliases REPLACE the default's", e.aliases, ["x"]);

  // an explicit label still overrides
  const m2 = M.mergeMenuSources(def, M.parseMenuJsonc('{"system":{"label":"Mine"}}'));
  eq("per-key: an explicit label still wins", m2.items.system.label, "Mine");
  eq("per-key: ...and the rest survives", m2.items.system.action, "act");

  // an explicit action="" clears it, and kind follows
  const m3 = M.mergeMenuSources(def, M.parseMenuJsonc('{"system":{"action":""}}'));
  eq("per-key: an explicit empty action clears it", m3.items.system.action, "");
  eq("per-key: kind follows the cleared action", m3.items.system.kind, "menu");

  // the FIRST source keeps its derived fields
  const m4 = M.mergeMenuSources(M.parseMenuJsonc('{"a.b":{"label":"X"}}'), []);
  eq("per-key: the first source keeps its derived parent", m4.items["a.b"].parent, "a");
  eq("per-key: the first source keeps its derived kind", m4.items["a.b"].kind, "menu");
  eq("per-key: the first source keeps its id", m4.items["a.b"].id, "a.b");

  // no `specified` key leaks into the item
  check("per-key: `specified` does not leak into the item", !("specified" in m.items.system), Object.keys(m.items.system));
}

console.log("\n=== E. quoted guard id ===");
{
  const hostile = "evil; touch " + path.join(os.tmpdir(), "omarchy-test-pwned2") + "; #";
  const items = {};
  items[hostile] = { id: hostile, when: "true", checked: "", disabled: "", label: "x",
                     parent: "root", kind: "menu", icon: "", iconFont: "", title: "", target: "",
                     description: "", action: "", provider: "", aliases: [], specified: [] };
  const script = M.guardScript(items);
  console.log("   generated:", script.split("\n").filter(l => l.includes("PWNED2")).join("\n").slice(0, 200));
  try { fs.unlinkSync(path.join(os.tmpdir(), "omarchy-test-pwned2")); } catch (e) {}
  let out = "", status = 0;
  try { out = execFileSync("bash", ["-lc", script], { encoding: "utf8", timeout: 20000 }); }
  catch (e) { status = e.status; out = e.stdout || ""; }
  console.log("   exit:", status, " output:", JSON.stringify(out.slice(0, 120)));
  check("a hostile id no longer breaks the batch", status === 0, { status, out: out.slice(0, 200) });
  check("a hostile id does not execute", !fs.existsSync(path.join(os.tmpdir(), "omarchy-test-pwned2")));
  check("the hostile id is answered correctly", out.trim() === hostile + ":w:1", { out: out.slice(0, 200) });

  // an id with a space and one with a quote
  for (const id of ["has space", "it's", "a*b", "a:b"]) {
    const it = {};
    it[id] = { id, when: "true", checked: "", disabled: "", label: "x", parent: "root", kind: "menu",
               icon: "", iconFont: "", title: "", target: "", description: "", action: "",
               provider: "", aliases: [], specified: [] };
    const sc = M.guardScript(it);
    let o = "", st = 0;
    try { o = execFileSync("bash", ["-lc", sc], { encoding: "utf8", timeout: 20000 }); }
    catch (e) { st = e.status; o = e.stdout || ""; }
    check("id " + JSON.stringify(id) + " round-trips through the guard batch", st === 0 && o.trim() === id + ":w:1", { st, o: o.slice(0, 120) });
  }
}


console.log("\n=== F. a fixture guard batch answers every id ===");
{
  const items = {}, ids = [];
  for (let i = 0; i < 30; i++) {
    const id = "g." + i;
    ids.push(id);
    items[id] = { id, when: i % 4 === 0 ? "true" : "false", checked: i % 2 ? "true" : "",
                  disabled: i % 5 === 0 ? "true" : "", label: id, parent: "root", kind: "menu",
                  icon: "", iconFont: "", title: "", target: "", description: "", action: "",
                  provider: "", aliases: [], specified: [] };
  }
  const script = M.guardScript(items);
  let out = "", status = 0;
  try { out = execFileSync("bash", ["-lc", script], { encoding: "utf8", timeout: 30000 }); }
  catch (e) { status = e.status; out = e.stdout || ""; }
  const lines = out.split("\n").filter(l => l.trim());
  // Mirror the generator's rule: a row hidden by when:"false" gets its `when`
  // guard only — marker guards on an invisible row are not worth running.
  const expected = ids.reduce((n, id) => {
    const e = items[id];
    const hidden = e.when && String(e.when).trim() === "false";
    return n + (e.when ? 1 : 0) + (!hidden && e.checked ? 1 : 0) + (!hidden && e.disabled ? 1 : 0);
  }, 0);
  console.log("   exit:", status, " lines:", lines.length, " guarded ids:", expected);
  check("the fixture guard batch exits 0", status === 0, { status });
  eq("every guarded id is answered", lines.length, expected);
  let parsed = 0;
  for (const line of lines) {
    const l = line.trim();
    const colon = l.lastIndexOf(":");
    if (colon < 0) continue;
    const rest = l.substring(0, colon);
    if (rest.lastIndexOf(":") < 0) continue;
    parsed++;
  }
  eq("every line parses under Menu.qml's parser", parsed, lines.length);
  // a row hidden with when:"false" carries no marker guards
  const hiddenChecked = script.split("\n").filter(l => l.includes("'g.1' 'c'")).length;
  eq("a hidden row's marker guards are skipped", hiddenChecked, 0);
  // the visible row's checked guard is present
  check("a visible row's marker guard is present", script.includes("'g.0' 'c'") || script.includes("'g.0' 'd'"), script.slice(0, 400));
}

console.log("\n=== RESULTS ===");
console.log("passed:", pass, " failed:", fail);
F.forEach(f => console.log("  x " + f));
process.exit(fail ? 1 : 0);
