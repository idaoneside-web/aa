#!/bin/bash
#
# Phase 10.1 - Install Node.js + Ollama and pull qwen2.5:3b
# Target: MacBook Pro (Late 2013), Intel i7, 16 GB RAM, macOS Big Sur 11.7.x
#
# Usage (from Terminal on the Mac):
#   bash phase10.1-setup.sh 2>&1 | tee phase10.1-raw.log
#   bash phase10.1-setup.sh --legacy-ollama 2>&1 | tee phase10.1-raw.log
#
# Default: installs the *current* Ollama release (which requires macOS 14+).
# --legacy-ollama: installs Ollama 0.3.14, the last release whose x86_64
#   binary still targets macOS 11.3 (verified from its Mach-O load command).
#
# Safety:
#   * OLLAMA_NO_START=1 is passed to the installer, so it does NOT launch the
#     Ollama menu-bar app. Step 3/4 need a server, so this script starts a
#     temporary `ollama serve`, and stops it on exit (trap). Nothing is left
#     running afterwards.
#   * Does NOT install Commander.
#   * Big Sur ships bash 3.2 - this script avoids bash 4+ features.

set -u

LEGACY_OLLAMA=0
if [ "${1:-}" = "--legacy-ollama" ]; then
  LEGACY_OLLAMA=1
fi

MODEL="qwen2.5:3b"
OLLAMA_URL="http://127.0.0.1:11434"
OLLAMA_PID=""
WORKDIR="$(mktemp -d /tmp/phase10.1.XXXXXX)" || exit 1

cleanup() {
  if [ -n "$OLLAMA_PID" ] && kill -0 "$OLLAMA_PID" 2>/dev/null; then
    echo
    echo "[cleanup] stopping temporary ollama server (pid $OLLAMA_PID)"
    kill "$OLLAMA_PID" 2>/dev/null
    wait "$OLLAMA_PID" 2>/dev/null
  fi
  rm -rf "$WORKDIR"
}
trap cleanup EXIT INT TERM

section() { printf '\n\n========== %s ==========\n' "$*"; }
ts() { date '+%Y-%m-%d %H:%M:%S'; }
cmd() {
  printf '\n$ %s\n' "$*"
  "$@"
  local rc=$?
  printf '[exit code: %s]\n' "$rc"
  return $rc
}

NODE_OK=0
NODE_STATUS="NOT RUN"
OLLAMA_STATUS="NOT RUN"
PULL_STATUS="NOT RUN"
BENCH_OK=0
BENCH_STATUS="NOT RUN"

# ---------------------------------------------------------------- preflight
section "PREFLIGHT  ($(ts))"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "ABORT: this script must run on the target Mac (found $(uname -s))." >&2
  exit 1
fi

cmd sw_vers
cmd uname -m
cmd sysctl -n hw.memsize
cmd df -h /

MACOS_VERSION="$(sw_vers -productVersion)"
MACOS_MAJOR="${MACOS_VERSION%%.*}"
echo
echo "macOS version: $MACOS_VERSION (major $MACOS_MAJOR)"

AVAIL_KB="$(df -k / | awk 'NR==2 {print $4}')"
echo "Free disk space: $((AVAIL_KB / 1024 / 1024)) GB"
if [ "$AVAIL_KB" -lt 4194304 ]; then
  echo "ABORT: need at least 4 GB free (Node pkg + Ollama + ~1.9 GB model)." >&2
  exit 1
fi

# Ensure the Node installer's target dir is on PATH in this non-login shell.
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

# ------------------------------------------------------------------ step 1
section "STEP 1: Node.js  ($(ts))"
cd "$WORKDIR" || exit 1

if cmd curl -fL --progress-bar -o node.pkg https://nodejs.org/dist/v20.11.1/node-v20.11.1.pkg; then
  if cmd sudo installer -pkg node.pkg -target /; then
    :
  else
    echo "WARNING: installer returned non-zero." >&2
  fi
else
  echo "ERROR: Node.js package download failed." >&2
fi

hash -r
cmd node --version
cmd npm --version

NODE_MAJOR="$(node -v 2>/dev/null | sed 's/^v//' | cut -d. -f1)"
if [ -n "${NODE_MAJOR:-}" ] && [ "$NODE_MAJOR" -ge 18 ] 2>/dev/null; then
  NODE_OK=1
  NODE_STATUS="PASS (node $(node -v))"
  echo "PASS: node $(node -v) satisfies >= v18"
else
  NODE_STATUS="FAIL (node >= v18 not found)"
  echo "FAIL: node >= v18 is not available on PATH ($PATH)" >&2
fi

cmd rm -f node.pkg


# ------------------------------------------------------------------ step 2
section "STEP 2: Ollama  ($(ts))"

if [ "$LEGACY_OLLAMA" = "1" ]; then
  OLLAMA_TARGET="0.3.14"
  echo "Installing pinned Ollama $OLLAMA_TARGET (x86_64 minos = 11.3)."
  curl -fsSL https://ollama.com/install.sh | OLLAMA_VERSION="$OLLAMA_TARGET" OLLAMA_NO_START=1 sh
  INSTALL_RC=$?
