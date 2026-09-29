#!/usr/bin/env bash
# Runs CI's Lua and Python jobs (.github/workflows/ci.yml) in local Linux containers, for a PC that
# lacks busted, psql or a Lua with dkjson (Windows). Needs Docker. Usage: tools/local-ci/run.sh [lua|python]
set -euo pipefail
# Git Bash: Windows paths, which Docker for Windows needs once MSYS path conversion is off.
here=$(cd "$(dirname "$0")" && (pwd -W 2>/dev/null || pwd))
root=$(cd "$(dirname "$0")/../.." && (pwd -W 2>/dev/null || pwd))
export MSYS_NO_PATHCONV=1
job=${1:-all}

if [ "$job" = all ] || [ "$job" = lua ]; then
    docker build -q -t dufleet-lua-ci -f "$here/lua.Dockerfile" "$here" >/dev/null
    echo "== Lua bus: busted on 5.3, luacheck, busted on 5.4"
    docker run --rm -v "$root:/repo" dufleet-lua-ci sh -ec '
        ./tools/deps.sh >/dev/null
        busted -o utfTerminal
        luacheck . --no-color --formatter plain
        update-alternatives --set lua-interpreter /usr/bin/lua5.4 >/dev/null 2>&1
        busted -o utfTerminal'
fi

if [ "$job" = all ] || [ "$job" = python ]; then
    docker build -q -t dufleet-py-ci -f "$here/python.Dockerfile" "$here" >/dev/null
    echo "== Protocol, companion (with PostgreSQL 16) and probe kit"
    docker run -d --rm --name dufleet-ci-pg -e POSTGRES_PASSWORD=postgres postgres:16 >/dev/null
    trap 'docker stop dufleet-ci-pg >/dev/null 2>&1 || true' EXIT
    until docker exec dufleet-ci-pg pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done
    docker run --rm --network container:dufleet-ci-pg -v "$root:/repo" \
        -e PGHOST=localhost -e PGPORT=5432 -e PGUSER=postgres -e PGPASSWORD=postgres -e DUFLEET_PG_TESTS=1 \
        dufleet-py-ci sh -ec '
            ./lua/tools/deps.sh >/dev/null
            python3 packages/protocol/codegen.py --check
            cd companion
            uv run --quiet python ../packages/protocol/tools/make_vectors.py --check
            uv run --quiet ruff check . ../packages/protocol
            uv run --quiet pytest -q
            cd ../spikes/host
            uv run --quiet ruff check .
            uv run --quiet pytest -q'
fi
