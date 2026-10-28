#!/usr/bin/env bash
# =============================================================================
#  from-lynis-to-100 — durcissement Debian / Ubuntu pour viser un
#  "Hardening index" Lynis de 100.
#
#  Compatible : Debian 12 (bookworm), Debian 13 (trixie),
#               Ubuntu 22.04 LTS, Ubuntu 24.04 LTS
#  Testé de bout en bout : Debian 13 (VM VMware, Lynis 3.1.4) -> 63 puis 100
#
#  LISEZ LE README (section Disclaimer) AVANT DE LANCER CE SCRIPT.
#  Il modifie SSH (port, utilisateurs autorisés), le pare-feu, l'USB,
#  les options de montage, GRUB, la politique de mots de passe...
#
#  Usage : sudo ./lynis-to-100.sh [options]     (./lynis-to-100.sh --help)
# =============================================================================
set -uo pipefail

VERSION="1.0.0"

# ----------------------------------------------------------------------------
# Options par défaut (modifiables en ligne de commande ou par variables d'env)
# ----------------------------------------------------------------------------
ASSUME_YES="${ASSUME_YES:-no}"
SSH_PORT="${SSH_PORT:-2222}"            # "keep" pour ne pas changer le port
ALLOW_USERS="${ALLOW_USERS:-auto}"      # "auto" = utilisateurs humains (UID>=1000) + l'appelant sudo
GRUB_PASSWORD="${GRUB_PASSWORD:-}"      # vide = demandé en interactif
DO_GRUB="${DO_GRUB:-yes}"
DO_FIREWALL="${DO_FIREWALL:-yes}"
DO_USB="${DO_USB:-yes}"                 # désactive l'USB (VM uniquement sauf --force-usb)
FORCE_USB="${FORCE_USB:-no}"
REMOVE_COMPILERS="${REMOVE_COMPILERS:-ask}"   # yes | no | ask
HOME_LV_SIZE="${HOME_LV_SIZE:-}"        # ex: 2G -> crée un LV /home si / est sur LVM
DO_EXCEPTIONS="${DO_EXCEPTIONS:-yes}"   # exceptions documentées dans /etc/lynis/custom.prf
TMOUT_SECONDS="${TMOUT_SECONDS:-900}"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/root/lynis-to-100-backup/${STAMP}"
LOG_FILE="/var/log/lynis-to-100.log"
export DEBIAN_FRONTEND=noninteractive
export APT_LISTBUGS_FRONTEND=none

