#!/usr/bin/env bash
#
# mcnet-setup.sh — Minecraft network provisioner (Velocity proxy + Paper lobby)
# Targets: Debian 13 (Trixie) and Raspberry Pi OS (Trixie-based), amd64 or arm64.
# No Bedrock support (no Geyser/Floodgate).
#
# MODES:
#   full   -> installs Java, MariaDB, Redis/Valkey; provisions /opt/minecraft/{proxy,lobby};
#             wires Velocity modern forwarding, LuckPerms(SQL+Redis), systemd services.
#             Must be run as root.
#   jars   -> no apt / no systemd / no DB / no root. Pulls Velocity + Paper 1.21.11 + plugins
#             into ./proxy and ./lobby in the CURRENT directory, accepts EULA, generates and
#             wires the forwarding secret, writes start scripts. Portable folder you can scp.
#
# Usage:
#   sudo ./mcnet-setup.sh full
#        ./mcnet-setup.sh jars
#
set -euo pipefail

# ------------------------------------------------------------------ config ---
PAPER_VERSION="1.21.11"          # pinned per request
VELOCITY_VERSION="latest"        # newest RECOMMENDED velocity build
BASE_FULL="/opt/minecraft"       # base dir in full mode
MC_USER="minecraft"              # system user in full mode
PROXY_PORT="25565"               # public-facing proxy port
LOBBY_PORT="25566"               # internal lobby port (not exposed publicly)
LOBBY_XMS="1G"
LOBBY_XMX="2G"                   # lower this on a Pi with <4G RAM
PROXY_XMS="512M"
PROXY_XMX="512M"

# Fill API requires a descriptive, non-generic User-Agent (no bare curl/wget).
# Change the contact URL to your own if you like.
USER_AGENT="mcnet-setup/1.0 (+https://github.com/zsigisti/mcnet-setup)"

# Backend (Paper) loader group used for Modrinth queries (comma-separated).
PAPER_LOADERS="paper,purpur,spigot,bukkit,folia"

# Lobby plugins:  source|id|display-name   (loader defaults to the Paper group)
LOBBY_PLUGINS=(
  "modrinth|luckperms|LuckPerms"
  "modrinth|viaversion|ViaVersion"
  "modrinth|viabackwards|ViaBackwards"
  "modrinth|viarewind|ViaRewind"
  "modrinth|grimac|GrimAC"
  "modrinth|placeholderapi|PlaceholderAPI"
  "modrinth|coreprotect|CoreProtect"
  "modrinth|worldedit|WorldEdit"
  "modrinth|worldguard|WorldGuard"
  "modrinth|tab-was-taken|TAB"
  "modrinth|decentholograms|DecentHolograms"
  "modrinth|fancynpcs|FancyNPCs"
  "modrinth|deluxemenus|DeluxeMenus"
  "github|MilkBowl/Vault|Vault"
)

# Proxy (Velocity) plugins:  source|id|display-name|loader
PROXY_PLUGINS=(
  "modrinth|luckperms|LuckPerms|velocity"
  "modrinth|maintenance|Maintenance|velocity"
)

