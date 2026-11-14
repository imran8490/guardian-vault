#!/usr/bin/env bash
# Run before the first public push:  demo/prepush-check.sh
# Looks for secrets in what git tracks and in git history. Read-only.
set -u
cd "$(dirname "$0")/.."
bad=0
fail() { echo "FAIL: $*"; bad=1; }
ok()   { echo "ok:   $*"; }

[ -d .git ] || { echo "not a git repo"; exit 1; }

# 1. files that must never be tracked
T=$(git ls-files | grep -E '(^|/)\.env($|\.)|\.guardian-pw|keystore|(^|/)broadcast/|node_modules/' | grep -v '\.env\.example$' || true)
[ -z "$T" ] && ok "no .env / keystore / password files tracked" || fail "tracked secret-looking files:"$'\n'"$T"

# 2. secrets in tracked content (working tree) and in history
pat_key='AI_PRIVATE_KEY=0x[0-9a-fA-F]{64}|PRIVATE_KEY=0x[0-9a-fA-F]{64}'
pat_oai='sk-[A-Za-z0-9_-]{20,}'
if git grep -nIE "$pat_key|$pat_oai" -- . ':!*.lock' >/dev/null 2>&1; then
  fail "secret pattern in tracked files:"; git grep -nIE "$pat_key|$pat_oai" | sed -E 's/(=|sk-).{6}.*/\1.../' | head
else ok "no private key / OpenAI key pattern in tracked files"; fi
if git log --all -p 2>/dev/null | grep -qE "$pat_key|$pat_oai"; then
  fail "secret pattern found in git HISTORY (do not push; ask for help rewriting history)"
else ok "no secret pattern in git history"; fi

# 3. the files we want public
for f in README.md LICENSE .env.example ai/.env.example ai/verdicts.jsonl NOTES.md; do
  git ls-files --error-unmatch "$f" >/dev/null 2>&1 && ok "$f is tracked" || echo "note: $f is NOT tracked (git add $f)"
done

# 4. libs
if [ -f .gitmodules ]; then ok "lib submodules:"; grep -E 'path|url' .gitmodules | sed 's/^/        /'
else echo "note: no .gitmodules. Clones need lib/forge-std and lib/reactive-lib-omni (see README)"; fi
git ls-files lib | head -1 | grep -q . && echo "note: lib/ files are tracked directly (fine if intended)"

echo; [ $bad -eq 0 ] && echo "RESULT: safe to push" || { echo "RESULT: NOT safe, fix the FAIL lines first"; exit 1; }
