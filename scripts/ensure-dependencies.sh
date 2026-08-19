#!/usr/bin/env bash
# ensure-dependencies.sh - Ensure external tools required by ~/.claude/scripts are installed.
#
# Cross-platform: Debian/WSL (apt) and macOS (Homebrew).
#
# Install strategy prefers package managers with built-in upgrade tooling:
# apt (incl. vendor apt repositories) on Linux and Homebrew on macOS, so tools
# stay upgradable via `apt upgrade` / `brew upgrade`. pip/npm/go/binary installs
# are used only for tools with no apt-repo or brew formula upstream.
#
# Tools are grouped into tiers. The "core" tier auto-installs by default; optional
# groups install only when requested with --group. Heavyweight/privileged tools
# (docker, cloud CLIs) are never auto-installed — they are reported with the command
# to run, because silently installing them is surprising and often wrong.
#
# Usage:
#   ensure-dependencies.sh                 # ensure core tier
#   ensure-dependencies.sh --check         # dry-run: report what's missing, install nothing
#   ensure-dependencies.sh --all           # core + every optional group
#   ensure-dependencies.sh --group security --group infra
#   ensure-dependencies.sh --list          # list known tools and their group
#   ensure-dependencies.sh --cron          # register auto-sync cron jobs only
#   ensure-dependencies.sh --docker         # configure non-sudo docker access only
#   ensure-dependencies.sh --all --no-cron  # install everything, skip cron
#
# --all also (a) configures Docker so the current user controls it without sudo,
# and (b) registers auto-sync cron: ~/.claude (claude-sync.sh) always, and the
# wiki (wiki-sync.sh) only if found under ~/projects or ~/projects/misc.
# Opt out with --no-docker / --no-cron.
#
# Idempotent: a tool already on PATH is skipped; cron uses a marker block;
# docker config no-ops when the user is already in the docker group.

set -euo pipefail

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; DIM='\033[2m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; DIM=''; NC=''
fi
err()  { echo -e "${RED}✗ $1${NC}" >&2; }
ok()   { echo -e "${GREEN}✓ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠ $1${NC}" >&2; }
info() { echo -e "${BLUE}ℹ $1${NC}"; }
step() { echo -e "${DIM}  → $1${NC}"; }

# Pick the user's shell rc file for persisting PATH entries.
shell_rc() {
  case "$(basename "${SHELL:-bash}")" in
    zsh)  echo "$HOME/.zshrc" ;;
    *)    echo "$HOME/.bashrc" ;;
  esac
}

# Append a `PATH` export for <dir> to the shell rc if not already present (idempotent).
persist_path() {
  local dir="$1" label="${2:-tool}" rc; rc="$(shell_rc)"
  [[ -d "$dir" ]] || mkdir -p "$dir" 2>/dev/null || true
  if [[ -f "$rc" ]] && grep -qF "$dir" "$rc"; then return 0; fi
  { echo ""; echo "# ensure-dependencies.sh: ${label} on PATH"; echo "export PATH=\"${dir}:\$PATH\""; } >> "$rc"
  step "persisted ${dir} to ${rc}"
}

# Persist fnm shell integration (so `fnm use`/auto-switch works in new shells).
persist_fnm_shell_init() {
  local fnm="$1" rc; rc="$(shell_rc)"
  [[ -f "$rc" ]] && grep -qF "fnm env" "$rc" && return 0
  { echo ""; echo "# ensure-dependencies.sh: fnm (node switcher)"; \
    echo "command -v fnm >/dev/null && eval \"\$(fnm env --use-on-cd --shell bash)\""; } >> "$rc"
  step "persisted fnm shell init to ${rc}"
}

