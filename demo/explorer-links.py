#!/usr/bin/env python3
"""Turn the tx hashes in NOTES.md into explorer links and write EVIDENCE.md.
Usage (from the repo root):  python3 demo/explorer-links.py
Base Sepolia txs -> sepolia.basescan.org, Lasna txs -> lasna.reactscan.net"""
import re, sys
SRC, OUT = "NOTES.md", "EVIDENCE.md"
BASE, LASNA = "https://sepolia.basescan.org/tx/", "https://lasna.reactscan.net/tx/"
pat = re.compile(r"^[-\s]*(.+?)\s*\((Base|Lasna)[^)]*\):\s*(0x[0-9a-fA-F]{64})\s*$")
out = ["# On-chain evidence", "",
       "Every reactive transaction on Lasna and the callback it triggered on Base Sepolia, as explorer links.",
       "Timings and the AI's reasons for each verdict are in [NOTES.md](NOTES.md).", ""]
n = 0
for line in open(SRC, encoding="utf-8"):
    line = line.rstrip("\n")
    if line.startswith("#"):
        out += ["", "## " + line.lstrip("# ").strip(), ""]
        continue
    m = pat.match(line)
    if m:
        label, chain, h = m.groups()
        url = (BASE if chain == "Base" else LASNA) + h
        out.append(f"- {label} ({'Base Sepolia' if chain == 'Base' else 'Reactive Lasna'}): [`{h[:10]}…{h[-6:]}`]({url})")
        n += 1
open(OUT, "w", encoding="utf-8").write("\n".join(out).replace("\n\n\n", "\n\n") + "\n")
print(f"wrote {OUT} with {n} transaction links")
if n == 0: sys.exit("no tx lines matched; is NOTES.md in the expected format?")
