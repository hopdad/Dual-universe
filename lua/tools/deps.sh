#!/usr/bin/env sh
# Fetches the Lua test dependencies into lua/.deps (gitignored):
#   du-mocks (1337joe/du-mocks), pinned below.
# busted, luacheck and dkjson come from the system or luarocks (see lua/README.md).
set -eu

DU_MOCKS_URL=https://github.com/1337joe/du-mocks
DU_MOCKS_REV=a510c77c7239c6162c560de95252b25fa78b3671

here=$(cd "$(dirname "$0")/.." && pwd)
dest="$here/.deps/du-mocks"

if [ -d "$dest/.git" ] && [ "$(git -C "$dest" rev-parse HEAD)" = "$DU_MOCKS_REV" ]; then
    exit 0
fi
rm -rf "$dest"
mkdir -p "$here/.deps"
git clone --quiet "$DU_MOCKS_URL" "$dest"
git -C "$dest" -c advice.detachedHead=false checkout --quiet "$DU_MOCKS_REV"
echo "du-mocks $DU_MOCKS_REV in $dest"
