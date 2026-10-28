# Vérification du rôle `lynis100`

Ce document retrace les passes de contrôle effectuées avant publication.

## Passe 1 — Analyse statique

| Contrôle | Résultat |
|---|---|
| `ansible-playbook --syntax-check` | ✅ OK |
| `ansible-lint` profil **production** | ✅ 0 erreur, 0 avertissement |

Problèmes trouvés et corrigés pendant cette passe :

| Problème | Correction |
|---|---|
| Noms de tâches contenant `: ` → YAML invalide | Noms entre guillemets |
| Calcul `AllowUsers` : UID comparés comme des chaînes (`'999' >= '1000'` vrai) | Boucle avec conversion `int` |
| Variables non préfixées par le nom du rôle | Rôle renommé `lynis100` (préfixe `lynis100_`) |
| `validate: nginx -t -c %s` : les `include` relatifs échouent depuis /tmp | Test `nginx -t` après écriture + restauration en `rescue` |
| Tâches `when: changed` au lieu de handlers | Handlers (`Recharger sshd`, `Recharger nftables`...) |
| Pipes shell sans `pipefail` | `set -o pipefail` |

## Passe 2 — Exécution réelle

Cible : conteneur **Ubuntu 24.04** avec systemd (rootfs debootstrap, accès SSH
par clé, utilisateur `yd`), exécuté avec `lynis100_allow_container=true`.
Debian 13 n'a pas pu être testée ici (miroir Debian inaccessible depuis
l'environnement de test).

| Exécution | Résultat | Problème révélé → correction |
|---|---|---|
| 1 | ❌ | Espace disque lu dans `ansible_mounts` (absent en overlay) → `df` |
| 2 | ❌ | `ls` des fichiers absents + `pipefail` → boucle bash qui ne garde que les fichiers existants |
| 3 | ❌ | `/etc/modprobe.d` absent → création des dossiers de configuration en préflight |
| 4 | ❌ | Boucle shell finissant sur un `&&` faux → `if ...; then ...; fi` |
| 5 | ❌ puis **retour arrière OK** | `validate: sshd -t -f` sur un drop-in → validation de la configuration complète ensuite. Le `rescue` a bien remis SSH sur le port 22 |
| 6 | ✅ 86 → 87 | Révèle : bannière insuffisante, `apt-listchanges` manquant (DEB-0811), `apt-listbugs` absent d'Ubuntu, **rkhunter dépend de binutils** (suppression des compilateurs annulée), handler sysctl perdu après un échec |
| 7 | ❌ | `/run/sshd` absent tant que `ssh.socket` n'a pas lancé sshd → création du dossier |
| 8 | ❌ | Handler `augenrules` en échec en conteneur → non bloquant |
| 9 | ❌ | Handler notifié **avant** la bascule de port exécuté **après** sur l'ancien port → `flush_handlers` avant la bascule, plus aucun handler après |
| 10 (conteneur neuf) | ✅ **62 → 93** | — |
| 11 (relance, port 2222) | ✅ idempotent | `freshclam` relancé à chaque fois → seulement si aucune signature |
| 12 (conteneur neuf, final) | ✅ **62 → 94** | — |

Les points restants en conteneur sont **impossibles en conteneur** et traités
sur une VM : auditd (ACCT-9628), options de montage (FILE-6310/6344/6374),
AppArmor (MACF-6290), USB (USB-3000), redémarrage noyau (KRNL-5830),
`forwarding` imposé par Docker (KRNL-6000).

La bascule du port SSH (22 → 2222) a été validée de bout en bout, y compris
avec `ssh.socket` (Ubuntu 24.04), ainsi que son retour arrière automatique.

## Passe 3 — Simulation logique sur une VM Debian 13 neuve

Hypothèses : netinst Debian 13, mot de passe root défini (pas de `sudo`),
utilisateur `yd`, connexion Ansible `ansible_user=yd`, `become_method=su`.

