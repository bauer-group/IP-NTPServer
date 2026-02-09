#!/usr/bin/env bash
# =============================================================================
# Fallback Install Script: NTP Server (time.bauer-group.com)
# =============================================================================
# Dieses Script installiert den NTP Server manuell auf einem bestehenden
# Ubuntu 24.04+ / Debian 13+ System, falls Cloud-Init nicht verfuegbar ist.
#
# Verwendung:
#   curl -fsSL https://raw.githubusercontent.com/bauer-group/IP-NTPServer/main/cloud-init/install.sh | sudo bash
#   oder:
#   sudo bash install.sh [HOSTNAME]
#
# Parameter:
#   HOSTNAME  Hostname des Servers (Default: time.bauer-group.com)
# =============================================================================

set -euo pipefail

NTP_HOSTNAME="${1:-time.bauer-group.com}"

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
echo " NTP Server Setup - ${NTP_HOSTNAME}"
echo "============================================="
echo ""

# --- Pakete installieren -----------------------------------------------------

echo "[1/6] Bestehende NTP-Dienste entfernen..."
export DEBIAN_FRONTEND=noninteractive
systemctl stop systemd-timesyncd 2>/dev/null || true
systemctl disable systemd-timesyncd 2>/dev/null || true
apt-get remove -y -q ntp ntpsec 2>/dev/null || true

echo "[2/6] Pakete aktualisieren und installieren..."
apt-get update -q
apt-get upgrade -y -q
apt-get install -y -q \
    chrony \
    unattended-upgrades \
    apt-listchanges \
    needrestart

# --- Chrony konfigurieren ----------------------------------------------------

echo "[3/6] Chrony NTP Server konfigurieren..."
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

# Messdaten ueber Neustarts persistieren
dumpdir /var/lib/chrony

# NTP-Dienst fuer alle Clients bereitstellen
allow all

# Rate Limiting: Schutz vor Amplification-Angriffen (Pool-tauglich)
# interval -4 = min. 1/16 Sek. zwischen Paketen pro Client (~16 Pkt/Sek)
# burst 16 = kurze Bursts erlauben, leak 2 = sanftes Throttling
ratelimit interval -4 burst 16 leak 2

# Client-Log: 128 MB = ca. 2 Mio. Clients (fuer NTP Pool ausreichend)
clientloglimit 134217728

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

echo "[4/6] Automatische Updates konfigurieren..."
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

// Automatischer Reboot wenn noetig (03:25 Uhr, nach apt-daily-upgrade)
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "03:25";

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

# systemd Timer: Alles ins Wartungsfenster 03:00-03:30 UTC legen
mkdir -p /etc/systemd/system/apt-daily.timer.d
cat > /etc/systemd/system/apt-daily.timer.d/override.conf <<'TIMER_DAILY'
[Timer]
OnCalendar=
OnCalendar=*-*-* 03:00
RandomizedDelaySec=0
TIMER_DAILY

mkdir -p /etc/systemd/system/apt-daily-upgrade.timer.d
cat > /etc/systemd/system/apt-daily-upgrade.timer.d/override.conf <<'TIMER_UPGRADE'
[Timer]
OnCalendar=
OnCalendar=*-*-* 03:10
RandomizedDelaySec=0
TIMER_UPGRADE

systemctl daemon-reload
systemctl enable apt-daily.timer
systemctl enable apt-daily-upgrade.timer

# --- System-Einstellungen -----------------------------------------------------

echo "[5/6] Hostname, Timezone und Locale setzen..."
hostnamectl set-hostname "${NTP_HOSTNAME}"
timedatectl set-timezone Etc/UTC
localectl set-locale LANG=en_US.UTF-8

# --- Abschluss ---------------------------------------------------------------

echo "[6/6] Verifizierung..."
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
echo "Wartungsfenster: 03:00-03:30 UTC (apt-update, upgrade, reboot)"
echo "Unattended-Upgrades Log: /var/log/unattended-upgrades/"
echo "Chrony Log: /var/log/chrony/"