# Register the auto-sync cron jobs (commit/pull/push) idempotently.
#   - ~/.claude config sync: always (if claude-sync.sh present)
#   - wiki sync + qmd reindex: only if wiki-sync.sh is found under ~/projects
#     or ~/projects/misc (location-conditional)
# Uses an INLINE per-job PATH (not a global crontab PATH=) so other cron entries
# are untouched, and a marker block so re-runs replace cleanly.
register_sync_cron() {
  command -v crontab &>/dev/null || { warn "crontab not found — skipping cron registration"; return 0; }
  # PATH each job needs: fnm-managed node/qmd + user bins + brew (mac) + system.
  local cron_path="${FNM_DEFAULT_BIN}:${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
  local begin="# >>> ensure-dependencies sync cron >>>"
  local end="# <<< ensure-dependencies sync cron <<<"
  local block=""

  local claude_sync="${HOME}/.claude/scripts/claude-sync.sh"
  if [[ -x "$claude_sync" ]]; then
    block+="*/15 * * * * PATH=${cron_path} ${claude_sync} >> /tmp/claude-sync.log 2>&1"$'\n'
    step "cron: claude-sync every 15 min"
  else
    warn "claude-sync.sh not found/executable at ${claude_sync} — skipping its cron"
  fi

  # Wiki: conditional on the project living under ~/projects or ~/projects/misc.
  local wiki_dir="" cand
  for cand in "${HOME}/projects/wiki" "${HOME}/projects/misc/wiki" "${HOME}/project/misc/wiki" "${HOME}/project/wiki"; do
    if [[ -x "${cand}/scripts/wiki-sync.sh" ]]; then wiki_dir="$cand"; break; fi
  done
  if [[ -n "$wiki_dir" ]]; then
    block+="7,22,37,52 * * * * PATH=${cron_path} ${wiki_dir}/scripts/wiki-sync.sh >> /tmp/wiki-sync.log 2>&1"$'\n'
    step "cron: wiki-sync (${wiki_dir}) at :07/:22/:37/:52"
  else
    info "wiki not found under ~/projects or ~/projects/misc — skipping wiki cron"
  fi

  [[ -n "$block" ]] || { warn "no sync scripts found — nothing to register"; return 0; }

  # Preserve the user's crontab minus: our marker block, any prior sync-script
  # lines, and the legacy global PATH header from earlier manual installs.
  local current
  current=$(crontab -l 2>/dev/null | awk -v b="$begin" -v e="$end" '
    $0==b {skip=1; next}
    $0==e {skip=0; next}
    skip==1 {next}
    /claude-sync\.sh|wiki-sync\.sh/ {next}
    /^# Auto-sync: commit|^# PATH so cron|^# ~\/\.claude config|^# wiki:/ {next}
    /^PATH=.*fnm\/aliases\/default/ {next}
    /^# ={5,}$/ {next}
    {print}
  ')
  { [[ -n "$current" ]] && printf '%s\n' "$current"
    printf '%s\n%s%s\n' "$begin" "$block" "$end"; } | crontab -
  ok "sync cron registered — view with: crontab -l"
}

# Configure Docker so the current non-sudo user can control it.
#   - Linux: ensure the `docker` group exists, add $USER to it, ensure the daemon
#     is running. (Group membership is root-equivalent — accepted dev-machine trade-off.)
#   - macOS: no-op — Docker Desktop runs as the user (no docker group).
# The new group only takes effect after re-login / `newgrp docker`.
configure_docker() {
  if [[ "$PLATFORM" == macos ]]; then
    info "docker: macOS uses Docker Desktop (runs as your user) — no group config needed"; return 0
  fi
  if ! command -v docker &>/dev/null; then
    warn "docker not installed — skipping non-sudo config (it's report-only; install Docker Engine first)"; return 0
  fi

  getent group docker &>/dev/null || { step "creating 'docker' group"; sudo groupadd docker || { err "could not create docker group"; return 1; }; }

  if id -nG "$USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
    ok "docker: ${USER} already in 'docker' group"
  else
    step "adding ${USER} to 'docker' group"
    sudo usermod -aG docker "$USER" || { err "could not add ${USER} to docker group"; return 1; }
    warn "docker: group added — run 'newgrp docker' or re-login for it to take effect in this shell"
  fi

  # Ensure the daemon is up (systemd hosts); otherwise note how to start it.
  if command -v systemctl &>/dev/null && systemctl list-unit-files 2>/dev/null | grep -q '^docker\.service'; then
    systemctl is-active --quiet docker || { step "enabling + starting docker.service"; sudo systemctl enable --now docker || warn "could not start docker.service"; }
  elif ! pgrep -x dockerd &>/dev/null; then
    warn "dockerd not running and no systemd unit — start it via Docker Desktop or 'sudo dockerd' (WSL: 'sudo service docker start')"
  fi

  # Verify. The running shell lacks the new group until re-login, so test via sg too.
  if docker info &>/dev/null; then
    ok "docker: usable without sudo"
  elif sg docker -c 'docker info' &>/dev/null; then
    ok "docker: configured — effective in new shells (re-login or 'newgrp docker')"
  else
    info "docker: configured; after re-login verify with 'docker ps' (daemon may also need starting)"
  fi
}

# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/platform.sh"
case "$(env_platform)" in
  darwin)    PLATFORM="macos" ;;
  linux|wsl) PLATFORM="linux" ;;
  *) err "Unsupported OS (only Debian/WSL Linux and macOS are supported)"; exit 1 ;;