# ------------------------------------------------------------------ output ---
if [[ -t 1 ]]; then
  C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[36m'; C_0=$'\e[0m'; C_BOLD=$'\e[1m'
else
  C_R=""; C_G=""; C_Y=""; C_B=""; C_0=""; C_BOLD=""
fi
log()  { printf '%s[*]%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

FAILED_PLUGINS=()

# --------------------------------------------------------------- utilities ---
genpw() { head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24; }
gensecret() { head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

# Reuse an existing forwarding secret on re-run so proxy/lobby stay in sync.
get_or_make_secret() { # FILE -> echoes secret (creating it if absent)
  local f="$1" s
  if [[ -s "$f" ]]; then cat "$f"; else s="$(gensecret)"; printf '%s' "$s" >"$f"; printf '%s' "$s"; fi
}

need_cmd() { command -v "$1" >/dev/null 2>&1; }

detect_os() {
  OS_ID="unknown"; OS_LIKE=""
  [[ -r /etc/os-release ]] && . /etc/os-release && OS_ID="${ID:-unknown}" && OS_LIKE="${ID_LIKE:-}"
  ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  case "$OS_ID" in
    debian|raspbian) : ;;
    *) if [[ "$OS_LIKE" == *debian* ]]; then :; else
         warn "Untested OS '$OS_ID'. This script targets Debian 13 / Raspberry Pi OS."
       fi ;;
  esac
  log "OS=$OS_ID  arch=$ARCH"
}

# curl wrapper: descriptive UA, retries, fail on HTTP error, globbing off
# (-g/--globoff prevents curl from interpreting [ ] in URLs as glob ranges).
fetch() { curl -fsSL -g --retry 3 --retry-delay 2 -A "$USER_AGENT" "$@"; }

# Build a JSON array string from a comma-separated list: "a,b" -> ["a","b"]
csv_to_json_array() { printf '%s' "$1" | jq -Rc 'split(",")'; }

# ------------------------------------------------------- PaperMC Fill v3 ------
# fill_download PROJECT VERSION CHANNEL OUTFILE
#   VERSION may be a concrete version (e.g. 1.21.11) or "latest".
#   CHANNEL is the preferred build channel (STABLE for paper, RECOMMENDED for velocity);
#   falls back to any build if the preferred channel is absent.
fill_url_for_version() { # PROJECT VERSION CHANNEL [STRICT]  -> "URL SHA256"
  local project="$1" version="$2" channel="$3" strict="${4:-0}" builds out
  builds="$(fetch "https://fill.papermc.io/v3/projects/${project}/versions/${version}/builds" || true)"
  [[ -z "$builds" ]] && return 1
  echo "$builds" | jq -e 'type=="array" and length>0' >/dev/null 2>&1 || return 1
  out="$(echo "$builds" | jq -r --arg ch "$channel" --argjson strict "$strict" '
    ([ .[] | select(.channel == $ch) ]) as $pref
    | (if ($pref|length) > 0 then $pref
       elif $strict == 1 then empty
       else . end)
    | sort_by(.id) | last
    | (.downloads."server:default" // (.downloads | to_entries[0].value))
    | "\(.url) \(.checksums.sha256 // "")"
  ')"
  [[ -z "$out" ]] && return 1
  echo "$out"
}

fill_download() { # PROJECT VERSION CHANNEL OUTFILE
  local project="$1" version="$2" channel="$3" out="$4" line url sha
  if [[ "$version" == "latest" ]]; then
    local versions v pass
    versions="$(fetch "https://fill.papermc.io/v3/projects/${project}" \
                 | jq -r '.versions | to_entries[] | .value[]' | sort -V -r)"
    line=""
    # pass 1: require the preferred channel (skips snapshots w/o a promoted build)
    # pass 2: accept any build, newest version first
    for pass in 1 0; do
      for v in $versions; do
        if line="$(fill_url_for_version "$project" "$v" "$channel" "$pass")" \
           && [[ -n "$line" && "$line" != "null null" ]]; then
          version="$v"; break 2
        fi
      done
    done
    [[ -z "${line:-}" ]] && die "No $project build found via Fill API."
  else
    line="$(fill_url_for_version "$project" "$version" "$channel")" \
      || die "$project $version not found on Fill API (is $version released yet?)."
  fi
  url="${line%% *}"; sha="${line##* }"
  [[ -z "$url" || "$url" == "null" ]] && die "Could not resolve $project download URL."
  log "Downloading $project ($version) ..."
  fetch -o "$out" "$url"
  if [[ -n "$sha" && "$sha" != "null" ]] && need_cmd sha256sum; then
    echo "${sha}  ${out}" | sha256sum -c - >/dev/null 2>&1 \
      && ok "$project verified (sha256)" || warn "$project checksum mismatch — keeping file anyway"
  else
    ok "$project downloaded"
  fi
}

# ------------------------------------------------------------- Modrinth -------
# modrinth_file_url SLUG LOADERS_CSV GAMEVERSION  -> URL (or empty)
# Query params are JSON arrays that MUST be URL-encoded; we let curl -G
# --data-urlencode handle encoding rather than putting raw [ ] " in the URL.
modrinth_file_url() {
  local slug="$1" loaders_csv="$2" gv="$3" lj resp withgv
  lj="$(csv_to_json_array "$loaders_csv")"      # e.g. ["paper","spigot"]
  local url="https://api.modrinth.com/v2/project/${slug}/version"
  # pass 1: constrain by game version; pass 2: loaders only (handles version-tag lag)
  for withgv in 1 0; do
    if [[ "$withgv" == 1 ]]; then
      resp="$(fetch -G --data-urlencode "loaders=${lj}" \
                       --data-urlencode "game_versions=[\"${gv}\"]" "$url" 2>/dev/null || true)"
    else
      resp="$(fetch -G --data-urlencode "loaders=${lj}" "$url" 2>/dev/null || true)"
    fi
    echo "$resp" | jq -e 'type=="array" and length>0' >/dev/null 2>&1 || continue
    echo "$resp" | jq -r '
      sort_by(.date_published) | reverse | .[0]
      | ((.files[] | select(.primary==true) | .url) // .files[0].url)
    '
    return 0
  done
  return 1
}

modrinth_resolve_slug() { # NAME -> slug via search (fallback when slug is wrong)
  fetch -G --data-urlencode "query=$1" \
           --data-urlencode 'facets=[["project_type:plugin"]]' \
           --data-urlencode 'limit=1' \
           "https://api.modrinth.com/v2/search" 2>/dev/null \
    | jq -r '.hits[0].slug // empty'
}

download_modrinth() { # SLUG NAME LOADERS GAMEVERSION OUTDIR
  local slug="$1" name="$2" loaders="$3" gv="$4" outdir="$5" url alt
  url="$(modrinth_file_url "$slug" "$loaders" "$gv" || true)"
  if [[ -z "${url:-}" ]]; then
    alt="$(modrinth_resolve_slug "$name" || true)"
    [[ -n "$alt" && "$alt" != "$slug" ]] && url="$(modrinth_file_url "$alt" "$loaders" "$gv" || true)"
  fi
  if [[ -z "${url:-}" || "$url" == "null" ]]; then
    warn "Could not resolve $name on Modrinth — skipping"; FAILED_PLUGINS+=("$name"); return 1
  fi
  fetch -o "${outdir}/$(basename "${url%%\?*}")" "$url" \
    && ok "  $name" || { warn "Download failed: $name"; FAILED_PLUGINS+=("$name"); }
}

download_github() { # OWNER/REPO NAME OUTDIR
  local repo="$1" name="$2" outdir="$3" url
  url="$(fetch "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
         | jq -r '[.assets[].browser_download_url
                   | select(test("(?i)\\.jar$"))
                   | select(test("(?i)(sources|javadoc)")|not)][0] // empty')"
  if [[ -z "$url" ]]; then
    warn "No release jar for $name ($repo) — skipping"; FAILED_PLUGINS+=("$name"); return 1
  fi
  fetch -o "${outdir}/$(basename "$url")" "$url" \
    && ok "  $name" || { warn "Download failed: $name"; FAILED_PLUGINS+=("$name"); }
}

download_plugins() { # OUTDIR SPEC...
  local outdir="$1"; shift
  mkdir -p "$outdir"
  local spec src id name loader
  for spec in "$@"; do
    IFS='|' read -r src id name loader <<<"$spec"
    case "$src" in
      modrinth) download_modrinth "$id" "$name" "${loader:-$PAPER_LOADERS}" "$PAPER_VERSION" "$outdir" || true ;;
      github)   download_github "$id" "$name" "$outdir" || true ;;
      *)        warn "Unknown plugin source '$src' for $name" ;;
    esac
  done
}

