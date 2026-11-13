import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { loadEnvFile } from "../src/config.js";

const tmp = (name, text) => {
  const f = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "env-")), name);
  fs.writeFileSync(f, text);
  return f;
};

test("later line wins, empty values ignored, export/quotes handled", () => {
  const f = tmp(".env", 'T_POOL=\nexport T_ORACLE="0xabc"\nT_POOL=0x111\nT_EMPTY=\n# c\nT_POOL=0x222\r\n');
  delete process.env.T_POOL; delete process.env.T_ORACLE; delete process.env.T_EMPTY;
  loadEnvFile(f);
  assert.equal(process.env.T_POOL, "0x222");
  assert.equal(process.env.T_ORACLE, "0xabc");
  assert.equal(process.env.T_EMPTY, undefined);
});

test("first file (ai/.env) beats second (root .env); empty template values do not block", () => {
  const a = tmp("a.env", "T_X=\nT_Y=fromAI\n");
  const b = tmp("b.env", "T_X=fromRoot\nT_Y=fromRoot\n");
  delete process.env.T_X; delete process.env.T_Y;
  loadEnvFile(a); loadEnvFile(b);
  assert.equal(process.env.T_X, "fromRoot");
  assert.equal(process.env.T_Y, "fromAI");
});

test("real environment wins over files", () => {
  process.env.T_Z = "real";
  loadEnvFile(tmp("c.env", "T_Z=file\n"));
  assert.equal(process.env.T_Z, "real");
});