esac

# Presence check for a dependency probe. Most probes are executables (command -v);
# a `lib:<name>` probe instead tests for a shared library via ldconfig, for
# dependencies that ship no CLI of their own (e.g. Playwright's browser system
# libraries). On macOS shared-lib probes are treated as present (the installer
# no-ops there).
dep_present() {
  local p="$1"
  case "$p" in
    lib:*) [[ "$PLATFORM" == macos ]] && return 0
           ldconfig -p 2>/dev/null | grep -q "${p#lib:}\.so" ;;
    *)     command -v "$p" &>/dev/null ;;
  esac
}

# ---------------------------------------------------------------------------
# Dependency table
# ---------------------------------------------------------------------------
# Each entry: "probe|group|method:arg"
#   probe   - command name to test with `command -v`
#   group   - core | security | infra | media | testing | report
#   method  - how to install:
#               apt:<pkg>      apt-get package (linux)
#               brew:<pkg>     homebrew formula (macos)
#               both:<pkg>     same package name on apt AND brew
#               pip:<pkg>      uv pip / pip install
#               npm:<pkg>      npm -g install
#               go:<path>      go install <path>@latest
#               script:<id>    bespoke installer (see install_script)
#               report:<text>  never auto-install; print <text> as guidance
#
# Multiple methods separated by ';' are tried by platform relevance.
DEPS=(
  # --- core: needed by many scripts, safe to auto-install ---
  "jq|core|both:jq"
  "curl|core|both:curl"
  "git|core|both:git"
  "yq|core|brew:yq;pip:yq"          # macOS=Go yq, Linux=Python yq — yaml.sh handles both
  "uuidgen|core|apt:uuid-runtime"   # present by default on macOS
  "shellcheck|core|both:shellcheck"
  "node|core|script:node"           # via fnm switcher; provides npm/npx too

  # --- web: URL loaders + browser automation for agents ---
  "trafilatura|web|pip:trafilatura"     # static-page markdown extractor
  "crwl|web|script:crawl4ai"            # crawl4ai JS-rendered extractor (CLI: crwl)
  "agent-browser|web|npm:agent-browser" # token-efficient agent browser driver

  # --- agent: CLI agent tooling ---
  "claude|agent|script:claude"          # Claude Code CLI (native installer → ~/.local/bin)
  "herdr|agent|brew:herdr;script:herdr" # terminal agent multiplexer (AGPL-3.0)
  "glow|agent|brew:glow;script:glow"    # terminal markdown renderer
  "qmd|agent|npm:@tobilu/qmd"           # local wiki/docs search (BM25+vector) — qmd search/vsearch

  # --- security scanners ---
  # trivy: apt repo (Debian) / brew (macOS) — both give managed `upgrade`.
  "trivy|security|script:trivy"
  # semgrep/pip-audit: no apt repo upstream; brew on macOS, pip on Linux.
  "semgrep|security|brew:semgrep;pip:semgrep"
  "gitleaks|security|brew:gitleaks;script:gitleaks"
  "pip-audit|security|brew:pip-audit;pip:pip-audit"
  # go toolchain — prerequisite for govulncheck (which ships only via `go install`).
  "go|security|brew:go;apt:golang-go"
  "govulncheck|security|go:golang.org/x/vuln/cmd/govulncheck"

  # --- infra / cloud / CI (report-only for heavyweight & privileged) ---
  "gh|infra|brew:gh;script:gh"
  "glab|infra|brew:glab;script:glab"
  "infisical|infra|brew:infisical;script:infisical"
  "terraform|infra|report:See https://developer.hashicorp.com/terraform/install"
  "docker|report|report:Install Docker Desktop (macOS) or Docker Engine (Debian) — see https://docs.docker.com/engine/install/"
  "aws|infra|brew:awscli;script:aws"
  "az|report|report:Install Azure CLI — https://learn.microsoft.com/cli/azure/install-azure-cli"
  "bq|report|report:Install Google Cloud SDK (gcloud) — https://cloud.google.com/sdk/docs/install"
  "ansible|infra|both:ansible"

  # --- media (training-videos) ---
  "ffmpeg|media|both:ffmpeg"
  "ffprobe|media|both:ffmpeg"
  "edge-tts|media|pip:edge-tts"

  # --- testing / load ---
  "bats|testing|brew:bats-core;apt:bats"
  "newman|testing|npm:newman"
  "k6|testing|brew:k6;script:k6"
  "locust|testing|pip:locust"
  # Playwright browser system libraries (no CLI of its own — probe a representative
  # shared lib). Needed for headless chromium in Playwright E2E suites.
  "lib:libnspr4|testing|script:playwright-deps"
)

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
CHECK_ONLY=false
DO_CRON=false
DO_DOCKER=false
INSTALL_REQUESTED=false   # true once --all or --group is seen
WANT_GROUPS=("core")

