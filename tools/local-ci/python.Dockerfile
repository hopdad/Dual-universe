# CI's Python job (.github/workflows/ci.yml): uv, Lua 5.3 with dkjson, and psql for the hub tests.
FROM ubuntu:24.04
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 python3-venv pipx lua5.3 lua-dkjson postgresql-client git \
    ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && update-alternatives --set lua-interpreter /usr/bin/lua5.3 \
 && git config --global --add safe.directory '*' \
 && PIPX_BIN_DIR=/usr/local/bin pipx install uv
# A venv of its own, so a .venv in the mounted repository (made on Windows) is left alone.
ENV UV_PROJECT_ENVIRONMENT=/tmp/venv UV_LINK_MODE=copy
WORKDIR /repo
