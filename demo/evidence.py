#!/usr/bin/env python3
"""Turn the `demo/proof.sh` blocks in NOTES.md into ready-to-paste evidence with explorer links.

Usage:  python3 demo/evidence.py 56 58        (epochs; the LAST proof block for each epoch is used)
Writes EVIDENCE.md and prints the same text. Hashes are copied from NOTES.md, never retyped.
"""
import re, sys

BASE = "https://sepolia.basescan.org/tx/"
LASNA = "https://lasna.reactscan.net/tx/"
H = r"(0x[0-9a-fA-F]{64})"
LINES = [  # (label, regex, explorer)
    ("Trigger swap (Base Sepolia)", r"^Trigger swap .*?: " + H, BASE),
    ("AI verdict published, RiskOracle.publishRisk (Base Sepolia)", r"^AI publishRisk .*?: " + H, BASE),
    ("Reactive ActionRequested (Reactive Lasna)", r"^Reactive ActionRequested \(Lasna block.*?: " + H, LASNA),
    ("Vault callback (Base Sepolia)", r"^Vault (?:DeRisked|ReRisked) callback .*?: " + H, BASE),
]

def blocks(text):
    parts = re.split(r"(?m)^## Proof for epoch (\d+) ", text)
    out = {}
    for i in range(1, len(parts), 2):
        out[int(parts[i])] = parts[i + 1]          # later blocks overwrite earlier ones
    return out

def main():
    epochs = [int(a) for a in sys.argv[1:]]
    if not epochs:
        sys.exit(__doc__)
    found = blocks(open("NOTES.md", encoding="utf-8").read())
    res, problems = [], []
    for ep in epochs:
        body = found.get(ep)
        if body is None:
            problems.append(f"epoch {ep}: no proof block in NOTES.md (run demo/proof.sh {ep} | tee -a NOTES.md)")
            continue
        head = body.split("\n", 1)[0]
        kind = "De-risk" if "DeRisked" in body else "Re-risk" if "ReRisked" in body else "Verdict"
        res.append(f"### {kind}, epoch {ep} {head.strip()}")
        for label, rx, base in LINES:
            m = re.search(rx, body, re.M)
            if m:
                res.append(f"- {label}: [{m.group(1)}]({base}{m.group(1)})")
            elif "Trigger swap" in label:
                continue                                   # optional line
            else:
                problems.append(f"epoch {ep}: missing '{label}' (re-run demo/proof.sh {ep})")
                res.append(f"- {label}: MISSING")
        t = re.search(r"swap -> vault moved: (\d+) s", body)
        if t:
            res.append(f"- Swap to vault, end to end: {t.group(1)} s")
        res.append("")
    text = "## Full-loop transaction hashes (testnet)\n\n" + "\n".join(res)
    open("EVIDENCE.md", "w", encoding="utf-8").write(text)
    print(text)
    if problems:
        print("\nPROBLEMS:\n" + "\n".join(" - " + p for p in problems), file=sys.stderr)
        sys.exit(1)

main()
