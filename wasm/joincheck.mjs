// the web version's way of joining (drakonnet.js + joincheck.js), in Node 22+ (it has
// WebSocket built in), against a game hosted by the game itself:
//   love . --run tools/hostcheck.lua          (in another terminal)
//   node wasm/joincheck.mjs ws://127.0.0.1:5229 secret
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const here = fileURLToPath(new URL(".", import.meta.url));
globalThis.window = globalThis;
vm.runInThisContext(readFileSync(here + "drakonnet.js", "utf8"));
vm.runInThisContext(readFileSync(here + "joincheck.js", "utf8"));
const ok = await window.joinCheck(process.argv[2] || "ws://127.0.0.1:5229", process.argv[3] || "secret", console.log);
process.exit(ok ? 0 : 1);
