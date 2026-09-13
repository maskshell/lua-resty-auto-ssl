#!/usr/bin/env bash
# install.sh — install the resty-auto-ssl bin payload (GitHub release asset,
# Channel B of the dual-channel release) into an installed lua-resty-auto-ssl
# Lua tree. The Lua half ships via OPM (`opm get maskshell/lua-resty-auto-ssl`);
# OPM carries pure Lua only, so the bin payload is distributed here and placed
# where the module's module-adjacent bin resolution looks for it:
#   <resty-lualib-dir>/auto-ssl/bin/resty-auto-ssl/
#
# Usage: ./install.sh <resty-lualib-dir>
#
#   <resty-lualib-dir>  the resty/ lualib directory that contains BOTH
#                       auto-ssl.lua and the auto-ssl/ package directory.
#
# Examples:
#   sudo ./install.sh /usr/local/openresty/site/lualib/resty   # system-wide (sudo for system prefixes)
#   ./install.sh ./resty_modules/lualib/resty           # opm --cwd layout
#
# Copies dehydrated, letsencrypt_hooks, start_sockproc and sockproc with exec
# bits preserved. Fails fast if the target is not a resty-auto-ssl lualib dir.

set -euo pipefail

PAYLOAD_FILES="dehydrated letsencrypt_hooks start_sockproc sockproc"

usage() {
  cat <<'USAGE'
usage: install.sh <resty-lualib-dir>

  <resty-lualib-dir>  the resty/ lualib directory that contains BOTH
                      auto-ssl.lua and the auto-ssl/ package directory.

examples:
  sudo install.sh /usr/local/openresty/site/lualib/resty   # system-wide prefix
  install.sh ./resty_modules/lualib/resty           # opm --cwd layout

Copies dehydrated, letsencrypt_hooks, start_sockproc and sockproc to
<resty-lualib-dir>/auto-ssl/bin/resty-auto-ssl/ (exec bits preserved).
Fails fast if the target directory is not a resty-auto-ssl lualib dir.
USAGE
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

# Pinned contract: exactly ONE required argument (plan N3).
if [ "$#" -ne 1 ]; then
  echo "error: exactly one argument is required: the resty/ lualib dir (got $#)" >&2
  usage >&2
  exit 2
fi

target=$1

# Fail-fast target checks: the argument must be the resty/ dir holding BOTH
# auto-ssl.lua and the auto-ssl/ package dir.
if [ -z "$target" ]; then
  echo "error: target directory must not be empty" >&2
  exit 1
fi
if [ ! -d "$target" ]; then
  echo "error: target directory does not exist or is not a directory: $target" >&2
  exit 1
fi
if [ ! -f "$target/auto-ssl.lua" ]; then
  echo "error: $target/auto-ssl.lua not found" >&2
  echo "       the argument must be the resty/ lualib dir containing auto-ssl.lua" >&2
  echo "       (e.g. /usr/local/openresty/site/lualib/resty or ./resty_modules/lualib/resty)" >&2
  exit 1
fi
if [ ! -d "$target/auto-ssl" ]; then
  echo "error: $target/auto-ssl/ not found" >&2
  echo "       the argument must be the resty/ lualib dir containing the auto-ssl/ package dir" >&2
  exit 1
fi

# Payload must sit next to this script (as laid out in the release asset:
# install.sh + bin/resty-auto-ssl/).
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
payload_dir="$script_dir/bin/resty-auto-ssl"
if [ ! -d "$payload_dir" ]; then
  echo "error: payload directory not found: $payload_dir" >&2
  echo "       run this script from the extracted release asset" >&2
  exit 1
fi
for f in $PAYLOAD_FILES; do
  if [ ! -f "$payload_dir/$f" ]; then
    echo "error: payload file missing: $payload_dir/$f" >&2
    exit 1
  fi
  if [ ! -x "$payload_dir/$f" ]; then
    echo "error: payload file is not executable: $payload_dir/$f" >&2
    exit 1
  fi
done

dest="$target/auto-ssl/bin/resty-auto-ssl"
mkdir -p "$dest"

for f in $PAYLOAD_FILES; do
  install -m 0755 "$payload_dir/$f" "$dest/$f"
done

echo "resty-auto-ssl bin payload installed:"
for f in $PAYLOAD_FILES; do
  echo "  $payload_dir/$f -> $dest/$f (0755)"
done
