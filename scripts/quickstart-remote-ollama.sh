#!/usr/bin/env bash
set -euo pipefail

# ── OpenJarvis Quickstart (Remote Ollama) ─────────────────────────────
# One-command setup for using a REMOTE Ollama for inference. Does NOT
# install, start, or pull a local Ollama — it assumes your inference runs
# on another machine (e.g. a GPU box) and that `~/.openjarvis/config.toml`
# points `[engine.ollama] host` at that remote endpoint.
#
# Usage:
#   git clone https://github.com/open-jarvis/OpenJarvis.git
#   cd OpenJarvis
#   ./scripts/quickstart-remote-ollama.sh
#
# Prereqs (do these once):
#   1. On the remote GPU box:  ollama serve --host 0.0.0.0  (and pull a model)
#   2. In ~/.openjarvis/config.toml:
#        [engine]
#        default = "ollama"
#        [engine.ollama]
#        host = "http://<remote-ip>:11434"
# ──────────────────────────────────────────────────────────────────────

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
BOLD='\033[1m'

info()  { echo -e "${BLUE}[info]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ok]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[warn]${NC}  $*"; }
fail()  { echo -e "${RED}[fail]${NC}  $*"; exit 1; }

CLEANUP_PIDS=()
cleanup() {
  echo ""
  info "Shutting down..."
  for pid in "${CLEANUP_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  ok "Done."
}
trap cleanup EXIT INT TERM

# ── Navigate to repo root ────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

echo -e "${BOLD}"
echo "  ┌──────────────────────────────────────┐"
echo "  │  OpenJarvis Quickstart (Remote Ollama) │"
echo "  └──────────────────────────────────────┘"
echo -e "${NC}"

# ── 1. Check Python ──────────────────────────────────────────────────
# Prefer python3, fall back to python (Windows / minimal distros that ship
# only the unversioned name).
info "Checking Python..."
if command -v python3 &>/dev/null; then
  PY_CMD="python3"
elif command -v python &>/dev/null; then
  PY_CMD="python"
else
  fail "Python 3 not found. Install from https://python.org"
