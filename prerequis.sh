#!/usr/bin/env bash
# =============================================================================
# from-lynis-to-100 : installation de TOUS les prérequis (étape 1 de lancer.sh)
#
# Part du principe que rien n'est installé. Le script :
#   1. vérifie qu'il tourne en root et identifie la distribution
#   2. répare les dépôts d'une Debian installée sans miroir réseau (cdrom seul)
#   3. installe : curl, certificats, tar, gzip, Python 3 (+ python3-apt), Ansible
#   4. si l'Ansible de la distribution est trop ancien (< 2.15), installe une
#      version récente dans /opt/lynis100-ansible (environnement Python isolé)
#   5. installe les collections Ansible si elles manquent ou sont trop anciennes
#   6. crée inventory.ini (cible : cette machine) ; télécharge le projet si le
#      script est lancé seul, hors du dossier du projet
# Il s'arrête (code 1) à la première erreur. La vérification des versions est
# faite ensuite par verif_prerequis.sh.
#
# Enchaînement complet : bash lancer.sh
#
# Seule partie en shell du projet : Ansible ne peut pas s'installer lui-même.
# =============================================================================
set -euo pipefail
# Tout le script est lu avant exécution (accolades) : il peut se mettre à jour
# lui-même à l'étape 6 sans risque.
{

REPO_TGZ="https://github.com/Narved-67/from-lynis-to-100/archive/refs/heads/main.tar.gz"
ICI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$ICI/site.yml" ]; then DEST="$ICI"; else DEST="${LYNIS100_DIR:-$HOME/from-lynis-to-100}"; fi
VENV=/opt/lynis100-ansible
MIN_CORE="2.15"
MIN_POSIX="1.5.0"
MIN_GENERAL="8.0.0"

ok()    { printf '  \033[32m✔\033[0m %s\n' "$*"; }
ko()    { printf '  \033[31m✖\033[0m %s\n' "$*"; }
etape() { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
stop()  { ko "$*"; printf '\n\033[31mPrérequis incomplets : le durcissement ne sera PAS lancé.\033[0m\n'; exit 1; }
trap 'stop "Erreur inattendue ligne $LINENO (commande : $BASH_COMMAND)"' ERR

# version_ge A B : vrai si A >= B
version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }

# --------------------------------------------------------------------------- 1
etape "1/6 Contrôles de base"
[ "$(id -u)" -eq 0 ] || stop "À lancer en root : su -  (ou sudo -i), puis relancer"
ok "root"
[ -r /etc/os-release ] || stop "/etc/os-release introuvable : distribution inconnue"
# shellcheck disable=SC1091
. /etc/os-release
FAMILLE=""
if command -v apt-get >/dev/null; then FAMILLE=debian
elif command -v dnf >/dev/null; then FAMILLE=redhat
elif command -v pacman >/dev/null; then FAMILLE=arch
fi
[ -n "$FAMILLE" ] || stop "Gestionnaire de paquets non supporté (apt, dnf ou pacman requis)"
ok "${PRETTY_NAME:-$ID} (famille $FAMILLE)"
command -v systemctl >/dev/null || stop "systemd est requis"
ok "systemd"

# --------------------------------------------------------------------------- 2
etape "2/6 Dépôts de paquets"
if [ "$FAMILLE" = debian ] && [ "${ID:-}" = debian ]; then
  if grep -qs '^deb cdrom:' /etc/apt/sources.list; then
    sed -i 's/^deb cdrom:/# deb cdrom:/' /etc/apt/sources.list
    ok "source cdrom désactivée"
  fi
  if ! grep -rqsE '^(deb|URIs:).*(deb\.debian\.org|ftp\..*debian|debian\.org)' /etc/apt/sources.list /etc/apt/sources.list.d/; then
    CODENAME="${VERSION_CODENAME:?codename Debian introuvable}"
    cat >> /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian ${CODENAME} main
deb http://deb.debian.org/debian ${CODENAME}-updates main
deb http://security.debian.org/debian-security ${CODENAME}-security main
EOF
    ok "dépôts deb.debian.org ajoutés (${CODENAME})"
  fi
fi
case "$FAMILLE" in
  debian) apt-get update -q || stop "apt-get update a échoué (réseau ? dépôts ?)" ;;
  redhat)
    if [ "${ID:-}" != fedora ]; then
      if [ "${ID:-}" = rhel ]; then
        dnf install -y "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${VERSION_ID%%.*}.noarch.rpm" \
          || stop "Installation d'EPEL impossible"
      else
        dnf install -y epel-release || stop "Installation d'EPEL impossible"
      fi
      dnf config-manager --set-enabled crb 2>/dev/null || true
      ok "EPEL"
    fi ;;
  arch) pacman -Sy --noconfirm || stop "pacman -Sy a échoué (réseau ? miroirs ?)" ;;
