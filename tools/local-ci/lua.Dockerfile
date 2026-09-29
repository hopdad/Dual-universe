# CI's Lua job (.github/workflows/ci.yml): Lua 5.3 and 5.4, busted, luacheck and dkjson.
FROM ubuntu:24.04
RUN apt-get update \
 && apt-get install -y --no-install-recommends lua5.3 lua5.4 lua-busted lua-check lua-dkjson git ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && update-alternatives --set lua-interpreter /usr/bin/lua5.3 \
 && git config --global --add safe.directory '*'
WORKDIR /repo/lua
