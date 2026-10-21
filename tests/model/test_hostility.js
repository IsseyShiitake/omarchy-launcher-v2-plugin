// Hostile-input probes on the guard layer and the parser.
const fs = require("fs");
const { execFileSync } = require("child_process");
const path = require("path");
const os = require("os");
const M = require(path.join(__dirname, "..", "..", "files", "MenuModel.js"));

let pass = 0, fail = 0; const F = [];
function check(n, c, d) { if (c) pass++; else { fail++; F.push(n + (d !== undefined ? "  -> " + JSON.stringify(d) : "")); } }

// ---- 1. A menu id containing shell metacharacters is interpolated UNQUOTED
const hostileId = "evil; touch " + path.join(os.tmpdir(), "omarchy-test-pwned") + "; #";
const items = {};
items[hostileId] = { id: hostileId, when: "true", checked: "", disabled: "", label: "x",
                     parent: "root", kind: "menu", icon: "", iconFont: "", title: "", target: "",
                     description: "", action: "", provider: "", aliases: [] };
const script = M.guardScript(items);
console.log("--- generated guard line ---");
console.log(script.split("\n").filter(l => l.includes("omarchy-test-pwned")).join("\n"));
try { fs.unlinkSync(path.join(os.tmpdir(), "omarchy-test-pwned")); } catch (e) {}
let out = "", status = 0;
try { out = execFileSync("bash", ["-lc", script], { encoding: "utf8", timeout: 20000 }); }
catch (e) { status = e.status; out = e.stdout || ""; }
const pwned = fs.existsSync(path.join(os.tmpdir(), "omarchy-test-pwned"));
console.log("guard batch exit:", status, " output:", JSON.stringify(out.slice(0, 200)));
check("hostile menu id does NOT execute arbitrary shell", !pwned, { pwned });
check("hostile menu id does NOT break the guard batch", status === 0, { status, out: out.slice(0, 200) });
check("hostile menu id is answered verbatim", out.trim() === hostileId + ":w:1", { out: out.slice(0, 200) });
if (pwned) { try { fs.unlinkSync(path.join(os.tmpdir(), "omarchy-test-pwned")); } catch (e) {} }

// ---- 2. A menu id with a SPACE breaks the guard line
const spacedId = "has space";
const items2 = {};
items2[spacedId] = { id: spacedId, when: "true", label: "x", parent: "root", kind: "menu",
                     icon: "", iconFont: "", title: "", target: "", description: "",
                     action: "", provider: "", aliases: [], checked: "", disabled: "" };
const s2 = M.guardScript(items2);
let out2 = "", status2 = 0;
try { out2 = execFileSync("bash", ["-lc", s2], { encoding: "utf8", timeout: 20000 }); }
catch (e) { status2 = e.status; out2 = e.stdout || ""; }
console.log("spaced-id guard output:", JSON.stringify(out2.slice(0, 200)), "exit:", status2);
check("a menu id containing a space round-trips through the batch",
      /^has space:w:1$/m.test(out2), { out: out2.slice(0, 200) });

// ---- 3. The guard READERS path (a `when:` that reads a reader)
const items3 = { x: { id: "x", when: "$(omarchy-default-browser)", checked: "", disabled: "",
                      label: "x", parent: "root", kind: "menu", icon: "", iconFont: "", title: "",
                      target: "", description: "", action: "", provider: "", aliases: [] } };
const s3 = M.guardScript(items3);
console.log("--- reader substitution present:", s3.includes("${__omarchy_read_2}"),
            "| reader process started:", s3.includes("omarchy-default-browser 2>/dev/null"));
check("guard readers are substituted and started", s3.includes("${__omarchy_read_2}") &&
      s3.includes("omarchy-default-browser 2>/dev/null"));
let out3 = "", status3 = 0;
try { out3 = execFileSync("bash", ["-lc", s3], { encoding: "utf8", timeout: 20000 }); }
catch (e) { status3 = e.status; out3 = e.stdout || ""; }
console.log("reader guard output:", JSON.stringify(out3.slice(0, 120)), "exit:", status3);
check("the reader-based guard still answers", /^x:w:[01]$/m.test(out3), { out: out3.slice(0, 200) });

// ---- 4. Parser hostility
check("parseMenuJsonc rejects a non-object", M.parseMenuJsonc("42").length === 0);
check("parseMenuJsonc rejects a bare array", M.parseMenuJsonc("[1,2,3]").length === 0);
check("parseMenuJsonc survives deeply nested junk", M.parseMenuJsonc('{"a":' + "[".repeat(200) + "]".repeat(200) + "}").length === 0);
check("parseMenuJsonc handles a 5000-entry input", (() => {
  const big = JSON.stringify(Object.fromEntries(Array.from({ length: 5000 }, (_, i) => ["k" + i, { label: "L" + i }])));
  return M.parseMenuJsonc(big).length === 5000;
})());

// ---- 5. stripJsonc hostility
{
  const cases = [
    ['{"a":"x,}"}', "comma+brace inside a string"],
    ['{"a":"x,]"}', "comma+bracket inside a string"],
    ['{"a":"//x"}', "double slash inside a string"],
    ['{"a":"/*x*/"}', "block comment marker inside a string"],
  ];
  for (const [raw, what] of cases) {
    const out = M.stripJsonc(raw);
    let ok = true; try { JSON.parse(out); } catch (e) { ok = false; }
    check("stripJsonc keeps " + what, ok, { raw, out });
  }
  // A line-starting // INSIDE a multi-line-looking string is not a real case in JSON,
  // but a // after a value on its own line IS a real comment and must go.
  const c = M.stripJsonc('{\n "a": 1 // trailing comment\n}');
  let ok = true; try { JSON.parse(c); } catch (e) { ok = false; }
  check("stripJsonc DOES strip a trailing // comment (the whole-file failure is fixed)", ok, { c });
}

// ---- 6. resolveRoute with a hostile input
check("resolveRoute with a shell payload falls through as a literal",
      M.resolveRoute({}, [], "'; rm -rf /") === "'; rm -rf /");
check("resolveRoute with a huge string does not hang",
      typeof M.resolveRoute({}, [], "a".repeat(100000)) === "string");

// ---- 7. depthFor / pathFor on a cyclic parent chain
{
  const cyc = { root: { id: "root", parent: "", label: "Go" } };
  cyc.a = { id: "a", parent: "b", label: "A" };
  cyc.b = { id: "b", parent: "a", label: "B" };
  const t0 = Date.now();
  const d = M.depthFor(cyc, "a");
  const p = M.pathFor(cyc, "a");
  check("depthFor terminates on a parent cycle", d <= 32, { d });
  check("pathFor terminates on a parent cycle", typeof p === "string" && p.length < 200, { p });
  check("depthFor on a cycle is fast", Date.now() - t0 < 100);
}

// ---- 8. isVisible on a self-referencing structure
{
  const items4 = { root: { id: "root", kind: "menu", parent: "", label: "Go" } };
  items4.x = { id: "x", kind: "menu", parent: "x", label: "X" };
  const t0 = Date.now();
  const v = M.isVisible(items4, ["root", "x"], {}, items4.x, 0);
  check("isVisible terminates on a self-parent", typeof v === "boolean", { v });
  check("isVisible on a cycle is fast", Date.now() - t0 < 200);
}

console.log("\n=== HOSTILITY PROBES ===");
console.log("passed:", pass, " failed:", fail);
F.forEach(f => console.log("  x " + f));
process.exit(fail ? 1 : 0);