else
  echo "Installing current Ollama release."
  echo "NOTE: ollama.com/docs/macos states macOS Sonoma 14+ is required."
  echo "      On Big Sur this is expected to install but fail to execute."
  curl -fsSL https://ollama.com/install.sh | OLLAMA_NO_START=1 sh
  INSTALL_RC=$?
fi
echo "[installer exit code: $INSTALL_RC]"

hash -r
echo
echo "$ command -v ollama"
command -v ollama || echo "ollama not found on PATH"
echo
echo "$ ollama --version"
ollama --version
VERSION_RC=$?
echo "[exit code: $VERSION_RC]"

if [ "$VERSION_RC" -ne 0 ]; then
  OLLAMA_STATUS="FAIL (ollama --version exited $VERSION_RC)"
  cat <<'EOF'

------------------------------------------------------------------
STEP 2 FAILED - stopping here, as instructed.

This is the known Big Sur blocker, not a bad download:
  * Current Ollama binaries declare a minimum of macOS 14.0
    (verified: LC_BUILD_VERSION minos=14.0.0 on v0.40.6).
  * A 11.7.10 -> 11.7.11 update does NOT help: the check is the
    major version, and 11.x < 14.0.
  * Typical error on 11.7.x is a dyld abort, e.g.
      dyld: Symbol not found: __ZTTNSt3__114basic_ifstreamIcNS_11char_traitsIcEEEE
      Referenced from: /usr/local/bin/ollama (which was built for Mac OS X 14.0)
      Expected in: /usr/lib/libc++.1.dylib
    or "built for macOS 14.0 which is newer than running OS".

Re-run with the last Big Sur-compatible build:
  bash phase10.1-setup.sh --legacy-ollama 2>&1 | tee phase10.1-raw.log
------------------------------------------------------------------
EOF
  printf '\nSUMMARY\n  Node.js  : %s\n  Ollama   : %s\n  Model    : %s\n  Benchmark: %s\n' \
    "$NODE_STATUS" "$OLLAMA_STATUS" "$PULL_STATUS" "$BENCH_STATUS"
  exit 2
fi

OLLAMA_STATUS="PASS ($(ollama --version 2>&1 | head -1))"

# ------------------------------------------------------------------ step 3
section "STEP 3: Pull $MODEL  ($(ts))"

server_up() {
  curl -fsS --max-time 2 "$OLLAMA_URL/api/version" >/dev/null 2>&1
}

if server_up; then
  echo "Ollama server already listening on $OLLAMA_URL"
else
  echo "No server on $OLLAMA_URL - starting a temporary 'ollama serve'."
  echo "(The installer was told not to launch the app; pull/run still need a server.)"
  nohup ollama serve > "$WORKDIR/ollama-serve.log" 2>&1 &
  OLLAMA_PID=$!
  echo "Temporary server pid: $OLLAMA_PID (will be stopped on exit)"
  i=0
  while [ "$i" -lt 30 ]; do
    if server_up; then break; fi
    i=$((i + 1))
    sleep 1
  done
  if ! server_up; then
    echo "ERROR: server did not come up within 30s. Log follows:" >&2
    sed -n '1,60p' "$WORKDIR/ollama-serve.log" >&2
    PULL_STATUS="FAIL (server did not start)"
    BENCH_STATUS="SKIPPED"
  fi
fi

if server_up; then
  cmd ollama pull "$MODEL"
  if [ $? -eq 0 ]; then
    PULL_STATUS="PASS"
  else
    PULL_STATUS="FAIL"
  fi
  cmd ollama list
fi

# ------------------------------------------------------------------ step 4
section "STEP 4: Inference benchmark  ($(ts))"

if [ "$PULL_STATUS" = "PASS" ]; then
  echo "$ /usr/bin/time -p ollama run $MODEL \"Write a 2-sentence story about a robot.\""
  echo
  if [ -x /usr/bin/time ]; then
    /usr/bin/time -p ollama run "$MODEL" "Write a 2-sentence story about a robot." 2>&1 | tee "$WORKDIR/inference.out"
  else
    # Fallback: bash's builtin timer (still prints a 'real' line).
    TIMEFORMAT='real %3R'
    { time ollama run "$MODEL" "Write a 2-sentence story about a robot." ; } 2>&1 | tee "$WORKDIR/inference.out"
  fi
  RUN_RC=${PIPESTATUS[0]}
  echo "[exit code: $RUN_RC]"
  if [ "$RUN_RC" -eq 0 ]; then
    BENCH_OK=1
    BENCH_STATUS="PASS (see 'real' above)"
  else
    BENCH_STATUS="FAIL (exit $RUN_RC)"
  fi
else
  echo "SKIPPED: model was not pulled successfully."
  BENCH_STATUS="SKIPPED"
fi

# ----------------------------------------------------------------- summary
section "SUMMARY  ($(ts))"
printf '  Node.js  : %s\n' "$NODE_STATUS"
printf '  Ollama   : %s\n' "$OLLAMA_STATUS"
printf '  Model    : %s\n' "$PULL_STATUS"
printf '  Benchmark: %s\n' "$BENCH_STATUS"

if [ "$NODE_OK" -ne 1 ] || [ "$PULL_STATUS" != "PASS" ] || [ "$BENCH_OK" -ne 1 ]; then
  exit 1
fi
exit 0
