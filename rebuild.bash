#!/usr/bin/env bash
# Rebuild csound.node with cmake-js (Csound 7 only; CsoundAC composition is wasm).
#
# Usage:
#   ./rebuild.bash [CMake -D flags...] [other cmake-js options...]
#
# CMake-style -DVAR=value is rewritten to cmake-js --CDVAR=value. Do not pass raw
# -D... to cmake-js: there, -D means "debug build" and breaks option parsing.
#
# Optional env:
#   CSOUND_ROOT          — install prefix for Csound 7 (bin/, lib/, include/ or Frameworks)
#   NW_RUNTIME           — e.g. nw (default: node for stock Node headers)
#   NW_RUNTIME_VERSION   — NW.js SDK version when NW_RUNTIME=nw

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT}"

USER_CMAKE_DEFS=()
PASSTHROUGH=()
while (($# > 0)); do
  case "$1" in
    -D)
      if [[ -z "${2:-}" ]]; then
        echo "rebuild.bash: missing argument after -D" >&2
        exit 1
      fi
      if [[ "$2" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
        USER_CMAKE_DEFS+=(--CD"${BASH_REMATCH[1]}=${BASH_REMATCH[2]}")
      else
        echo "rebuild.bash: expected NAME=value after -D, got: $2" >&2
        exit 1
      fi
      shift 2
      ;;
    -D[A-Za-z_]*=*)
      _pair="${1#-D}"
      if [[ "${_pair}" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
        USER_CMAKE_DEFS+=(--CD"${BASH_REMATCH[1]}=${BASH_REMATCH[2]}")
      else
        PASSTHROUGH+=("$1")
      fi
      shift
      ;;
    --define=*)
      _pair="${1#--define=}"
      if [[ "${_pair}" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
        USER_CMAKE_DEFS+=(--CD"${BASH_REMATCH[1]}=${BASH_REMATCH[2]}")
      else
        PASSTHROUGH+=("$1")
      fi
      shift
      ;;
    *)
      PASSTHROUGH+=("$1")
      shift
      ;;
  esac
done
if ((${#PASSTHROUGH[@]} > 0)); then
  set -- "${PASSTHROUGH[@]}"
else
  set --
fi

if [[ -f "${ROOT}/native/package.json" ]]; then
  if [[ ! -d "${ROOT}/native/node_modules/node-addon-api" ]]; then
    (cd "${ROOT}/native" && npm install --no-audit --no-fund)
  fi
  export NODE_ADDON_API_INCLUDE="$(
    cd "${ROOT}/native" && node -e "const p=require('path'); const n=require('node-addon-api'); process.stdout.write(p.resolve(process.cwd(), n.include_dir));"
  )"
else
  if command -v node >/dev/null 2>&1; then
    _napi="$(
      node -e "try{const p=require('path');const n=require('node-addon-api');process.stdout.write(p.resolve(process.cwd(),n.include_dir));}catch(e){}" 2>/dev/null || true
    )"
    if [[ -n "${_napi}" ]]; then
      export NODE_ADDON_API_INCLUDE="${_napi}"
    fi
  fi
fi

if [[ -z "${NODE_ADDON_API_INCLUDE:-}" ]]; then
  echo "Could not resolve node-addon-api include path." >&2
  echo "Add native/package.json + run (cd native && npm install), or: npm install -g node-addon-api" >&2
  exit 1
fi

CMAKE_EXTRAS=()

if [[ -n "${CSOUND_ROOT:-}" ]]; then
  export CSOUND_ROOT
  CMAKE_EXTRAS+=(--CDCSOUND_ROOT_HINT="${CSOUND_ROOT}")
  echo "Using CSOUND_ROOT=${CSOUND_ROOT}"
fi

if ((${#USER_CMAKE_DEFS[@]} > 0)); then
  CMAKE_EXTRAS+=("${USER_CMAKE_DEFS[@]}")
fi

echo "NODE_ADDON_API_INCLUDE=${NODE_ADDON_API_INCLUDE}"
echo "Running cmake-js rebuild..." >&2

if command -v cmake-js >/dev/null 2>&1; then
  exec cmake-js rebuild \
    ${NW_RUNTIME:+--runtime "${NW_RUNTIME}"} \
    ${NW_RUNTIME_VERSION:+--runtime-version "${NW_RUNTIME_VERSION}"} \
    ${CMAKE_EXTRAS[@]+"${CMAKE_EXTRAS[@]}"} \
    "$@"
else
  exec npx --yes cmake-js rebuild \
    ${NW_RUNTIME:+--runtime "${NW_RUNTIME}"} \
    ${NW_RUNTIME_VERSION:+--runtime-version "${NW_RUNTIME_VERSION}"} \
    ${CMAKE_EXTRAS[@]+"${CMAKE_EXTRAS[@]}"} \
    "$@"
fi
