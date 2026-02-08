#!/usr/bin/env bash
# =============================================================================
# Fallback Install Script: NTP Server (time.bauer-group.com)
# =============================================================================
# Dieses Script installiert den NTP Server manuell auf einem bestehenden
# Ubuntu 24.04+ / Debian 13+ System, falls Cloud-Init nicht verfuegbar ist.
#
# Verwendung:
#   curl -fsSL <url>/install.sh | sudo bash
#   oder:
#   sudo bash install.sh
# =============================================================================

set -euo pipefail

# --- Pruefungen --------------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then
    echo "FEHLER: Dieses Script muss als root ausgefuehrt werden." >&2
    echo "Verwendung: sudo bash $0" >&2
    exit 1
fi

if ! command -v apt-get &>/dev/null; then
    echo "FEHLER: Nur Debian/Ubuntu wird unterstuetzt (apt-get nicht gefunden)." >&2
    exit 1
fi

echo "============================================="
echo " NTP Server Setup - time.bauer-group.com"
echo "============================================="
echo ""

# --- Pakete installieren -----------------------------------------------------

echo "[1/5] Pakete aktualisieren und installieren..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get upgrade -y -q
apt-get install -y -q \
    chrony \
    unattended-upgrades \
    apt-listchanges \
    needrestart \
    ufw

# --- Chrony konfigurieren ----------------------------------------------------

echo "[2/5] Chrony NTP Server konfigurieren..."
cat > /etc/chrony/chrony.conf <<'CHRONY_CONF'
# =======================================================================
# Chrony NTP Server - time.bauer-group.com
# =======================================================================

# Upstream NTP Server (deutsche Zeitquellen)
server ptbtime1.ptb.de iburst prefer
server ptbtime2.ptb.de iburst
server ptbtime3.ptb.de iburst
server ntps1-0.eecsit.tu-berlin.de iburst
server ntp1.fau.de iburst
server zeit.fu-berlin.de iburst

# Zeitdifferenz-Datei (fuer Neustarts)
driftfile /var/lib/chrony/chrony.drift

# NTP-Dienst fuer alle Clients im Netzwerk bereitstellen
allow all

# Logging
log tracking measurements statistics
logdir /var/log/chrony

# RTC (Hardware-Uhr) synchronisieren
rtcsync

# Grosse Zeitspruenge beim Start erlauben (erste 3 Updates)
makestep 1.0 3

# Leap-Second-Handling
leapsectz right/UTC
CHRONY_CONF

systemctl enable chrony
systemctl restart chrony

# Initiale Zeitsynchronisation erzwingen
chronyc makestep

# --- Automatische Updates konfigurieren --------------------------------------

echo "[3/5] Automatische Updates konfigurieren..."
cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'UNATTENDED_CONF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}:${distro_codename}-updates";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};

// Alle installierten Pakete aktualisieren (nicht nur Sicherheit)
Unattended-Upgrade::DevRelease "auto";

// Automatischer Reboot wenn noetig (03:00 Uhr)
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";

// Ungenutzte Abhaengigkeiten entfernen
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";

// Syslog-Logging
Unattended-Upgrade::SyslogEnable "true";
UNATTENDED_CONF

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'AUTO_UPGRADES'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
AUTO_UPGRADES

# needrestart: Automatischer Restart von Diensten nach Updates
mkdir -p /etc/needrestart/conf.d
cat > /etc/needrestart/conf.d/auto-restart.conf <<'NEEDRESTART_CONF'
$nrconf{restart} = 'a';
NEEDRESTART_CONF

systemctl enable unattended-upgrades
systemctl restart unattended-upgrades
systemctl enable apt-daily.timer
systemctl enable apt-daily-upgrade.timer

# --- Firewall konfigurieren --------------------------------------------------

echo "[4/5] Firewall konfigurieren..."
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow 123/udp comment "NTP"
ufw --force enable

# --- Timezone setzen ----------------------------------------------------------

echo "[5/5] Timezone auf UTC setzen..."
timedatectl set-timezone Etc/UTC

# --- Abschluss ---------------------------------------------------------------

echo ""
echo "============================================="
echo " Setup abgeschlossen!"
echo "============================================="
echo ""
echo "NTP Server Status:"
chronyc tracking
echo ""
echo "Quellen:"
chronyc sources -v
echo ""
echo "Firewall:"
ufw status
echo ""
echo "Naechster automatischer Reboot (falls noetig): 03:00 Uhr"
echo "Unattended-Upgrades Log: /var/log/unattended-upgrades/"
echo "Chrony Log: /var/log/chrony/"