# ----------------------------------------------------------------------------
# Affichage
# ----------------------------------------------------------------------------
if [ -t 1 ]; then R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[1;34m'; N=$'\e[0m'; else R='' G='' Y='' B='' N=''; fi
step()  { echo; echo "${B}==> $*${N}"; }
ok()    { echo "  ${G}[OK]${N} $*"; }
warn()  { echo "  ${Y}[!]${N} $*"; }
err()   { echo "  ${R}[ERREUR]${N} $*"; }
die()   { err "$*"; exit 1; }

usage() {
cat <<EOF
from-lynis-to-100 v${VERSION}
Durcit un serveur Debian/Ubuntu pour viser un score Lynis de 100.

Usage : sudo $0 [options]

  -y, --yes                 Ne pas demander de confirmation (le disclaimer reste affiché)
  --ssh-port N              Nouveau port SSH (défaut : 2222)
  --keep-ssh-port           Ne pas changer le port SSH (perte de quelques points)
  --allow-users "u1 u2"     Comptes autorisés en SSH (défaut : auto)
  --grub-password PASS      Mot de passe GRUB (sinon demandé ; aussi via GRUB_PASSWORD)
  --no-grub                 Ne pas protéger GRUB par mot de passe
  --no-firewall             Ne pas installer de pare-feu (nftables/ufw)
  --keep-usb                Ne pas désactiver l'USB
  --force-usb               Désactiver l'USB même sur une machine physique (DANGEREUX)
  --remove-compilers        Supprimer gcc/g++/binutils sans demander
  --keep-compilers          Garder les compilateurs (accès restreint à root)
  --home-lv SIZE            Créer un LV séparé pour /home (ex : 2G) si / est sur LVM
  --no-exceptions           Ne pas écrire d'exceptions dans /etc/lynis/custom.prf
  -h, --help                Afficher cette aide

Sauvegardes : ${BACKUP_DIR%/*}/<date>/   Journal : ${LOG_FILE}
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes) ASSUME_YES=yes ;;
    --ssh-port) SSH_PORT="${2:?}"; shift ;;
    --keep-ssh-port) SSH_PORT=keep ;;
    --allow-users) ALLOW_USERS="${2:?}"; shift ;;
    --grub-password) GRUB_PASSWORD="${2:?}"; shift ;;
    --no-grub) DO_GRUB=no ;;
    --no-firewall) DO_FIREWALL=no ;;
    --keep-usb) DO_USB=no ;;
    --force-usb) FORCE_USB=yes ;;
    --remove-compilers) REMOVE_COMPILERS=yes ;;
    --keep-compilers) REMOVE_COMPILERS=no ;;
    --home-lv) HOME_LV_SIZE="${2:?}"; shift ;;
    --no-exceptions) DO_EXCEPTIONS=no ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "Option inconnue : $1" ;;
  esac
  shift
done

# ----------------------------------------------------------------------------
# Fonctions utilitaires
# ----------------------------------------------------------------------------
backup() {  # backup <fichier> : copie dans BACKUP_DIR en gardant l'arborescence
  local f
  for f in "$@"; do
    [ -e "$f" ] || continue
    mkdir -p "${BACKUP_DIR}$(dirname "$f")"
    [ -e "${BACKUP_DIR}${f}" ] || cp -a "$f" "${BACKUP_DIR}${f}"
  done
}
have()    { command -v "$1" >/dev/null 2>&1; }
pkg_ok()  { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }
pkg_available() { local c; c="$(LC_ALL=C apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/{print $2}')"; [ -n "$c" ] && [ "$c" != "(none)" ]; }
apt_install() {
  local p todo=()
  for p in "$@"; do
    pkg_ok "$p" && continue
    if pkg_available "$p"; then todo+=("$p"); else warn "paquet indisponible : $p"; fi
  done
  [ ${#todo[@]} -eq 0 ] && return 0
  apt-get install -y -q "${todo[@]}" >>"$LOG_FILE" 2>&1 && ok "installé : ${todo[*]}" || err "échec installation : ${todo[*]} (voir $LOG_FILE)"
}
set_kv() {  # set_kv <fichier> <clé> <valeur> <séparateur>  (remplace ou ajoute)
  local file=$1 key=$2 val=$3 sep=${4:- }
  if grep -qE "^[#[:space:]]*${key}([[:space:]]|=)" "$file" 2>/dev/null; then
    sed -ri "s@^[#[:space:]]*${key}([[:space:]]+|=).*@${key}${sep}${val}@" "$file"
  else
    printf '%s%s%s\n' "$key" "$sep" "$val" >> "$file"
  fi
}
ensure_newline() { [ -s "$1" ] && [ "$(tail -c1 "$1" | od -An -c | tr -d ' ')" != '\n' ] && echo >> "$1"; return 0; }
lynis_score() { awk -F= '/^hardening_index=/{print $2}' /var/log/lynis-report.dat 2>/dev/null; }
run_lynis() { lynis audit system --quick --no-colors >>"$LOG_FILE" 2>&1; lynis_score; }

# ----------------------------------------------------------------------------
# Vérifications préalables
# ----------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "À lancer en root (sudo $0)."
[ -r /etc/os-release ] || die "/etc/os-release introuvable."
# shellcheck disable=SC1091
. /etc/os-release
case "${ID}:${VERSION_ID:-}" in
  debian:12|debian:13|ubuntu:22.04|ubuntu:24.04) ;;
  debian:*|ubuntu:*) warn "Version ${PRETTY_NAME} non testée : le script continue, résultats non garantis." ;;
  *) die "Distribution non supportée : ${PRETTY_NAME:-inconnue} (Debian/Ubuntu uniquement)." ;;
esac
have systemctl || die "systemd requis."
if have systemd-detect-virt && systemd-detect-virt --container -q; then
  die "Conteneur détecté : ce script vise une VM ou un serveur (montages, GRUB, USB, sysctl)."
fi
VIRT="$(systemd-detect-virt 2>/dev/null || echo none)"
CALLER="${SUDO_USER:-}"
[ "$CALLER" = root ] && CALLER=""
if [ "$SSH_PORT" != keep ] && ! [[ "$SSH_PORT" =~ ^[0-9]+$ && "$SSH_PORT" -ge 1 && "$SSH_PORT" -le 65535 ]]; then
  die "Port SSH invalide : $SSH_PORT"
fi
if [ "$ALLOW_USERS" = auto ]; then
  ALLOW_USERS="$(awk -F: '$3>=1000 && $3<65534 && $7 !~ /(nologin|false)$/ {print $1}' /etc/passwd | tr '\n' ' ')"
  [ -n "$CALLER" ] && ! grep -qw "$CALLER" <<<"$ALLOW_USERS" && ALLOW_USERS="$ALLOW_USERS $CALLER"
  ALLOW_USERS="$(echo "$ALLOW_USERS" | xargs)"
fi
[ -n "$ALLOW_USERS" ] || die "Aucun utilisateur à autoriser en SSH : utilisez --allow-users \"user\"."
CUR_SSH_PORTS="$(ss -Htlnp 2>/dev/null | awk '/sshd/{n=split($4,a,":"); print a[n]}' | sort -u | tr '\n' ' ')"

# ----------------------------------------------------------------------------
# Disclaimer
# ----------------------------------------------------------------------------
cat <<EOF

${R}=====================================================================
  AVERTISSEMENT — from-lynis-to-100 v${VERSION}
=====================================================================${N}
Système : ${PRETTY_NAME}   Virtualisation : ${VIRT}

Ce script applique un durcissement AGRESSIF pour atteindre 100 sur Lynis.
Il est prévu pour un serveur de lab / de formation. Principaux impacts :

  * SSH : port $( [ "$SSH_PORT" = keep ] && echo "inchangé" || echo "${CUR_SSH_PORTS:-22}-> ${SSH_PORT}" ),
          seuls ces comptes pourront se connecter : ${ALLOW_USERS}
          (root ne pourra plus se connecter en SSH), MaxAuthTries 3,
          redirections TCP/X11/agent désactivées, fail2ban actif.
  * Pare-feu : $( [ "$DO_FIREWALL" = yes ] && echo "entrant BLOQUÉ sauf les ports TCP en écoute actuellement + SSH" || echo "non modifié" ).
  * USB : $( [ "$DO_USB" = yes ] && echo "TOUT l'USB est désactivé (clavier/souris USB compris) — VM uniquement" || echo "non modifié" ).
  * Montages : /tmp, /dev/shm, /dev (et /home si séparé) en noexec,
               /proc en hidepid=2 (chaque utilisateur ne voit que ses processus).
  * Comptes : mots de passe expirant à 90 jours, déconnexion des shells
              inactifs après $((TMOUT_SECONDS/60)) min, umask 027, core dumps interdits.
  * GRUB : $( [ "$DO_GRUB" = yes ] && echo "mot de passe pour modifier les entrées (démarrage normal libre)" || echo "non modifié" ).
  * Modules : usb-storage, firewire, dccp/sctp/rds/tipc, cramfs/hfs/
              squashfs/udf... bloqués (pas d'ISO udf, pas de snaps si squashfs bloqué).
  * Paquets ajoutés : fail2ban, auditd, aide, rkhunter, clamav, usbguard,
              needrestart, debsums, sysstat, acct, unattended-upgrades...
  * Compilateurs : $( [ "$REMOVE_COMPILERS" = yes ] && echo "SUPPRIMÉS" || echo "suppression proposée / accès réservé à root" ).
  * Exceptions Lynis documentées dans /etc/lynis/custom.prf (voir README).

Sauvegardes des fichiers modifiés : ${BACKUP_DIR}
Journal détaillé : ${LOG_FILE}

${Y}FAITES UN SNAPSHOT / UNE SAUVEGARDE AVANT DE CONTINUER.
Gardez une seconde session SSH ouverte pendant l'exécution.${N}
EOF
if [ "$ASSUME_YES" != yes ]; then
  read -rp "Tapez OUI (en majuscules) pour continuer : " ans
  [ "$ans" = "OUI" ] || die "Abandon."
fi

mkdir -p "$BACKUP_DIR"
echo "===== $(date) from-lynis-to-100 v${VERSION} =====" >>"$LOG_FILE"

# ----------------------------------------------------------------------------
# 0. Prérequis + audit initial
# ----------------------------------------------------------------------------
step "0. Prérequis et audit initial"
if [ "$ID" = ubuntu ] && ! grep -rqsE '^[^#].*\buniverse\b' /etc/apt/sources.list /etc/apt/sources.list.d/; then
  warn "Le dépôt 'universe' semble désactivé : certains paquets peuvent manquer (add-apt-repository universe)."
fi
# apt-listbugs peut épingler (-30000) des paquets : on sauvegarde puis on retire ces épinglages
if [ -f /etc/apt/preferences.d/apt-listbugs ]; then
  backup /etc/apt/preferences.d/apt-listbugs
  rm -f /etc/apt/preferences.d/apt-listbugs && warn "épinglages apt-listbugs retirés (sauvegardés)"
fi
apt-get update -q >>"$LOG_FILE" 2>&1 || warn "apt-get update a signalé des erreurs (voir $LOG_FILE)"
apt_install lynis bind9-dnsutils
have lynis || die "Lynis n'a pas pu être installé."
SCORE_BEFORE="$(run_lynis)"
ok "Score Lynis initial : ${SCORE_BEFORE:-?}"

# ----------------------------------------------------------------------------
# 1. Paquets de sécurité
# ----------------------------------------------------------------------------
step "1. Paquets de sécurité"
apt_install libpam-tmpdir needrestart fail2ban python3-systemd libpam-passwdqc \
  debsums apt-show-versions unattended-upgrades acct sysstat auditd aide rkhunter \
  clamav clamav-daemon usbguard
[ "$DO_FIREWALL" = yes ] && ! have ufw && apt_install nftables

# ----------------------------------------------------------------------------
# 2. Comptes et mots de passe (AUTH-9230/9262/9282/9286/9328/9408)
# ----------------------------------------------------------------------------
step "2. Comptes et politique de mots de passe"
backup /etc/login.defs
set_kv /etc/login.defs PASS_MIN_DAYS 1 $'\t'
set_kv /etc/login.defs PASS_MAX_DAYS 90 $'\t'
set_kv /etc/login.defs PASS_WARN_AGE 7 $'\t'
set_kv /etc/login.defs UMASK 027 $'\t'
set_kv /etc/login.defs SHA_CRYPT_MIN_ROUNDS 5000 $'\t'
set_kv /etc/login.defs SHA_CRYPT_MAX_ROUNDS 10000 $'\t'
set_kv /etc/login.defs FAILLOG_ENAB yes $'\t'
grep -q '^ENCRYPT_METHOD[[:space:]]*YESCRYPT' /etc/login.defs && set_kv /etc/login.defs YESCRYPT_COST_FACTOR 7 $'\t'
ok "login.defs : âge 1/90 j, umask 027, rounds, FAILLOG_ENAB"
for u in $(awk -F: '$2 ~ /^\$/ {print $1}' /etc/shadow); do
  chage -m 1 -M 90 -W 7 "$u" && ok "expiration 90 j : $u"
done

# ----------------------------------------------------------------------------
# 3. Shells, umask, core dumps (SHLL-6220, KRNL-5820)
# ----------------------------------------------------------------------------
step "3. Shells inactifs et core dumps"
printf 'TMOUT=%s\nreadonly TMOUT\nexport TMOUT\n' "$TMOUT_SECONDS" > /etc/profile.d/99-tmout.sh
echo 'ulimit -c 0' > /etc/profile.d/99-coredump.sh
chmod 644 /etc/profile.d/99-tmout.sh /etc/profile.d/99-coredump.sh
backup /etc/security/limits.conf
ensure_newline /etc/security/limits.conf
sed -i 's/^\(# End of file\)\(\*.*\)$/\1\n\2/' /etc/security/limits.conf
printf '*    soft    core    0\n*    hard    core    0\n' > /etc/security/limits.d/99-coredump.conf
mkdir -p /etc/systemd/coredump.conf.d
printf '[Coredump]\nStorage=none\nProcessSizeMax=0\n' > /etc/systemd/coredump.conf.d/99-disable.conf
backup /etc/systemd/coredump.conf
if [ -f /etc/systemd/coredump.conf ]; then
  sed -ri 's/^#?Storage=.*/Storage=none/; s/^#?ProcessSizeMax=.*/ProcessSizeMax=0/' /etc/systemd/coredump.conf
  grep -q '^Storage=none' /etc/systemd/coredump.conf || echo 'Storage=none' >> /etc/systemd/coredump.conf
  grep -q '^ProcessSizeMax=0' /etc/systemd/coredump.conf || echo 'ProcessSizeMax=0' >> /etc/systemd/coredump.conf
else
  printf '[Coredump]\nStorage=none\nProcessSizeMax=0\n' > /etc/systemd/coredump.conf
fi
ok "TMOUT=${TMOUT_SECONDS}, core dumps désactivés (profile, limits, systemd)"

# ----------------------------------------------------------------------------
# 4. Noyau : sysctl (KRNL-6000) et modules (USB-1000, STRG-1846, NETW-3200, FILE-6430)
# ----------------------------------------------------------------------------
step "4. Noyau : sysctl et modules"
SYSCTL_CONF=/etc/sysctl.d/99-lynis-to-100.conf
: > "$SYSCTL_CONF"
FORWARDING_NEEDED=no
if have docker || [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" = 1 ]; then
  FORWARDING_NEEDED=yes; warn "routage IP actif (Docker/routeur ?) : forwarding laissé à 1"
fi
while read -r key val; do
  [ -z "$key" ] && continue
  [ "$FORWARDING_NEEDED" = yes ] && [[ "$key" == *forwarding* ]] && continue
  sysctl -n "$key" >/dev/null 2>&1 || continue
  echo "$key = $val" >> "$SYSCTL_CONF"
done <<'EOF'
dev.tty.ldisc_autoload 0
fs.protected_fifos 2
fs.protected_hardlinks 1
fs.protected_regular 2
fs.protected_symlinks 1
fs.suid_dumpable 0
kernel.core_uses_pid 1
kernel.ctrl-alt-del 0
kernel.dmesg_restrict 1
kernel.kptr_restrict 2
kernel.perf_event_paranoid 3
kernel.randomize_va_space 2
kernel.sysrq 0
kernel.unprivileged_bpf_disabled 1
kernel.yama.ptrace_scope 1
net.core.bpf_jit_harden 2
net.ipv4.conf.all.accept_redirects 0
net.ipv4.conf.all.accept_source_route 0
net.ipv4.conf.all.bootp_relay 0
net.ipv4.conf.all.forwarding 0
net.ipv4.conf.all.log_martians 1
net.ipv4.conf.all.mc_forwarding 0
net.ipv4.conf.all.proxy_arp 0
net.ipv4.conf.all.rp_filter 1
net.ipv4.conf.all.send_redirects 0
net.ipv4.conf.default.accept_redirects 0
net.ipv4.conf.default.accept_source_route 0
net.ipv4.conf.default.log_martians 1
net.ipv4.conf.default.send_redirects 0
net.ipv4.icmp_echo_ignore_broadcasts 1
net.ipv4.icmp_ignore_bogus_error_responses 1
net.ipv4.tcp_syncookies 1
net.ipv6.conf.all.accept_redirects 0
net.ipv6.conf.all.accept_source_route 0
net.ipv6.conf.all.send_redirects 0
net.ipv6.conf.default.accept_redirects 0
net.ipv6.conf.default.accept_source_route 0
EOF
sysctl --system >>"$LOG_FILE" 2>&1 && ok "sysctl appliqués ($SYSCTL_CONF)"

MOD_CONF=/etc/modprobe.d/99-lynis-to-100.conf
{
  echo "# from-lynis-to-100 : modules inutiles sur un serveur"
  for m in usb-storage firewire-core firewire-ohci firewire-sbp2 dccp sctp rds tipc \
           cramfs freevxfs hfs hfsplus jffs2 udf squashfs; do
    if [ "$m" = squashfs ] && { have snap || pkg_ok snapd; }; then
      echo "# squashfs conservé : snapd est installé"; continue
    fi
    echo "install $m /bin/false"
    echo "blacklist $m"
  done
} > "$MOD_CONF"
ok "modules bloqués ($MOD_CONF)"
{ have snap || pkg_ok snapd; } && warn "snapd présent : squashfs non bloqué (1 point FILE-6430 perdu)"

# ----------------------------------------------------------------------------
# 5. Montages (FILE-6344, FILE-6374) et /home séparé optionnel (FILE-6310)
# ----------------------------------------------------------------------------
step "5. Options de montage"
backup /etc/fstab
ensure_newline /etc/fstab
add_fstab() { grep -qE "^[^#[:space:]]+[[:space:]]+$2[[:space:]]" /etc/fstab || echo "$1" >> /etc/fstab; }
add_fstab 'proc      /proc     proc      defaults,nosuid,nodev,noexec,hidepid=2  0  0' /proc
add_fstab 'devtmpfs  /dev      devtmpfs  defaults,nosuid,noexec  0  0' /dev
add_fstab 'tmpfs     /dev/shm  tmpfs     defaults,nodev,nosuid,noexec  0  0' /dev/shm
add_fstab 'tmpfs     /tmp      tmpfs     defaults,nodev,nosuid,noexec,mode=1777,size=1G  0  0' /tmp

if [ -n "$HOME_LV_SIZE" ] && ! findmnt -n /home >/dev/null; then
  ROOT_SRC="$(findmnt -no SOURCE /)"
  VG="$(lvs --noheadings -o vg_name "$ROOT_SRC" 2>/dev/null | xargs)"
  if [ -n "$VG" ] && lvcreate -y -L "$HOME_LV_SIZE" -n home "$VG" >>"$LOG_FILE" 2>&1; then
    mkfs.ext4 -q "/dev/$VG/home"
    TMPM="$(mktemp -d)"; mount "/dev/$VG/home" "$TMPM" && cp -a /home/. "$TMPM"/ && umount "$TMPM"; rmdir "$TMPM"
    echo "UUID=$(blkid -s UUID -o value "/dev/$VG/home")  /home  ext4  defaults,nodev,nosuid,noexec  0  2" >> /etc/fstab
    ok "/home créé sur /dev/$VG/home ($HOME_LV_SIZE)"
  else
    warn "/home séparé non créé (/ n'est pas sur LVM ou pas d'espace libre)"
  fi
fi
# /home séparé : on garantit nodev,nosuid,noexec
awk 'BEGIN{OFS="\t"} $1 !~ /^#/ && $2=="/home" { n=split($4,o,","); for(i=1;i<=n;i++) h[o[i]]=1;
     split("nodev nosuid noexec",w," "); for(i=1;i<=3;i++) if(!(w[i] in h)) $4=$4","w[i]; delete h }
     {print}' /etc/fstab > /etc/fstab.lynis-to-100.tmp && cat /etc/fstab.lynis-to-100.tmp > /etc/fstab && rm -f /etc/fstab.lynis-to-100.tmp
systemctl daemon-reload
mount -o remount,hidepid=2 /proc 2>/dev/null || warn "remount /proc échoué (appliqué au prochain boot)"
mount -o remount,nosuid,noexec /dev 2>/dev/null || warn "remount /dev échoué (prochain boot)"
mount -o remount,nodev,nosuid,noexec /dev/shm 2>/dev/null || true
if findmnt -n /tmp >/dev/null; then mount -o remount,nodev,nosuid,noexec /tmp 2>/dev/null; else mount /tmp 2>/dev/null || warn "/tmp en tmpfs au prochain boot"; fi
if awk '$1 !~ /^#/ && $2=="/home"{f=1} END{exit !f}' /etc/fstab; then
  findmnt -n /home >/dev/null || mount /home
  mount -o remount,nodev,nosuid,noexec /home 2>/dev/null || true
fi
cat > /etc/apt/apt.conf.d/99-lynis-to-100-tmp-exec <<'EOF'
// /tmp est en noexec : apt le repasse en exec le temps d'une installation
DPkg::Pre-Invoke  {"mount -o remount,exec /tmp || true";};
DPkg::Post-Invoke {"mount -o remount,noexec /tmp || true";};
EOF
if findmnt --verify >>"$LOG_FILE" 2>&1; then ok "fstab vérifié (findmnt --verify)"; else warn "findmnt --verify signale des alertes (voir $LOG_FILE)"; fi

# ----------------------------------------------------------------------------
# 6. SSH (SSH-7408, SSH-7440) + fail2ban (DEB-0880, TOOL-5104)
# ----------------------------------------------------------------------------
step "6. SSH et fail2ban"
SSHD_DROPIN=/etc/ssh/sshd_config.d/99-lynis-to-100.conf
backup /etc/ssh/sshd_config
grep -qE '^Include /etc/ssh/sshd_config.d/\*\.conf' /etc/ssh/sshd_config || sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
{
  echo "# from-lynis-to-100"
  [ "$SSH_PORT" != keep ] && echo "Port $SSH_PORT"
  cat <<'EOF'
AllowTcpForwarding no
AllowAgentForwarding no
X11Forwarding no
TCPKeepAlive no
ClientAliveInterval 300
ClientAliveCountMax 2
LogLevel VERBOSE
MaxAuthTries 3
MaxSessions 2
EOF
  echo "AllowUsers $ALLOW_USERS"
} > "$SSHD_DROPIN"
chmod 600 "$SSHD_DROPIN" /etc/ssh/sshd_config
SSHD_BIN="$(command -v sshd || echo /usr/sbin/sshd)"
if "$SSHD_BIN" -t >>"$LOG_FILE" 2>&1; then
  if [ "$SSH_PORT" != keep ] && systemctl is-enabled -q ssh.socket 2>/dev/null; then
    mkdir -p /etc/systemd/system/ssh.socket.d
    printf '[Socket]\nListenStream=\nListenStream=0.0.0.0:%s\nListenStream=[::]:%s\n' "$SSH_PORT" "$SSH_PORT" > /etc/systemd/system/ssh.socket.d/99-port.conf
    systemctl daemon-reload; systemctl restart ssh.socket
  fi
  systemctl restart ssh 2>/dev/null || systemctl restart sshd
  sleep 1
  if [ "$SSH_PORT" != keep ]; then
    if ss -Htln | awk '{print $4}' | grep -qE "[:.]${SSH_PORT}$"; then ok "SSH écoute sur le port $SSH_PORT"; else err "SSH n'écoute PAS sur $SSH_PORT : vérifiez avant de fermer votre session"; fi
  fi
  ok "SSH durci, AllowUsers : $ALLOW_USERS"
else
  rm -f "$SSHD_DROPIN"; err "sshd -t a échoué : configuration SSH annulée (voir $LOG_FILE)"
  SSH_PORT=keep
fi
EFFECTIVE_SSH_PORT="$( [ "$SSH_PORT" = keep ] && echo "${CUR_SSH_PORTS%% *}" || echo "$SSH_PORT")"
EFFECTIVE_SSH_PORT="${EFFECTIVE_SSH_PORT:-22}"

backup /etc/fail2ban/jail.local
BANACTION=nftables; have ufw && ufw status 2>/dev/null | grep -q 'Status: active' && BANACTION=ufw
cat > /etc/fail2ban/jail.local <<EOF
# from-lynis-to-100
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
banaction = ${BANACTION}
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
backend = systemd
port    = ${EFFECTIVE_SSH_PORT}
EOF
systemctl enable --now fail2ban >>"$LOG_FILE" 2>&1; systemctl restart fail2ban && ok "fail2ban actif (sshd, port ${EFFECTIVE_SSH_PORT})"

# ----------------------------------------------------------------------------
# 7. Pare-feu (FIRE-4590) : bloque l'entrant sauf ports en écoute + SSH
# ----------------------------------------------------------------------------
step "7. Pare-feu"
if [ "$DO_FIREWALL" != yes ]; then
  warn "pare-feu ignoré (--no-firewall)"
elif have docker; then
  warn "Docker détecté : pare-feu non modifié (risque de casser le réseau des conteneurs)"
else
  TCP_PORTS="$(ss -Htln | awk '{print $4}' | grep -vE '^(127\.|\[::1\]|::1)' | awk -F: '{print $NF}' | sort -un | tr '\n' ' ')"
  TCP_PORTS="$(echo "$TCP_PORTS $EFFECTIVE_SSH_PORT" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -un | tr '\n' ',' | sed 's/,$//')"
  if have ufw; then
    ufw --force default deny incoming >>"$LOG_FILE" 2>&1
    ufw --force default allow outgoing >>"$LOG_FILE" 2>&1
    for p in ${TCP_PORTS//,/ }; do ufw allow "${p}/tcp" >>"$LOG_FILE" 2>&1; done
    ufw --force enable >>"$LOG_FILE" 2>&1 && ok "ufw actif, TCP autorisés : $TCP_PORTS"
  else
    backup /etc/nftables.conf
    cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
# from-lynis-to-100 : entrant bloqué sauf services en écoute
flush ruleset
table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;
    ct state established,related accept
    ct state invalid drop
    iif "lo" accept
    meta l4proto { icmp, ipv6-icmp } accept
    udp dport { 68, 546 } accept
    tcp dport { ${TCP_PORTS} } accept
  }
  chain forward { type filter hook forward priority 0; policy $( [ "$FORWARDING_NEEDED" = yes ] && echo accept || echo drop ); }
  chain output  { type filter hook output priority 0; policy accept; }
}
EOF
    if nft -c -f /etc/nftables.conf >>"$LOG_FILE" 2>&1; then
      systemctl enable --now nftables >>"$LOG_FILE" 2>&1; nft -f /etc/nftables.conf && ok "nftables actif, TCP autorisés : $TCP_PORTS"
      systemctl restart fail2ban
    else
      err "règles nftables invalides : pare-feu non appliqué"
    fi
  fi
fi

# ----------------------------------------------------------------------------
# 8. USB (USB-2000, USB-3000)
# ----------------------------------------------------------------------------
step "8. USB"
if [ "$DO_USB" != yes ]; then
  warn "USB non modifié (--keep-usb)"
elif [ "$VIRT" = none ] && [ "$FORCE_USB" != yes ]; then
  warn "machine physique : USB non désactivé (clavier/souris). Utilisez --force-usb pour forcer."
else
  if have usbguard; then
    systemctl stop usbguard 2>/dev/null
    backup /etc/usbguard/usbguard-daemon.conf /etc/usbguard/rules.conf
    : > /etc/usbguard/rules.conf; chmod 600 /etc/usbguard/rules.conf
    for kv in RuleFile=/etc/usbguard/rules.conf ImplicitPolicyTarget=block PresentDevicePolicy=apply-policy \
              PresentControllerPolicy=apply-policy InsertedDevicePolicy=apply-policy RestoreControllerDeviceState=false; do
      k="${kv%%=*}"
      if grep -qE "^#?${k}=" /etc/usbguard/usbguard-daemon.conf; then sed -ri "s|^#?${k}=.*|${kv}|" /etc/usbguard/usbguard-daemon.conf; else echo "$kv" >> /etc/usbguard/usbguard-daemon.conf; fi
    done
    systemctl enable --now usbguard >>"$LOG_FILE" 2>&1 && ok "USBGuard actif (tout périphérique USB bloqué)"
  else
    err "usbguard indisponible (USB-3000 : 8 points perdus)"
  fi
  cat > /etc/systemd/system/usb-deauthorize.service <<'EOF'
[Unit]
Description=from-lynis-to-100 : desactive les bus USB (Lynis USB-2000)
After=usbguard.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for d in /sys/bus/usb/devices/usb*; do [ -e "$d/authorized_default" ] && echo 0 > "$d/authorized_default"; [ -e "$d/authorized" ] && echo 0 > "$d/authorized"; done; true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload; systemctl enable usb-deauthorize.service >>"$LOG_FILE" 2>&1
  systemctl restart usb-deauthorize.service && ok "bus USB désactivés"
fi

# ----------------------------------------------------------------------------
# 9. DNS (NETW-2705) : résolveur local si un seul DNS amont
# ----------------------------------------------------------------------------
step "9. DNS"
if grep -qE '^nameserver[[:space:]]+(127\.0\.0\.(1|53)|::1)' /etc/resolv.conf; then
  ok "résolveur local déjà présent dans resolv.conf (test NETW-2705 non applicable)"
elif [ -L /etc/resolv.conf ] || systemctl is-active -q NetworkManager 2>/dev/null; then
  warn "resolv.conf géré par un autre service : ajoutez un 2e DNS dans sa configuration"
else
  UPSTREAM="$(awk '/^nameserver/{print $2}' /etc/resolv.conf | grep -vE '^(127\.|::1)' | head -n1)"
  if [ "$(grep -c '^nameserver' /etc/resolv.conf)" -ge 2 ]; then
    ok "au moins 2 DNS configurés"
  elif [ -n "$UPSTREAM" ]; then
    apt_install dnsmasq
    printf 'listen-address=127.0.0.1\nbind-interfaces\nno-resolv\nserver=%s\ncache-size=1000\n' "$UPSTREAM" > /etc/dnsmasq.d/99-lynis-to-100.conf
    systemctl enable --now dnsmasq >>"$LOG_FILE" 2>&1; systemctl restart dnsmasq
    if dig +short +time=2 @127.0.0.1 debian.org >/dev/null 2>&1; then
      backup /etc/resolv.conf
      printf 'nameserver 127.0.0.1\nnameserver %s\n' "$UPSTREAM" > /etc/resolv.conf
      [ -f /etc/dhcp/dhclient.conf ] && ! grep -q 'prepend domain-name-servers 127.0.0.1' /etc/dhcp/dhclient.conf && echo 'prepend domain-name-servers 127.0.0.1;' >> /etc/dhcp/dhclient.conf
      [ -f /etc/dhcpcd.conf ] && ! grep -q '^nohook resolv.conf' /etc/dhcpcd.conf && echo 'nohook resolv.conf' >> /etc/dhcpcd.conf
      ok "dnsmasq (127.0.0.1) devant $UPSTREAM"
    else
      warn "dnsmasq ne répond pas : resolv.conf non modifié"
    fi
  else
    warn "aucun DNS amont trouvé dans resolv.conf"
  fi
fi

# ----------------------------------------------------------------------------
# 10. Journalisation, audit, intégrité, antimalware
#     (ACCT-9622/9626/9628/9630, FINT-4350/4402, HRDN-7230, PKGS-7370)
# ----------------------------------------------------------------------------
step "10. Audit, intégrité, antimalware"
systemctl enable --now acct >>"$LOG_FILE" 2>&1 || systemctl enable --now psacct >>"$LOG_FILE" 2>&1
backup /etc/default/sysstat
[ -f /etc/default/sysstat ] && sed -i 's/^ENABLED=.*/ENABLED="true"/' /etc/default/sysstat
systemctl enable --now sysstat >>"$LOG_FILE" 2>&1
cat > /etc/audit/rules.d/99-lynis-to-100.rules <<'EOF'
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/sudoers -p wa -k sudoers
-w /etc/sudoers.d/ -p wa -k sudoers
-w /etc/ssh/sshd_config -p wa -k sshd
-w /etc/ssh/sshd_config.d/ -p wa -k sshd
-w /etc/fstab -p wa -k mounts
-w /var/log/lastlog -p wa -k logins
-a always,exit -F arch=b64 -S execve -F euid=0 -F auid>=1000 -F auid!=unset -k root_cmd
EOF
systemctl enable --now auditd >>"$LOG_FILE" 2>&1; augenrules --load >>"$LOG_FILE" 2>&1 && ok "auditd + règles"
backup /etc/default/debsums
if grep -q '^CRON_CHECK' /etc/default/debsums 2>/dev/null; then sed -i 's/^CRON_CHECK=.*/CRON_CHECK=weekly/' /etc/default/debsums; else echo 'CRON_CHECK=weekly' >> /etc/default/debsums; fi
backup /etc/aide/aide.conf
if [ -f /etc/aide/aide.conf ]; then
  if grep -q '^Checksums' /etc/aide/aide.conf; then sed -i 's/^Checksums.*/Checksums = sha512/' /etc/aide/aide.conf; else echo 'Checksums = sha512' >> /etc/aide/aide.conf; fi
fi
systemctl stop clamav-freshclam >/dev/null 2>&1; freshclam >>"$LOG_FILE" 2>&1 || warn "freshclam : signatures non téléchargées (réseau ?)"
systemctl enable --now clamav-freshclam clamav-daemon >>"$LOG_FILE" 2>&1
rkhunter --update >>"$LOG_FILE" 2>&1; rkhunter --propupd >>"$LOG_FILE" 2>&1 && ok "rkhunter : base des propriétés à jour"
echo "  ... initialisation de la base AIDE (plusieurs minutes)"
if have aideinit; then aideinit -y -f >>"$LOG_FILE" 2>&1 && ok "base AIDE (sha512)"; else aide --init >>"$LOG_FILE" 2>&1; fi

# ----------------------------------------------------------------------------
# 11. Mises à jour, bannières, GRUB, droits (PKGS-7420, BANN-*, BOOT-5122, FILE-7524)
# ----------------------------------------------------------------------------
step "11. Mises à jour auto, bannières, GRUB, droits"
printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' > /etc/apt/apt.conf.d/20auto-upgrades
systemctl enable --now unattended-upgrades >>"$LOG_FILE" 2>&1 && ok "unattended-upgrades"
backup /etc/issue /etc/issue.net
BANNER="Acces reserve aux personnes autorisees. Toute connexion est journalisee.
Authorized access only. All activity is monitored and logged."
echo "$BANNER" > /etc/issue; echo "$BANNER" > /etc/issue.net; ok "bannières légales"

if [ "$DO_GRUB" = yes ] && have grub-mkpasswd-pbkdf2 && [ -f /etc/grub.d/10_linux ]; then
  if [ -z "$GRUB_PASSWORD" ] && [ "$ASSUME_YES" != yes ] && [ -t 0 ]; then
    read -rsp "  Mot de passe GRUB (vide = ignorer) : " GRUB_PASSWORD; echo
    if [ -n "$GRUB_PASSWORD" ]; then read -rsp "  Confirmation : " GP2; echo; [ "$GRUB_PASSWORD" = "$GP2" ] || { warn "différents : GRUB ignoré"; GRUB_PASSWORD=""; }; fi
  fi
  if [ -n "$GRUB_PASSWORD" ]; then
    HASH="$(printf '%s\n%s\n' "$GRUB_PASSWORD" "$GRUB_PASSWORD" | grub-mkpasswd-pbkdf2 2>/dev/null | awk '/grub.pbkdf2/{print $NF}')"
    backup /etc/grub.d/40_custom /etc/grub.d/10_linux
    sed -i '/^set superusers=/d;/^password_pbkdf2 /d' /etc/grub.d/40_custom
    printf 'set superusers="root"\npassword_pbkdf2 root %s\n' "$HASH" >> /etc/grub.d/40_custom
    grep -q -- '--unrestricted' /etc/grub.d/10_linux || sed -i 's/^CLASS="--class gnu-linux --class gnu --class os"/CLASS="--class gnu-linux --class gnu --class os --unrestricted"/' /etc/grub.d/10_linux
    update-grub >>"$LOG_FILE" 2>&1 && ok "GRUB protégé (édition), démarrage normal libre"
  else
    warn "GRUB non protégé (BOOT-5122 : 4 points perdus)"
  fi
  unset GRUB_PASSWORD GP2
fi
chmod 600 /etc/crontab 2>/dev/null
chmod 700 /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/cron.monthly 2>/dev/null
[ -f /boot/grub/grub.cfg ] && chmod 600 /boot/grub/grub.cfg
ok "droits cron / grub.cfg / sshd_config"

# ----------------------------------------------------------------------------
# 12. nginx (HTTP-6710) si présent
# ----------------------------------------------------------------------------
if pkg_ok nginx; then
  step "12. nginx : TLS"
  backup /etc/nginx/nginx.conf
  sed -ri 's/^(\s*ssl_protocols).*/\1 TLSv1.2 TLSv1.3;/' /etc/nginx/nginx.conf
  grep -q 'ssl_prefer_server_ciphers' /etc/nginx/nginx.conf || sed -i '/ssl_protocols/a\        ssl_prefer_server_ciphers on;' /etc/nginx/nginx.conf
  if ! grep -rqs 'ssl_certificate' /etc/nginx/; then
    mkdir -p /etc/nginx/ssl
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 -subj "/CN=$(hostname)" \
      -keyout /etc/nginx/ssl/lynis-to-100.key -out /etc/nginx/ssl/lynis-to-100.crt >>"$LOG_FILE" 2>&1
    chmod 600 /etc/nginx/ssl/lynis-to-100.key
    cat > /etc/nginx/conf.d/99-lynis-to-100-https.conf <<'EOF'
# from-lynis-to-100 : vhost HTTPS (certificat auto-signé à remplacer)
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    ssl_certificate     /etc/nginx/ssl/lynis-to-100.crt;
    ssl_certificate_key /etc/nginx/ssl/lynis-to-100.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    server_tokens off;
    root /var/www/html;
    index index.html index.nginx-debian.html;
    location / { try_files $uri $uri/ =404; }
}
EOF
    warn "vhost HTTPS auto-signé ajouté (port 443)"
    if [ "$DO_FIREWALL" = yes ]; then
      if have ufw; then ufw allow 443/tcp >>"$LOG_FILE" 2>&1; elif [ -f /etc/nftables.conf ]; then sed -i 's/tcp dport { \(.*\) } accept/tcp dport { \1,443 } accept/' /etc/nftables.conf && nft -f /etc/nftables.conf; fi
    fi
  fi
  nginx -t >>"$LOG_FILE" 2>&1 && systemctl reload nginx && ok "nginx : TLS 1.2/1.3"
fi

# ----------------------------------------------------------------------------
# 13. Compilateurs (HRDN-7220/7222)
# ----------------------------------------------------------------------------
step "13. Compilateurs"
COMP_PKGS="$(for p in gcc g++ cpp binutils clang tcc; do pkg_ok "$p" && echo "$p"; done | tr '\n' ' ')"
if [ -n "$COMP_PKGS" ]; then
  if [ "$REMOVE_COMPILERS" = ask ] && [ "$ASSUME_YES" != yes ] && [ -t 0 ]; then
    echo "  Paquets qui seraient supprimés :"
    apt-get -s purge $COMP_PKGS 2>/dev/null | awk '/^Purg/{print "    " $2}'
    read -rp "  Supprimer les compilateurs ? (o/N) " r; [ "${r,,}" = o ] && REMOVE_COMPILERS=yes
  fi
  if [ "$REMOVE_COMPILERS" = yes ]; then
    # shellcheck disable=SC2086
    apt-get purge -y $COMP_PKGS >>"$LOG_FILE" 2>&1 && apt-get autoremove -y >>"$LOG_FILE" 2>&1 && ok "compilateurs supprimés"
  else
    for c in as cc gcc g++ c++ cpp ld clang tcc; do
      p="$(command -v "$c" 2>/dev/null)" || continue
      chmod o-rwx "$(readlink -f "$p")"
    done
    warn "compilateurs conservés, réservés à root (HRDN-7220 : 2 points perdus)"
  fi
else
  ok "aucun compilateur installé"
fi

# ----------------------------------------------------------------------------
# 14. Exceptions documentées (/etc/lynis/custom.prf, ASCII uniquement)
# ----------------------------------------------------------------------------
step "14. Exceptions Lynis documentées"
if [ "$DO_EXCEPTIONS" = yes ]; then
  mkdir -p /etc/lynis
  backup /etc/lynis/custom.prf
  {
    echo "# from-lynis-to-100 : exceptions acceptees (justifications dans le README)"
    echo "# LYNIS : version des depots, mise a jour via apt"
    echo "skip-upgrade-test=yes"
    echo "# BOOT-5180 : test informatif (runlevel), aucune action"
    echo "skip-test=BOOT-5180"
    echo "# BOOT-5264 : durcissement systemd service par service, hors perimetre"
    echo "skip-test=BOOT-5264"
    echo "# LOGG-2154 : pas de serveur syslog distant"
    echo "skip-test=LOGG-2154"
    echo "# TOOL-5002 : gestion de configuration externe (Ansible...)"
    echo "skip-test=TOOL-5002"
    echo "# KRNL-6000 kernel.modules_disabled=1 empeche tout chargement de module"
    echo "skip-test=KRNL-6000:kernel.modules_disabled"
    echo "# MALW-3280 : ClamAV actif mais ce test ne detecte que les antivirus commerciaux ou Wazuh"
    echo "skip-test=MALW-3280"
    if ! lsblk -no TYPE -s "$(findmnt -no SOURCE /)" 2>/dev/null | grep -q crypt; then
      echo "# DEB-0510 : disque systeme non chiffre (chiffrer = reinstaller)"
      echo "skip-test=DEB-0510"
    fi
  } > /etc/lynis/custom.prf
  ok "/etc/lynis/custom.prf écrit"
else
  warn "aucune exception écrite (--no-exceptions) : 100 inatteignable sur la plupart des systèmes"
fi

# Paquets désinstallés mais non purgés (PKGS-7346)
dpkg -l | awk '/^rc/{print $2}' | xargs -r dpkg --purge >>"$LOG_FILE" 2>&1
# apt-listbugs en DERNIER : il épingle les paquets bogués et bloquerait les installations ci-dessus
apt_install apt-listbugs

# ----------------------------------------------------------------------------
# Audit final
# ----------------------------------------------------------------------------
step "Audit final"
SCORE_AFTER="$(run_lynis)"
echo
echo "  Score Lynis : ${SCORE_BEFORE:-?}  ->  ${G}${SCORE_AFTER:-?}${N}"
PARTIAL="$(grep -E 'Performing test ID|Hardening: assigned partial' /var/log/lynis.log | grep -B1 'partial' | grep 'Performing test ID' | sed -E 's/.*test ID ([A-Z0-9-]+) \((.*)\)/    \1  \2/')"
if [ -n "$PARTIAL" ]; then
  echo "  Tests encore incomplets :"; echo "$PARTIAL"
fi
cat <<EOF

${Y}À FAIRE MAINTENANT :${N}
  1. Ouvrez une NOUVELLE session SSH avant de fermer celle-ci :
       ssh -p ${EFFECTIVE_SSH_PORT} <utilisateur>@<ip>      (utilisateurs : ${ALLOW_USERS})
  2. Redémarrez (sudo reboot) pour appliquer /tmp, /dev, USB, GRUB, modules.
  3. Relancez : sudo lynis audit system --quick

Sauvegardes : ${BACKUP_DIR}      Journal : ${LOG_FILE}
EOF