# ------------------------------------------------------- config writers -------
write_velocity_toml() { # DIR PORT LOBBY_PORT
  local dir="$1" port="$2" lport="$3"
  cat >"${dir}/velocity.toml" <<EOF
# Velocity config — generated by mcnet-setup.sh
config-version = "2.7"
bind = "0.0.0.0:${port}"
motd = "<#00aaff>Network</#00aaff> <gray>| Lobby"
show-max-players = 100
online-mode = true
force-key-authentication = true
prevent-client-proxy-connections = false
player-info-forwarding-mode = "modern"
forwarding-secret-file = "forwarding.secret"
announce-forge = false
kick-existing-players = false
ping-passthrough = "DISABLED"
enable-player-address-logging = true

[servers]
lobby = "127.0.0.1:${lport}"
try = ["lobby"]

[forced-hosts]

[advanced]
compression-threshold = 256
compression-level = -1
login-ratelimit = 3000
connection-timeout = 5000
read-timeout = 30000
haproxy-protocol = false
tcp-fast-open = false
bungee-plugin-message-channel = true
show-ping-requests = false
failover-on-unexpected-server-disconnect = true
announce-proxy-commands = true
log-command-executions = false
log-player-connections = true

[query]
enabled = false
port = ${port}
map = "Velocity"
show-plugins = false
EOF
}

