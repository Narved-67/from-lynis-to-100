#!/usr/bin/env bash
# =============================================================================
# from-lynis-to-100 : vérification des prérequis (étape 2 de lancer.sh)
#
# Lance « --version » sur chaque prérequis installé par prerequis.sh, contrôle
# les versions minimales, les fichiers du projet et la syntaxe du playbook.
# Code 0 : tout est bon. Code 1 : au moins un prérequis manque, Ansible ne
# doit pas être lancé.
# =============================================================================
set -uo pipefail

ICI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIN_CORE="2.15"
MIN_POSIX="1.5.0"
MIN_GENERAL="8.0.0"
ECHECS=0

version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }
ligne() { printf '  %b %-34s %.70s\n' "$1" "$2" "$3"; }
bon()   { ligne '\033[32m✔\033[0m' "$1" "$2"; }
mauvais() { ligne '\033[31m✖\033[0m' "$1" "$2"; ECHECS=$((ECHECS + 1)); }

# verif NOM COMMANDE... : exécute la commande de version, affiche la 1re ligne
verif() {
  local nom="$1"; shift
  local sortie
  if sortie="$("$@" 2>&1)" && [ -n "$sortie" ]; then
    sortie="${sortie%%$'\n'*}"
    bon "$nom" "$sortie"
  else
    mauvais "$nom" "absent ou en erreur (${*})"
  fi
}

printf '\n\033[1;36m▶ Vérification des prérequis (--version)\033[0m\n'
verif curl              curl --version
verif tar               tar --version
verif gzip              gzip --version
verif python3           python3 --version
verif systemd           systemctl --version
verif ansible           ansible --version
verif ansible-playbook  ansible-playbook --version
verif ansible-galaxy    ansible-galaxy --version

if command -v apt-get >/dev/null; then
  PYSYS=/usr/bin/python3; [ -x "$PYSYS" ] || PYSYS=python3
  verif python3-apt "$PYSYS" -c 'import apt_pkg; print("python3-apt (libapt " + apt_pkg.VERSION + ")")'
fi

printf '\n\033[1;36m▶ Versions minimales\033[0m\n'
CORE="$(ansible --version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)"
if [ -n "$CORE" ] && version_ge "$CORE" "$MIN_CORE"; then bon ansible-core "$CORE (>= $MIN_CORE)"
else mauvais ansible-core "${CORE:-absent} (>= $MIN_CORE requis)"; fi

for c in "ansible.posix:$MIN_POSIX" "community.general:$MIN_GENERAL"; do
  nom="${c%%:*}"; min="${c##*:}"
  v="$(ansible-galaxy collection list "$nom" 2>/dev/null | awk -v c="$nom" '$1==c {print $2}' | sort -V | tail -n1)"
  if [ -n "$v" ] && version_ge "$v" "$min"; then bon "$nom" "$v (>= $min)"
  else mauvais "$nom" "${v:-absent} (>= $min requis)"; fi
done

printf '\n\033[1;36m▶ Projet\033[0m\n'
for f in site.yml questions.yml ansible.cfg inventory.ini requirements.yml \
         roles/lynis100/tasks/main.yml callback_plugins/lynis100_tui.py; do
  if [ -f "$ICI/$f" ]; then bon "$f" "présent"; else mauvais "$f" "manquant"; fi
done
if (cd "$ICI" && ansible-playbook --syntax-check site.yml >/dev/null 2>&1); then
  bon "syntax-check" "site.yml valide"
else
  mauvais "syntax-check" "site.yml invalide : cd $ICI && ansible-playbook --syntax-check site.yml"
fi

if [ "$ECHECS" -eq 0 ]; then
  printf '\n\033[1;32mTous les prérequis sont OK.\033[0m\n'
  exit 0
fi
printf '\n\033[1;31m%d prérequis en échec : Ansible ne sera pas lancé.\033[0m\n' "$ECHECS"
printf 'Corrigez-les (ou relancez prerequis.sh), puis relancez : bash %s/lancer.sh\n' "$ICI"
exit 1
