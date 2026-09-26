#!/usr/bin/env bash
# Reproduces the DU-LuaC checks in docs/verification.md.
#
#   handoff/    project.json exactly as written in the handoff (section 3). Expected: build fails.
#   corrected/  the same two builds in the format DU-LuaC 1.3.5 accepts. Expected: build succeeds,
#               and each target compiles in only its own transport branch.
#
# Needs Node 18+ and network access to the npm registry. Build output goes to */out (git-ignored).
set -uo pipefail
cd "$(dirname "$0")"
DULUA=(npx --yes -p @wolfe-labs/du-luac@1.3.5 du-lua)

echo "=== handoff/ (expect: Can't initialize a Slot without a name)"
(cd handoff && "${DULUA[@]}" build 2>&1 | grep -E 'ERROR|SUCCESS')

echo "=== corrected/ (expect: SUCCESS plus size report against the 200 kB JSON / 180 kB CONF limits)"
(cd corrected && "${DULUA[@]}" build 2>&1 | grep -E 'ERROR|SUCCESS|build size')
for target in development production; do
  printf '%-12s pilot compiled transport branch: ' "$target"
  grep -o -E 'optical-frame|log-print' "corrected/out/$target/pilot.json" | sort -u | tr '\n' ' '
  echo
done