| Étape | Comportement attendu | Point d'attention |
|---|---|---|
| pre_tasks `raw` | Installe `python3` / `python3-apt` via `su` si absents | Nécessite `--ask-become-pass` (mot de passe root) |
| 00 Préflight | `systemd-detect-virt --vm` = `vmware`, port 22 détecté, `AllowUsers = yd` | **Échoue volontairement** si `lynis100_grub_password` n'est pas fourni |
| 01 Lynis initial | Score ≈ 60 | 1 à 3 minutes |
| 02 Paquets | Installation sans `Recommends` (pas de MTA ajouté), `apt upgrade` | `usbguard` installable car apt-listbugs n'est pas encore là |
| 03 Comptes | `login.defs` : la regex ne touche que les lignes `CLÉ valeur`, pas les commentaires explicatifs | root et yd expirent à 90 jours |
| 04 Core dumps | `limits.d`, `profile.d`, `coredump.conf(.d)` | — |
| 05 sysctl | Chaque clé appliquée à chaud et persistée | `forwarding` laissé à 1 si Docker/routage |
| 06 Montages | Options exigées par Lynis fusionnées dans fstab, sans changer la source (UUID conservé) | Partitionnement « /home, /var et /tmp séparés » conseillé ; sinon exception FILE-6310 (1 point par dossier) |
| 07 SSH | `/run/sshd` créé, `sshd -t`, reload | Session ouverte conservée |
| 08 nftables | Entrant bloqué sauf 22 + 2222 + services en écoute | fail2ban redémarré après `flush ruleset` |
| 09 USB | VMware → USBGuard (règles vides) + bus désactivés | Clavier console VMware en PS/2 : non affecté |
| 10 DNS | `resolv.conf` à un seul DNS (VMware NAT) → dnsmasq local | — |
| 11 Intégrité | AIDE en SHA512 (plusieurs minutes), freshclam | — |
| 12 GRUB | Hash généré sur la cible (`no_log`), `--unrestricted`, `update-grub` | — |
| 14 Compilateurs | Simulation apt avant purge, annulée si un paquet hors périmètre serait retiré | rkhunter retiré (dépend de binutils), ClamAV garde HRDN-7230 |
| 15 Exceptions | apt-listbugs installé en dernier, `custom.prf` ASCII | DEB-0510 ajouté (disque non chiffré) |
| 16 Port SSH | Écoute 22+2222 → reconnexion sur 2222 → retrait du 22 | **Mettre `ansible_port=2222` dans l'inventaire pour les exécutions suivantes** |
| 17 Audit final | Score, tests incomplets, avertissements | Redémarrer ensuite |

## Passe 4 — Exécution réelle sur Debian 13 vierge

VM VMware, Debian 13.7 netinst, une seule partition, exécution en local
(`ansible_connection=local`, `become_method=su`).

| Résultat | Détail |
|---|---|
| ✅ **63 → 99**, 0 échec | 158 tâches, bascule SSH 22 → 2222 en local |
| Seul test incomplet | FILE-6310 : /home et /var sur la racine (1 point chacun) → exception automatique ajoutée |
| Corrections | Message « appliqué au redémarrage » erroné pour des dossiers non séparés ; avertissements `raw`/`environment` et `reset_connection`/`when` supprimés ; documentation : FILE-6310 vaut 1 point par dossier, pas 10 |

## Passe 5 — Multi-distribution, questionnaire, affichage

| Contrôle | Résultat |
|---|---|
| `ansible-lint` production, `--syntax-check` | ✅ |
| Questionnaire piloté (pexpect) : y partout sauf USB, DNS 192.168.42.2 / 1.1.1.1 | ✅ `lynis100_answers.yml` correct, mot de passe GRUB absent du fichier |
| `-e lynis100_assume_yes=true` | ✅ aucune question, aucune valeur imposée |
| Callback `lynis100_tui` rendu dans un pseudo-terminal (émulateur pyte) | ✅ panneau fixe, journal défilant, bilan final |
| Chemins RHEL / Fedora / Arch | ⚠️ implémentés, **non exécutés** (pas d'image de test disponible) |

Corrections : `fail_msg` évalué même quand l'assertion passe (clé absente en
mode `assume_yes`) → `default('')` ; barre arrondie à 100 % pour 99 → arrondi
inférieur ; ligne du journal en double après un échec ignoré → ordre corrigé.

## Passe 6 — Prérequis installés et vérifiés au début

| Contrôle | Résultat |
|---|---|
| `shellcheck prerequis.sh`, `bash -n` | ✅ |
| `ansible-lint` production | ✅ |
| `prerequis.sh` sur Ubuntu 24.04 sans Ansible (réel, root) | ✅ ansible installé, collections OK, projet téléchargé, syntax-check OK, code 0 |
| Python système sans module `apt_pkg` | ✅ détecté, arrêt avec code 1 : le playbook n'est pas lancé |
| Lancement sans être root | ✅ arrêt immédiat, code 1 |
| Installation d'Ansible récent dans `/opt/lynis100-ansible` (distribution trop ancienne) | ⚠️ non exécutée (pas de Debian 12 / Ubuntu 22.04 de test) |
| Préflight du rôle : commandes requises vérifiées avant modification | ✅ lint + syntaxe ; à confirmer sur VM |
