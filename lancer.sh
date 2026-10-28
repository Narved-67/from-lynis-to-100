#!/usr/bin/env bash
# =============================================================================
# from-lynis-to-100 : enchaînement complet (lancé par install.sh)
#   1. prerequis.sh       installe tous les prérequis (arrêt à la 1re erreur)
#   2. verif_prerequis.sh vérifie chaque prérequis avec --version (arrêt si un manque)
#   3. ansible-playbook   questionnaire, durcissement, récapitulatif final
# Chaque étape ne démarre que si la précédente a réussi.
# =============================================================================
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

[ "$(id -u)" -eq 0 ] || { echo "À lancer en root : su -  (ou sudo -i), puis : bash $PWD/lancer.sh"; exit 1; }

printf '\033[1m== 1/3 Installation des prérequis ==\033[0m\n'
bash ./prerequis.sh

printf '\n\033[1m== 2/3 Vérification des prérequis ==\033[0m\n'
bash ./verif_prerequis.sh

printf '\n\033[1m== 3/3 Durcissement (Ansible) ==\033[0m\n'
exec ansible-playbook site.yml "$@"
