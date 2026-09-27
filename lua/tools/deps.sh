#!/usr/bin/env sh
# Fetches the Lua test dependencies into lua/.deps (gitignored), each at a pinned commit:
#   du-mocks (1337joe/du-mocks): mocks of the game's elements;
#   ArchHUD (The-Third-Verse/ArchHUD, GPL-3.0) and AtlasFile (The-Third-Verse/AtlasFile): the
#   real atlas and autopilot code that spec/archhud_contract_spec.lua runs the adapter against.
#   The commits match companion/src/dufleet/pins.py.
# busted, luacheck and dkjson come from the system or luarocks (see lua/README.md).
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$here/.deps"

fetch() { # name url commit
    dest="$here/.deps/$1"
    if [ -d "$dest/.git" ] && [ "$(git -C "$dest" rev-parse HEAD)" = "$3" ]; then
        return 0
    fi
    rm -rf "$dest"
    git init --quiet "$dest"
    git -C "$dest" fetch --quiet --depth 1 "$2" "$3"
    git -C "$dest" -c advice.detachedHead=false checkout --quiet FETCH_HEAD
    echo "$1 $3 in $dest"
}

fetch du-mocks https://github.com/1337joe/du-mocks a510c77c7239c6162c560de95252b25fa78b3671
fetch archhud https://github.com/The-Third-Verse/ArchHUD 6c952221d9c82797b282161d9ae94744d3f8c9cf
fetch atlasfile https://github.com/The-Third-Verse/AtlasFile 48dd00f910782e9707af923264b387bd2a4357ee