# Portable (bash 3.2 compatible) membership check, replaces an associative-array
# set — this script must run on a fresh Mac before Homebrew/bash 4 exist.
is_group_wanted() {
  local needle="$1" g
  for g in "${WANT_GROUPS[@]}"; do
    [[ "$g" == "$needle" ]] && return 0
  done
  return 1
}

usage() { grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -30; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check|-n)  CHECK_ONLY=true; shift ;;
    --all)       WANT_GROUPS=(core web agent security infra media testing report)
                 INSTALL_REQUESTED=true; DO_CRON=true; DO_DOCKER=true; shift ;;
    --cron)      DO_CRON=true; shift ;;       # register sync cron
    --no-cron)   DO_CRON=false; shift ;;      # opt out even with --all
    --docker)    DO_DOCKER=true; shift ;;     # configure non-sudo docker access
    --no-docker) DO_DOCKER=false; shift ;;    # opt out even with --all
    --group|-g)  [[ -z "${2:-}" ]] && { err "--group needs a value"; exit 1; }
                 WANT_GROUPS+=("$2"); INSTALL_REQUESTED=true; shift 2 ;;
    --list)
        printf '%-14s %-10s %s\n' "TOOL" "GROUP" "INSTALL"
        for e in "${DEPS[@]}"; do IFS='|' read -r p g m <<<"$e"; printf '%-14s %-10s %s\n' "$p" "$g" "$m"; done
        exit 0 ;;
    -h|--help)  usage ;;
    *) err "Unknown argument: $1"; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Package-manager bootstrap
# ---------------------------------------------------------------------------
PKG_UPDATED=false

