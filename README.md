mc-setup

Provisions a Minecraft network — Velocity proxy + Paper 1.21.11 lobby — on Debian 13 (Trixie) or Raspberry Pi OS. No Bedrock. Two modes: full server (Java + MariaDB + Redis/Valkey + systemd) or a portable jars-only folder.

Quick start

Full install (Java, MariaDB, Redis/Valkey, /opt/minecraft, systemd services — needs root):

bash
curl -fsSL https://raw.githubusercontent.com/zsigisti/mc-setup/main/mcnet-setup.sh | sudo bash -s -- full

Jars only (no root, no apt, no DB — drops ./proxy and ./lobby into the current directory):

bash
curl -fsSL https://raw.githubusercontent.com/zsigisti/mc-setup/main/mcnet-setup.sh | bash -s -- jars

Piping into sudo bash runs the script the moment it downloads. Read it first if you'd rather:

bash
curl -fsSL -o mcnet-setup.sh https://raw.githubusercontent.com/zsigisti/mc-setup/main/mcnet-setup.sh
less mcnet-setup.sh          # audit
chmod +x mcnet-setup.sh
sudo ./mcnet-setup.sh full   # or: ./mcnet-setup.sh jars

(If your default branch is master, swap main → master in the URL.)

What it does
Pulls Velocity and Paper 1.21.11 via the current PaperMC Fill v3 API, with sha256 verification.
Installs the lobby plugin set from Modrinth (LuckPerms, ViaVersion/ViaBackwards/ViaRewind, GrimAC, PlaceholderAPI, CoreProtect, WorldEdit/WorldGuard, TAB, DecentHolograms, FancyNPCs) plus DeluxeMenus and Vault from GitHub. Failed downloads are reported at the end, never fatal.
Accepts the EULA, generates the Velocity modern-forwarding secret, and wires it into both the proxy and the lobby.
Full mode only: provisions MariaDB + Redis (falls back to Valkey on Trixie), points LuckPerms at SQL storage + Redis messaging, and installs mc-proxy / mc-lobby systemd units.
Prints every credential at the end and saves them to CREDENTIALS.txt (chmod 600).
Modes
	full	jars
Root required	yes	no
Installs Java / DB / Redis	yes	no
systemd services	yes	no (writes start.sh)
Install location	/opt/minecraft	current directory
LuckPerms storage	MariaDB + Redis	default H2 (unwired)
Requirements
Debian 13 (Trixie) or Raspberry Pi OS (Trixie-based), amd64 or arm64
Full mode: root; installs openjdk-21-jre-headless, mariadb-server, redis-server/valkey-server, jq, curl
Jars mode: curl and jq already present
After install

Full mode:

bash
systemctl start mc-lobby     # first run generates the world
systemctl start mc-proxy
journalctl -u mc-lobby -f

Jars mode:

bash
./lobby/start.sh             # first run generates the world
./proxy/start.sh

Connect your client to the proxy on port 25565 — it forwards to the lobby (127.0.0.1:25566, loopback-bound so it's never exposed publicly).

Ports & firewall
Port	Service	Exposure
25565	Velocity proxy	public — open this
25566	Paper lobby	localhost only

The script does not touch your firewall. Expose only 25565.

Notes
Paper/LuckPerms configs are seeded partially and merged with defaults on first boot — those files grow on the first mc-lobby start; that's expected.
Lower LOBBY_XMX (top of the script, default 2G) on a Pi with <4 GB RAM.
Edit the USER_AGENT variable if you fork this — the Fill API rejects generic agents.