fi
PY_VERSION=$("$PY_CMD" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
PY_MAJOR=$(echo "$PY_VERSION" | cut -d. -f1)
PY_MINOR=$(echo "$PY_VERSION" | cut -d. -f2)
if [ "$PY_MAJOR" -ge 3 ] && [ "$PY_MINOR" -ge 10 ]; then
  ok "Python $PY_VERSION ($PY_CMD)"
else
  fail "Python 3.10+ required (found $PY_VERSION)"
fi

# ── 2. Check / install uv ───────────────────────────────────────────
info "Checking uv..."
if command -v uv &>/dev/null; then
  ok "uv $(uv --version 2>/dev/null | head -1)"
else
  warn "uv not found — installing..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
  ok "uv installed"
fi

# ── 3. Check Node.js ────────────────────────────────────────────────
info "Checking Node.js..."
if command -v node &>/dev/null; then
  NODE_VERSION=$(node --version)
  NODE_MAJOR=$(echo "$NODE_VERSION" | sed 's/v//' | cut -d. -f1)
  if [ "$NODE_MAJOR" -ge 18 ]; then
    ok "Node.js $NODE_VERSION"
  else
    fail "Node.js 18+ required (found $NODE_VERSION). Install from https://nodejs.org"
  fi
else
  fail "Node.js not found. Install from https://nodejs.org"
fi

# ── 4. (Skipped) Local Ollama ────────────────────────────────────────
# This variant does NOT install/start/pull a local Ollama. Inference is
# expected to run on a remote machine; see the header comment for config.

# ── 4b. Check remote Ollama is reachable ─────────────────────────────
# Read the endpoint from the live config (~/.openjarvis/config.toml) so we
# don't assume a static IP. We only check status — we do NOT start anything.
# Times out after 5s so the script fails fast if the remote is down.
info "Checking remote Ollama..."
CONFIG_PATH="$HOME/.openjarvis/config.toml"
if [[ ! -f "$CONFIG_PATH" ]]; then
  fail "No config at $CONFIG_PATH. Run the installer or create it (see header)."
fi

# Extract [engine.ollama] host from the TOML (robust to single/double quotes).
OLLAMA_HOST="$(sed -n '/\[engine.ollama\]/,/^\[/p' "$CONFIG_PATH" \
  | sed -n 's/^[[:space:]]*host[[:space:]]*=[[:space:]]*["'"'"']\([^"'"'"']*\)["'"'"'].*/\1/p' \
  | head -n1)"

if [[ -z "$OLLAMA_HOST" ]]; then
  warn "No [engine.ollama] host found in $CONFIG_PATH — skipping reachability check."
else
  if curl -sf --connect-timeout 5 --max-time 5 "${OLLAMA_HOST%/}/api/tags" &>/dev/null; then
    ok "Remote Ollama reachable at $OLLAMA_HOST"
  else
    fail "Remote Ollama at $OLLAMA_HOST is not reachable. Start it (e.g. 'ollama serve --host 0.0.0.0' on the remote) then re-run this script."
  fi
fi

# ── 5. Install Python dependencies ──────────────────────────────────
info "Installing Python dependencies..."
uv sync --extra desktop --extra tools-search --quiet 2>/dev/null \
  || uv sync --extra desktop --extra tools-search
ok "Python dependencies installed"

# ── 5b. Build Rust extension ──────────────────────────────────────
info "Building Rust extension..."
uv run maturin develop -m rust/crates/openjarvis-python/Cargo.toml --quiet 2>/dev/null \
  || uv run maturin develop -m rust/crates/openjarvis-python/Cargo.toml
ok "Rust extension built"

# ── 6. Install frontend dependencies ────────────────────────────────
info "Installing frontend dependencies..."
(cd frontend && npm install --silent 2>/dev/null || npm install)
ok "Frontend dependencies installed"

# ── 7. Start backend ────────────────────────────────────────────────
info "Starting backend API server on port 8000..."
if curl -sf http://localhost:8000/health &>/dev/null; then
  fail "An OpenJarvis server is already running on port 8000. Stop it before re-running quickstart so updated environment variables are applied."
fi
uv run jarvis serve --port 8000 &>/dev/null &
BACKEND_PID=$!
CLEANUP_PIDS+=("$BACKEND_PID")
sleep 3

if ! kill -0 "$BACKEND_PID" 2>/dev/null; then
  fail "Backend exited during startup. Run 'uv run jarvis serve --port 8000' to see the error."
elif curl -sf http://localhost:8000/health &>/dev/null; then
  ok "Backend running at http://localhost:8000"
else
  warn "Backend may still be starting..."
fi

# ── 8. Start frontend ──────────────────────────────────────────────
info "Starting frontend dev server on port 5173..."
(cd frontend && npm run dev) &>/dev/null &
CLEANUP_PIDS+=($!)
sleep 3
ok "Frontend running at http://localhost:5173"

# ── 9. Open browser ────────────────────────────────────────────────
URL="http://localhost:5173"
info "Opening $URL ..."
case "$(uname -s)" in
  Darwin) open "$URL" ;;
  Linux)  xdg-open "$URL" 2>/dev/null || true ;;
  MINGW*|MSYS*|CYGWIN*) cmd /c start "" "$URL" 2>/dev/null || true ;;
  *)      true ;;
esac

echo ""
echo -e "${GREEN}${BOLD}  OpenJarvis is running!${NC}"
echo ""
echo "  Chat UI:  http://localhost:5173"
echo "  API:      http://localhost:8000"
echo "  Inference: REMOTE Ollama (see ~/.openjarvis/config.toml)"
echo ""
echo "  Press Ctrl+C to stop all services."
echo ""

wait