write_lobby_configs() { # DIR SECRET PORT
  local dir="$1" secret="$2" port="$3"
  echo "eula=true" >"${dir}/eula.txt"
  cat >"${dir}/server.properties" <<EOF
# Paper lobby — generated by mcnet-setup.sh
# Bind to loopback only: reachable from the local proxy, never from the public internet.
server-ip=127.0.0.1
server-port=${port}
online-mode=false
prevent-proxy-connections=false
enforce-secure-profile=false
network-compression-threshold=-1
motd=Lobby
max-players=100
level-name=lobby
level-type=minecraft\:flat
gamemode=adventure
force-gamemode=true
difficulty=peaceful
spawn-protection=0
allow-flight=true
view-distance=6
simulation-distance=4
spawn-monsters=false
spawn-npcs=false
spawn-animals=false
generate-structures=false
allow-nether=false
enable-command-block=false
white-list=false
EOF
  # Paper merges missing keys with defaults on first boot; we seed only the proxy block.
  mkdir -p "${dir}/config"
  cat >"${dir}/config/paper-global.yml" <<EOF
# Seeded by mcnet-setup.sh — Paper fills the remaining defaults on first start.
proxies:
  velocity:
    enabled: true
    online-mode: true
    secret: '${secret}'
  bungee-cord:
    online-mode: false
EOF
}

seed_luckperms_sql_redis() { # PLUGINDIR DBPASS REDISPASS
  local dir="$1" dbpass="$2" redispass="$3"
  mkdir -p "${dir}/LuckPerms"
  cat >"${dir}/LuckPerms/config.yml" <<EOF
# Seeded by mcnet-setup.sh — LuckPerms uses built-in defaults for any key not listed here.
server: lobby
storage-method: mariadb
data:
  address: localhost:3306
  database: luckperms
  username: luckperms
  password: '${dbpass}'
  pool-settings:
    maximum-pool-size: 10
    minimum-idle: 5
    maximum-lifetime: 1800000
    connection-timeout: 5000
  table-prefix: 'luckperms_'
messaging-service: redis
redis:
  enabled: true
  address: localhost:6379
  password: '${redispass}'
EOF
}

# ------------------------------------------------------------- full mode ------
require_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "full mode must run as root (use sudo)."; }

install_packages() {
  log "Installing system packages ..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq curl jq openjdk-21-jre-headless mariadb-server ca-certificates >/dev/null
  # Redis on Trixie: prefer redis-server, fall back to valkey-server (wire-compatible).
  if apt-get install -y -qq redis-server >/dev/null 2>&1; then
    CACHE_SVC="redis-server"; CACHE_CONF="/etc/redis/redis.conf"
  elif apt-get install -y -qq valkey-server >/dev/null 2>&1; then
    CACHE_SVC="valkey-server"; CACHE_CONF="/etc/valkey/valkey.conf"
  else
    die "Neither redis-server nor valkey-server is installable from your repos."
  fi
  ok "Packages installed (cache: ${CACHE_SVC})"
}

