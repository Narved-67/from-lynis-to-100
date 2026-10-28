#!/usr/bin/env bash
# =============================================================================
# from-lynis-to-100 : installation en une commande (lancé par la ligne du README)
#
#   1. installe curl, tar et gzip si besoin (apt, dnf ou pacman)
#   2. télécharge et décompresse le projet dans ~/from-lynis-to-100 (sans git)
#   3. lance lancer.sh : prérequis → vérification --version → Ansible → récap
#
# Les options sont transmises à Ansible, par ex. :
#   bash <(curl -fsSL .../install.sh) -e lynis100_reask=true
# =============================================================================
set -euo pipefail
{

REPO_TGZ="https://github.com/Narved-67/from-lynis-to-100/archive/refs/heads/main.tar.gz"
DEST="${LYNIS100_DIR:-$HOME/from-lynis-to-100}"

etape() { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
stop()  { printf '\033[31m✖ %s\033[0m\n' "$*"; exit 1; }

[ "$(id -u)" -eq 0 ] || stop "À lancer en root : su -  (ou sudo -i), puis relancer la commande"

etape "Outils de téléchargement et de décompression (curl, tar, gzip)"
if command -v apt-get >/dev/null; then
  apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y -q curl tar gzip ca-certificates
elif command -v dnf >/dev/null; then
  dnf install -y -q curl tar gzip
elif command -v pacman >/dev/null; then
  pacman -Sy --noconfirm --needed curl tar gzip
else
  stop "Gestionnaire de paquets non supporté (apt, dnf ou pacman requis)"
fi
for c in curl tar gzip; do command -v "$c" >/dev/null || stop "$c n'a pas pu être installé"; done

etape "Téléchargement du projet dans $DEST"
mkdir -p "$DEST"
curl -fsSL "$REPO_TGZ" | tar xz --strip-components=1 -C "$DEST" \
  || stop "Téléchargement impossible (accès à github.com ?)"
[ -f "$DEST/lancer.sh" ] || stop "Archive incomplète : lancer.sh absent"
printf '  \033[32m✔\033[0m projet à jour (inventory.ini et réponses conservés)\n'

exec bash "$DEST/lancer.sh" "$@"
}