# Remove apt repos whose signed-by keyring is missing or empty. A corrupt keyring
# (e.g. an interrupted gpg --recv-keys leaving a 0-byte file) makes EVERY
# `apt-get update` fail, which silently breaks unrelated installs. Run once up front.
repair_apt_repos() {
  [[ "$PLATFORM" == linux ]] || return 0
  command -v apt-get &>/dev/null || return 0
  local list key
  for list in /etc/apt/sources.list.d/*.list; do
    [[ -f "$list" ]] || continue
    key=$(grep -hoE 'signed-by=[^] ]*' "$list" 2>/dev/null | head -1 | cut -d= -f2)
    [[ -n "$key" ]] || continue
    # Broken if missing, empty, OR present-but-unparseable (the "EOF/failed to parse" case).
    if [[ ! -s "$key" ]] || ! gpg --no-default-keyring --keyring "$key" --list-keys &>/dev/null; then
      warn "removing apt repo with missing/corrupt keyring: $(basename "$list") (→ $key)"
      sudo rm -f "$list"
    fi
  done
}
apt_install() {
  local pkg="$1"
  command -v apt-get &>/dev/null || { err "apt-get not found — cannot install $pkg"; return 1; }
  if ! $PKG_UPDATED; then step "apt-get update"; sudo apt-get update -qq && PKG_UPDATED=true; fi
  step "sudo apt-get install -y $pkg"
  sudo apt-get install -y -qq "$pkg"
}
brew_install() {
  command -v brew &>/dev/null || { err "Homebrew not found — install from https://brew.sh"; return 1; }
  step "brew install $1"; brew install "$1"
}
# fnm (node switcher) install dir + the stable "default" node bin that we pin onto PATH.
FNM_DIR="${FNM_DIR:-$HOME/.local/share/fnm}"
FNM_DEFAULT_BIN="${FNM_DIR}/aliases/default/bin"

# Make a node-managed bin dir usable for the rest of this run.
activate_node_path() {
  [[ -d "$FNM_DEFAULT_BIN" ]] && export PATH="${FNM_DEFAULT_BIN}:${PATH}"
  hash -r 2>/dev/null || true
}

pip_install() {
  # uv tool / pipx / pip --user all target ~/.local/bin, which is already on PATH.
  if command -v uv &>/dev/null; then step "uv tool install $1"; uv tool install "$1" 2>/dev/null || uv pip install --system "$1"
  elif command -v pipx &>/dev/null; then step "pipx install $1"; pipx install "$1"
  elif command -v pip3 &>/dev/null; then step "pip3 install --user $1"; pip3 install --user "$1"
  else err "no uv/pipx/pip3 available to install $1"; return 1; fi
}
npm_install() {
  # Prefer the fnm-managed node (avoids a broken Windows/nvm4w npm earlier on PATH).
  activate_node_path
  if ! command -v npm &>/dev/null || [[ "$(command -v npm)" == /mnt/c/* ]]; then
    err "npm not found (or only a non-Linux npm on PATH) — the 'node' dependency must install first"; return 1
  fi
  # With fnm, global installs land in the node version's bin == $FNM_DEFAULT_BIN (on PATH).
  step "npm install -g $1"; npm install -g "$1"
}
go_install() {
  command -v go &>/dev/null || { err "go not found — install Go first to get ${1##*/}"; return 1; }
  # Force the binary into an on-PATH dir instead of the default ~/go/bin (not on PATH here).
  mkdir -p "$HOME/.local/bin"
  step "GOBIN=~/.local/bin go install $1@latest"; GOBIN="$HOME/.local/bin" go install "$1@latest"
}

