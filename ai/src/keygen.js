/// Creates a fresh wallet for the AI service and writes its key straight into ai/.env.
/// The private key is NEVER printed: only the address is, so it is safe to screenshot.
import fs from "node:fs";
import path from "node:path";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { AI_DIR } from "./config.js";

const envPath = path.join(AI_DIR, ".env");
const examplePath = path.join(AI_DIR, ".env.example");

let text = fs.existsSync(envPath)
  ? fs.readFileSync(envPath, "utf8")
  : fs.readFileSync(examplePath, "utf8");

const m = text.match(/^AI_PRIVATE_KEY=(0x[0-9a-fA-F]{64})\s*$/m);
if (m) {
  const addr = privateKeyToAccount(m[1]).address;
  console.log("ai/.env already has an AI wallet. Not touching it.");
  console.log("AI signer address:", addr);
  process.exit(0);
}

const pk = generatePrivateKey();
const addr = privateKeyToAccount(pk).address;
if (/^AI_PRIVATE_KEY=.*$/m.test(text)) {
  text = text.replace(/^AI_PRIVATE_KEY=.*$/m, `AI_PRIVATE_KEY=${pk}`);
} else {
  text += `\nAI_PRIVATE_KEY=${pk}\n`;
}
fs.writeFileSync(envPath, text, { mode: 0o600 });
console.log("New AI wallet created. Key saved in ai/.env (never share or commit it).");
console.log("AI signer address:", addr);