setup_user_dirs() {
  id -u "$MC_USER" >/dev/null 2>&1 || useradd -r -m -d "$BASE_FULL" -s /usr/sbin/nologin "$MC_USER"
  mkdir -p "${BASE_FULL}/proxy" "${BASE_FULL}/lobby/plugins"
}

setup_mariadb() { # -> sets DB_PASS
  log "Configuring MariaDB ..."
  systemctl enable --now mariadb >/dev/null 2>&1 || systemctl enable --now mysql >/dev/null 2>&1 || true
  DB_PASS="$(genpw)"
  mysql <<SQL
CREATE DATABASE IF NOT EXISTS luckperms CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'luckperms'@'localhost' IDENTIFIED BY '${DB_PASS}';
ALTER USER 'luckperms'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON luckperms.* TO 'luckperms'@'localhost';
FLUSH PRIVILEGES;
SQL
  ok "MariaDB database 'luckperms' ready"
}

setup_cache() { # -> sets REDIS_PASS
  log "Configuring ${CACHE_SVC} ..."
  REDIS_PASS="$(genpw)"
  local marker="# mcnet-setup managed"
  if ! grep -q "$marker" "$CACHE_CONF" 2>/dev/null; then
    {
      echo ""
      echo "$marker"
      echo "bind 127.0.0.1 -::1"
      echo "protected-mode yes"
      echo "requirepass ${REDIS_PASS}"
    } >>"$CACHE_CONF"
  else
    sed -i "s/^requirepass .*/requirepass ${REDIS_PASS}/" "$CACHE_CONF"
  fi
  systemctl enable --now "$CACHE_SVC" >/dev/null 2>&1 || true
  systemctl restart "$CACHE_SVC"
  ok "${CACHE_SVC} secured on 127.0.0.1:6379"
}

