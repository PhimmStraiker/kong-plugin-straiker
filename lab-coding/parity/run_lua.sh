#!/usr/bin/env bash
# wrapper: set luarocks cjson path + plugin repo, run lua_cli on a wire.jsonl
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export PLUGIN_REPO="$(cd "$HERE/../.." && pwd)"   # .../kong-plugin-straiker
eval "$(luarocks path)"
exec lua "$HERE/lua_cli.lua" "$@"