# Bespoke installers for tools with official scripts / repos.
install_script() {
  case "$1" in
    node)
      # Install fnm (node version switcher), then Node LTS via it, then pin a stable
      # "default" alias whose bin dir we add to PATH (now + persisted in shell rc).
      if ! command -v fnm &>/dev/null && [[ ! -x "${FNM_DIR}/fnm" ]]; then
        if [[ "$PLATFORM" == macos ]]; then brew_install fnm
        elif command -v cargo &>/dev/null; then step "cargo install fnm"; cargo install fnm
        else step "fnm install script"
             curl -fsSL https://fnm.vercel.app/install | bash -s -- --install-dir "$FNM_DIR" --skip-shell; fi
      fi
      local FNM; FNM="$(command -v fnm || echo "${FNM_DIR}/fnm")"
      [[ -x "$FNM" ]] || { err "node: fnm not available after install"; return 1; }
      export PATH="$(dirname "$FNM"):${PATH}"
      step "fnm install --lts && fnm default lts-latest"
      "$FNM" install --lts && "$FNM" default lts-latest || { err "node: fnm failed to install Node LTS"; return 1; }
      # Activate for this process and persist for future shells.
      eval "$("$FNM" env --shell bash)" 2>/dev/null || true
      activate_node_path
      persist_path "$FNM_DEFAULT_BIN" "fnm default node"
      persist_fnm_shell_init "$FNM"
      command -v node &>/dev/null ;;
    claude)
      # Claude Code native installer → ~/.local/bin (already on PATH); works on macOS + Linux.
      step "Claude Code native installer"
      curl -fsSL https://claude.ai/install.sh | bash ;;
    herdr)
      [[ "$PLATFORM" == macos ]] && { brew_install herdr; return; }
      step "herdr install script (AGPL-3.0 agent multiplexer)"
      curl -fsSL https://herdr.dev/install.sh | sh ;;
    glow)
      [[ "$PLATFORM" == macos ]] && { brew_install glow; return; }
      step "Charm apt repo (glow, apt-managed upgrades)"
      sudo mkdir -p /etc/apt/keyrings \
      && curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor --yes -o /etc/apt/keyrings/charm.gpg \
      && echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list >/dev/null \
      && sudo apt-get update -qq && sudo apt-get install -y -qq glow ;;
    crawl4ai)
      pip_install crawl4ai || return 1
      # crawl4ai needs a one-time browser/runtime setup; the CLI is `crwl`.
      if command -v crawl4ai-setup &>/dev/null; then step "crawl4ai-setup (browsers)"; crawl4ai-setup || warn "crawl4ai-setup reported issues — run it manually if 'crwl' misbehaves"; fi ;;
    trivy)
      [[ "$PLATFORM" == macos ]] && { brew_install trivy; return; }
      step "Trivy apt repo (apt-managed upgrades)"
      sudo apt-get install -y -qq wget gnupg \
      && wget -qO- https://aquasecurity.github.io/trivy-repo/deb/public.key | gpg --dearmor | sudo tee /usr/share/keyrings/trivy.gpg >/dev/null \
      && echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb generic main" | sudo tee /etc/apt/sources.list.d/trivy.list >/dev/null \
      && sudo apt-get update -qq && sudo apt-get install -y -qq trivy ;;
    gitleaks)
      [[ "$PLATFORM" == macos ]] && { brew_install gitleaks; return; }
      err "gitleaks: no upstream apt repo — download a release binary from https://github.com/gitleaks/gitleaks/releases"; return 1 ;;
    gh)
      [[ "$PLATFORM" == macos ]] && { brew_install gh; return; }
      step "GitHub CLI apt repo"
      (type -p wget >/dev/null || sudo apt-get install -y -qq wget) \
      && sudo mkdir -p -m 755 /etc/apt/keyrings \
      && wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null \
      && sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
      && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null \
      && sudo apt-get update -qq && sudo apt-get install -y -qq gh ;;
    glab)
      [[ "$PLATFORM" == macos ]] && { brew_install glab; return; }
      # No official apt repo upstream; install the official release .deb (dpkg-managed) by arch.
      local g_arch deb_url tmp_deb rc=0
      case "$(uname -m)" in
        x86_64|amd64) g_arch="amd64" ;;
        aarch64|arm64) g_arch="arm64" ;;
        *) err "glab: unsupported arch $(uname -m)"; return 1 ;;
      esac
      step "querying latest glab release (.deb, ${g_arch})"
      deb_url=$(curl -fsSL "https://gitlab.com/api/v4/projects/gitlab-org%2Fcli/releases/permalink/latest" \
        | grep -oE "https://[^\"]*_linux_${g_arch}\.deb" | head -1)
      [[ -z "$deb_url" ]] && { err "glab: could not resolve latest .deb URL from GitLab API"; return 1; }
      tmp_deb=$(mktemp --suffix=.deb)
      step "downloading $deb_url"
      if curl -fsSL -o "$tmp_deb" "$deb_url"; then
        step "sudo dpkg -i (apt-managed)"; sudo dpkg -i "$tmp_deb" || rc=$?
      else rc=1; fi
      rm -f "$tmp_deb"
      return "$rc" ;;
    infisical)
      [[ "$PLATFORM" == macos ]] && { brew_install infisical; return; }
      step "Infisical apt repo"
      curl -1sLf 'https://artifacts-cli.infisical.com/setup.deb.sh' | sudo -E bash \
      && sudo apt-get install -y -qq infisical ;;
    aws)
      [[ "$PLATFORM" == macos ]] && { brew_install awscli; return; }
      # AWS publishes no apt repo; use the official v2 zip installer (self-updating via `aws` itself).
      local a_arch tmp_dir rc=0
      case "$(uname -m)" in
        x86_64|amd64)  a_arch="x86_64" ;;
        aarch64|arm64) a_arch="aarch64" ;;
        *) err "aws: unsupported arch $(uname -m)"; return 1 ;;
      esac
      if ! command -v unzip &>/dev/null; then
        sudo apt-get install -y -qq unzip || { err "aws: 'unzip' is required but could not be installed"; return 1; }
      fi
      tmp_dir=$(mktemp -d)
      step "downloading AWS CLI v2 (${a_arch})"
      if curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${a_arch}.zip" -o "$tmp_dir/awscliv2.zip" \
        && unzip -q "$tmp_dir/awscliv2.zip" -d "$tmp_dir" \
        && step "sudo ./aws/install --update" \
        && sudo "$tmp_dir/aws/install" --update; then rc=0; else rc=1; fi
      rm -rf "$tmp_dir"
      return "$rc" ;;
    k6)
      [[ "$PLATFORM" == macos ]] && { brew_install k6; return; }
      step "k6 apt repo (apt-managed upgrades)"
      local k6_key=/usr/share/keyrings/k6-archive-keyring.gpg
      sudo rm -f "$k6_key"   # drop any 0-byte/corrupt leftover that would poison apt
      # Fetch the signing key over HTTPS (deterministic); fall back to the keyserver.
      if ! curl -fsSL https://dl.k6.io/key.gpg | sudo gpg --dearmor --yes -o "$k6_key"; then
        sudo gpg --no-default-keyring --keyring "$k6_key" --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys C5AD17C747E3415A3642D57D77C6C491D6AC1D69
      fi
      [[ -s "$k6_key" ]] || { err "k6: could not obtain a valid signing key"; return 1; }
      echo "deb [signed-by=${k6_key}] https://dl.k6.io/deb stable main" | sudo tee /etc/apt/sources.list.d/k6.list >/dev/null \
      && sudo apt-get update -qq && sudo apt-get install -y -qq k6 ;;
    playwright-deps)
      # Install the OS shared libraries Playwright's bundled browsers need
      # (libnspr4/libnss3/libatk/… on Debian). Playwright's own install-deps is
      # version-aware across Debian releases, so prefer it over a hand-pinned
      # apt list. Run under sudo so the internal apt-get calls don't re-prompt.
      [[ "$PLATFORM" == macos ]] && { info "playwright: macOS needs no extra browser system libraries"; return 0; }
      activate_node_path
      command -v npx &>/dev/null || { err "playwright-deps: npx required (the 'node' dependency must install first)"; return 1; }
      step "sudo npx playwright install-deps chromium (browser system libraries)"
      sudo env "PATH=$PATH" npx --yes playwright install-deps chromium ;;
    *) err "no bespoke installer for $1"; return 1 ;;
  esac
}