esac
ok "dépôts à jour"

# --------------------------------------------------------------------------- 3
etape "3/6 Paquets : curl, certificats, tar, gzip, Python 3, Ansible"
case "$FAMILLE" in
  debian) DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
            ca-certificates curl tar gzip python3 python3-apt python3-venv ansible ;;
  redhat) dnf install -y ca-certificates curl tar gzip python3 ansible \
            || dnf install -y ca-certificates curl tar gzip python3 ansible-core ;;
  arch)   pacman -S --noconfirm --needed ca-certificates curl tar gzip python ansible ;;
esac
ok "paquets installés"

# --------------------------------------------------------------------------- 4
etape "4/6 Version d'Ansible (minimum ansible-core $MIN_CORE)"
core_version() { ansible --version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1; }
CORE="$(core_version || true)"
if [ -z "$CORE" ] || ! version_ge "$CORE" "$MIN_CORE"; then
  ok "Ansible de la distribution trop ancien (${CORE:-absent}) : installation récente dans $VENV"
  python3 -m venv "$VENV" || stop "python3 -m venv impossible (paquet python3-venv manquant ?)"
  "$VENV/bin/pip" install -q --upgrade pip
  "$VENV/bin/pip" install -q "ansible>=10" || stop "pip install ansible a échoué (accès à pypi.org ?)"
  for b in ansible ansible-playbook ansible-galaxy ansible-vault; do
    ln -sf "$VENV/bin/$b" "/usr/local/bin/$b"
  done
  hash -r
  CORE="$(core_version || true)"
fi
version_ge "${CORE:-0}" "$MIN_CORE" || stop "ansible-core ${CORE:-absent} < $MIN_CORE"
ok "ansible-core $CORE"

# --------------------------------------------------------------------------- 5
etape "5/6 Collections Ansible"
coll_version() {
  ansible-galaxy collection list "$1" 2>/dev/null | awk -v c="$1" '$1==c {print $2}' | sort -V | tail -n1
}
POSIX="$(coll_version ansible.posix || true)"
GENERAL="$(coll_version community.general || true)"
if [ -z "$POSIX" ] || ! version_ge "$POSIX" "$MIN_POSIX" \
   || [ -z "$GENERAL" ] || ! version_ge "$GENERAL" "$MIN_GENERAL"; then
  ansible-galaxy collection install -U "ansible.posix:>=$MIN_POSIX" "community.general:>=$MIN_GENERAL" \
    || stop "Installation des collections impossible (accès à galaxy.ansible.com ?)"
  POSIX="$(coll_version ansible.posix || true)"
  GENERAL="$(coll_version community.general || true)"
fi
version_ge "${POSIX:-0}" "$MIN_POSIX"     || stop "ansible.posix ${POSIX:-absent} < $MIN_POSIX"
version_ge "${GENERAL:-0}" "$MIN_GENERAL" || stop "community.general ${GENERAL:-absent} < $MIN_GENERAL"
ok "ansible.posix $POSIX"
ok "community.general $GENERAL"

# --------------------------------------------------------------------------- 6
etape "6/6 Projet from-lynis-to-100 dans $DEST"
if [ ! -f "$DEST/site.yml" ]; then
  mkdir -p "$DEST"
  curl -fsSL "$REPO_TGZ" | tar xz --strip-components=1 -C "$DEST" \
    || stop "Téléchargement du projet impossible (accès à github.com ?)"
  ok "projet téléchargé"
else
  ok "projet présent"
fi
if [ ! -f "$DEST/inventory.ini" ]; then
  printf '[lynis_targets]\nlocalhost ansible_connection=local ansible_become_method=su\n' > "$DEST/inventory.ini"
  ok "inventory.ini créé (cible : cette machine)"
else
  ok "inventory.ini existant conservé"
fi

trap - ERR
printf '\n\033[1;32mPrérequis installés.\033[0m Vérification : bash %s/verif_prerequis.sh\n' "$DEST"
exit 0
}