write_systemd_units() {
  cat >/etc/systemd/system/mc-proxy.service <<EOF
[Unit]
Description=Minecraft Velocity proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${MC_USER}
WorkingDirectory=${BASE_FULL}/proxy
ExecStart=/usr/bin/java -Xms${PROXY_XMS} -Xmx${PROXY_XMX} -XX:+UseG1GC -XX:G1HeapRegionSize=4M -XX:+UnlockExperimentalVMOptions -XX:+ParallelRefProcEnabled -XX:MaxInlineLevel=15 -jar velocity.jar
Restart=on-failure
RestartSec=5s
SuccessExitStatus=0 143

[Install]
WantedBy=multi-user.target
EOF

  cat >/etc/systemd/system/mc-lobby.service <<EOF
[Unit]
Description=Minecraft Paper lobby
After=network-online.target mariadb.service ${CACHE_SVC}.service
Wants=network-online.target

[Service]
Type=simple
User=${MC_USER}
WorkingDirectory=${BASE_FULL}/lobby
ExecStart=/usr/bin/java -Xms${LOBBY_XMS} -Xmx${LOBBY_XMX} -XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 -XX:+UnlockExperimentalVMOptions -XX:+DisableExplicitGC -XX:+AlwaysPreTouch -XX:G1NewSizePercent=30 -XX:G1MaxNewSizePercent=40 -XX:G1HeapRegionSize=8M -XX:G1ReservePercent=20 -XX:G1HeapWastePercent=5 -XX:G1MixedGCCountTarget=4 -XX:InitiatingHeapOccupancyPercent=15 -XX:G1MixedGCLiveThresholdPercent=90 -XX:G1RSetUpdatingPauseTimePercent=5 -XX:SurvivorRatio=32 -XX:+PerfDisableSharedMem -XX:MaxTenuringThreshold=1 -Dusing.aikars.flags=https://mcflags.emc.gs -Daikars.new.flags=true -jar paper.jar --nogui
Restart=on-failure
RestartSec=5s
SuccessExitStatus=0 143

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

run_full() {
  require_root
  detect_os
  install_packages
  setup_user_dirs

  local secret; secret="$(get_or_make_secret "${BASE_FULL}/proxy/forwarding.secret")"

  # Proxy
  log "Provisioning proxy ..."
  fill_download velocity "$VELOCITY_VERSION" RECOMMENDED "${BASE_FULL}/proxy/velocity.jar"
  write_velocity_toml "${BASE_FULL}/proxy" "$PROXY_PORT" "$LOBBY_PORT"
  log "Downloading proxy plugins ..."
  download_plugins "${BASE_FULL}/proxy/plugins" "${PROXY_PLUGINS[@]}"

  # Lobby
  log "Provisioning lobby ..."
  fill_download paper "$PAPER_VERSION" STABLE "${BASE_FULL}/lobby/paper.jar"
  write_lobby_configs "${BASE_FULL}/lobby" "$secret" "$LOBBY_PORT"
  log "Downloading lobby plugins ..."
  download_plugins "${BASE_FULL}/lobby/plugins" "${LOBBY_PLUGINS[@]}"

  # Infra
  setup_mariadb
  setup_cache
  seed_luckperms_sql_redis "${BASE_FULL}/lobby/plugins" "$DB_PASS" "$REDIS_PASS"

  # Services
  write_systemd_units
  chown -R "${MC_USER}:${MC_USER}" "$BASE_FULL"
  chmod 600 "${BASE_FULL}/proxy/forwarding.secret"
  systemctl enable mc-proxy.service mc-lobby.service >/dev/null 2>&1 || true

  write_credentials_file "$BASE_FULL" "$secret" full
  print_summary "$secret" full
}

# ------------------------------------------------------------- jars mode ------
run_jars() {
  detect_os
  need_cmd curl || die "curl is required (install: apt install curl)"
  need_cmd jq   || die "jq is required (install: apt install jq)"
  local base; base="$(pwd)"
  mkdir -p "${base}/proxy/plugins" "${base}/lobby/plugins"

  local secret; secret="$(get_or_make_secret "${base}/proxy/forwarding.secret")"

  log "Provisioning proxy (jars) ..."
  fill_download velocity "$VELOCITY_VERSION" RECOMMENDED "${base}/proxy/velocity.jar"
  write_velocity_toml "${base}/proxy" "$PROXY_PORT" "$LOBBY_PORT"
  download_plugins "${base}/proxy/plugins" "${PROXY_PLUGINS[@]}"

  log "Provisioning lobby (jars) ..."
  fill_download paper "$PAPER_VERSION" STABLE "${base}/lobby/paper.jar"
  write_lobby_configs "${base}/lobby" "$secret" "$LOBBY_PORT"
  download_plugins "${base}/lobby/plugins" "${LOBBY_PLUGINS[@]}"

  # Portable start scripts (no systemd, no DB/Redis wiring)
  cat >"${base}/proxy/start.sh" <<EOF
#!/usr/bin/env bash
cd "\$(dirname "\$0")"
exec java -Xms${PROXY_XMS} -Xmx${PROXY_XMX} -XX:+UseG1GC -XX:G1HeapRegionSize=4M -jar velocity.jar
EOF
  cat >"${base}/lobby/start.sh" <<EOF
#!/usr/bin/env bash
cd "\$(dirname "\$0")"
exec java -Xms${LOBBY_XMS} -Xmx${LOBBY_XMX} -XX:+UseG1GC -XX:+ParallelRefProcEnabled -jar paper.jar --nogui
EOF
  chmod +x "${base}/proxy/start.sh" "${base}/lobby/start.sh"
  chmod 600 "${base}/proxy/forwarding.secret"

  warn "jars mode: LuckPerms is NOT wired to a database/Redis (no infra installed)."
  warn "It will use its default local (H2) storage until you configure it."
  write_credentials_file "$base" "$secret" jars
  print_summary "$secret" jars
}

# --------------------------------------------------------------- summary ------
write_credentials_file() { # BASE SECRET MODE
  local base="$1" secret="$2" mode="$3" f="${1}/CREDENTIALS.txt"
  {
    echo "Minecraft network — provisioning summary ($(date -u +%FT%TZ))"
    echo "mode: $mode"
    echo "base: $base"
    echo
    echo "forwarding.secret : $secret"
    echo "  (proxy: ${base}/proxy/forwarding.secret ; lobby: config/paper-global.yml -> proxies.velocity.secret)"
    echo
    echo "proxy port (public) : $PROXY_PORT"
    echo "lobby port (internal): $LOBBY_PORT"
    if [[ "$mode" == "full" ]]; then
      echo
      echo "MariaDB db=luckperms user=luckperms pass=${DB_PASS:-?} host=localhost:3306"
      echo "Redis/Valkey (${CACHE_SVC:-?}) host=localhost:6379 pass=${REDIS_PASS:-?}"
    fi
  } >"$f"
  chmod 600 "$f"
}

print_summary() { # SECRET MODE
  local secret="$1" mode="$2" base
  [[ "$mode" == "full" ]] && base="$BASE_FULL" || base="$(pwd)"
  echo
  printf '%s============================================================%s\n' "$C_BOLD" "$C_0"
  printf '%s  SETUP COMPLETE (%s mode)%s\n' "$C_BOLD" "$mode" "$C_0"
  printf '%s============================================================%s\n' "$C_BOLD" "$C_0"
  echo
  printf '  %sForwarding secret%s : %s%s%s\n' "$C_BOLD" "$C_0" "$C_G" "$secret" "$C_0"
  echo   "                      (identical on proxy + lobby — this is what keeps backends secure)"
  echo
  printf '  Proxy   : %s/proxy   (velocity.jar, public port %s)\n' "$base" "$PROXY_PORT"
  printf '  Lobby   : %s/lobby   (paper.jar %s, internal port %s)\n' "$base" "$PAPER_VERSION" "$LOBBY_PORT"
  if [[ "$mode" == "full" ]]; then
    echo
    printf '  %sMariaDB%s : db=luckperms user=luckperms pass=%s%s%s host=localhost:3306\n' \
      "$C_BOLD" "$C_0" "$C_G" "${DB_PASS}" "$C_0"
    printf '  %sCache%s   : %s host=localhost:6379 pass=%s%s%s\n' \
      "$C_BOLD" "$C_0" "$CACHE_SVC" "$C_G" "${REDIS_PASS}" "$C_0"
    echo
    echo   "  Services:"
    echo   "    systemctl start mc-lobby     # boot the lobby (first run generates the world)"
    echo   "    systemctl start mc-proxy     # boot the proxy"
    echo   "    journalctl -u mc-lobby -f    # watch logs"
    echo   "  (both are 'enabled' and will start on boot)"
  else
    echo
    echo   "  Start (no systemd):"
    echo   "    ./lobby/start.sh   # first run generates the world"
    echo   "    ./proxy/start.sh"
  fi
  echo
  printf '  Credentials saved to: %s%s/CREDENTIALS.txt%s (chmod 600)\n' "$C_B" "$base" "$C_0"
  if ((${#FAILED_PLUGINS[@]})); then
    echo
    printf '  %sPlugins that need manual download:%s %s\n' "$C_Y" "$C_0" "${FAILED_PLUGINS[*]}"
  fi
  echo
  echo   "  Connect your client to the proxy on port ${PROXY_PORT} → it forwards to the lobby."
  echo
}

# ------------------------------------------------------------------ main ------
main() {
  local mode="${1:-}"
  case "$mode" in
    full|--full) run_full ;;
    jars|jars-only|--jars|--jars-only) run_jars ;;
    *) cat >&2 <<USAGE
Usage: $0 <full|jars>

  full   Install Java + MariaDB + Redis/Valkey, provision ${BASE_FULL}/{proxy,lobby},
         wire modern forwarding + LuckPerms(SQL+Redis) + systemd services. Run as root.

  jars   No apt/systemd/DB/root. Pull Velocity + Paper ${PAPER_VERSION} + plugins into
         ./proxy and ./lobby here, accept EULA, generate + wire the forwarding secret,
         write start scripts.
USAGE
       exit 2 ;;
  esac
}
main "$@"