# Dispatch a method spec (e.g. "both:jq;pip:yq") for the current platform.
install_tool() {
  local probe="$1" spec="$2" method arg
  IFS=';' read -ra methods <<<"$spec"
  # Pick the method that fits this platform; fall back to first usable.
  for m in "${methods[@]}"; do
    method="${m%%:*}"; arg="${m#*:}"
    case "$method" in
      both)   [[ "$PLATFORM" == macos ]] && brew_install "$arg" || apt_install "$arg"; return ;;
      apt)    [[ "$PLATFORM" == linux ]] && { apt_install "$arg"; return; } ;;
      brew)   [[ "$PLATFORM" == macos ]] && { brew_install "$arg"; return; } ;;
      pip)    pip_install "$arg"; return ;;
      npm)    npm_install "$arg"; return ;;
      go)     go_install "$arg"; return ;;
      script) install_script "$arg"; return ;;
      report) warn "$probe: $arg"; return 2 ;;
    esac
  done
  err "$probe: no install method applicable on $PLATFORM (spec: $spec)"; return 1
}

# Actions-only mode: --cron and/or --docker passed without --all/--group → run
# just those actions (no tool installs) and exit.
if ! $INSTALL_REQUESTED && ! $CHECK_ONLY && { $DO_CRON || $DO_DOCKER; }; then
  activate_node_path
  $DO_DOCKER && { info "Configuring Docker for non-sudo access"; configure_docker; }
  $DO_CRON   && { info "Registering auto-sync cron jobs"; register_sync_cron; }
  exit 0
fi

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
info "Platform: $PLATFORM | groups: ${WANT_GROUPS[*]} | mode: $([[ $CHECK_ONLY == true ]] && echo check || echo install)"
# If fnm already manages a default node, put it on PATH up front so node (and its
# npm-installed CLIs) are detected as present instead of triggering a redundant reinstall.
activate_node_path
command -v fnm >/dev/null 2>&1 && eval "$(fnm env --shell bash 2>/dev/null)" 2>/dev/null || true
$CHECK_ONLY || repair_apt_repos   # clean broken apt repos so unrelated installs don't fail
echo

present=0 installed=0 missing=0 reported=0 failed=0
MISSING_LIST=()

for entry in "${DEPS[@]}"; do
  IFS='|' read -r probe group spec <<<"$entry"
  is_group_wanted "$group" || continue

  if dep_present "$probe"; then
    ok "$probe"; present=$((present+1)); continue
  fi

  # Report-only tools (and the 'report' group): never auto-install.
  is_report=false
  [[ "$spec" == report:* || "$group" == report ]] && is_report=true

  if $CHECK_ONLY; then
    if $is_report; then warn "$probe missing — ${spec#report:}"; reported=$((reported+1))
    else warn "$probe missing — would install ($spec)"; missing=$((missing+1)); MISSING_LIST+=("$probe"); fi
    continue
  fi

  if $is_report; then
    warn "$probe missing — ${spec#report:}"; reported=$((reported+1)); continue
  fi

  warn "$probe missing — installing…"
  if install_tool "$probe" "$spec"; then
    hash -r 2>/dev/null || true   # refresh PATH lookup cache so a just-installed binary resolves
    if dep_present "$probe"; then ok "$probe installed${probe:+ → }$(command -v "$probe" 2>/dev/null || true)"; installed=$((installed+1))
    else err "$probe install ran but command still not found (may need a new shell/PATH)"; failed=$((failed+1)); fi
  else
    rc=$?
    [[ $rc -eq 2 ]] && reported=$((reported+1)) || { err "$probe install failed"; failed=$((failed+1)); MISSING_LIST+=("$probe"); }
  fi
done

# ---------------------------------------------------------------------------
# PATH audit — confirm every requested tool resolves; report dirs to add if not.
# ---------------------------------------------------------------------------
if ! $CHECK_ONLY; then
  hash -r 2>/dev/null || true
  echo
  info "PATH audit (dirs ensured: ${FNM_DEFAULT_BIN}, ~/.local/bin, ~/.npm-global/bin)"
  not_on_path=()
  for entry in "${DEPS[@]}"; do
    IFS='|' read -r probe group spec <<<"$entry"
    is_group_wanted "$group" || continue
    [[ "$spec" == report:* || "$group" == report ]] && continue
    dep_present "$probe" || not_on_path+=("$probe")
  done
  if [[ ${#not_on_path[@]} -eq 0 ]]; then
    ok "all requested tools resolve on PATH"
  else
    warn "not yet on PATH (open a new shell to pick up persisted exports, or install prerequisite): ${not_on_path[*]}"
  fi
fi

# ---------------------------------------------------------------------------
# Cron registration (after installs, so node/qmd exist for the PATH it pins).
# ---------------------------------------------------------------------------
if $DO_DOCKER && ! $CHECK_ONLY; then
  echo
  info "Docker non-sudo access configuration"
  configure_docker
fi

if $DO_CRON && ! $CHECK_ONLY; then
  echo
  info "Auto-sync cron registration"
  register_sync_cron

  # Nightly maintenance jobs go to the platform scheduler, not cron: cron skips
  # anything scheduled while the machine is asleep/off, which is exactly when
  # these run. schedule-job.sh renders launchd agents on macOS and systemd user
  # timers on Linux/WSL from ~/.claude/scheduled-jobs.json.
  echo
  info "Scheduled maintenance jobs"
  if [[ -x "${HOME}/.claude/scripts/schedule-job.sh" ]]; then
    "${HOME}/.claude/scripts/schedule-job.sh" install --all --no-json || \
      warn "schedule-job.sh install failed — inspect with: schedule-job.sh list"
  else
    warn "schedule-job.sh not found/executable — skipping maintenance job registration"
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
info "Summary: ${present} present, ${installed} installed, ${missing} missing (check), ${reported} report-only, ${failed} failed"
if [[ ${#MISSING_LIST[@]} -gt 0 ]] && $CHECK_ONLY; then
  echo "Missing (installable): ${MISSING_LIST[*]}"
fi
if [[ $failed -gt 0 ]]; then
  err "Some installs failed: ${MISSING_LIST[*]}"
  exit 1
fi
exit 0
