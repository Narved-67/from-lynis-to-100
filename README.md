# From Lynis to 100%

Rôle et playbook **Ansible** qui durcissent un serveur **Debian ou Ubuntu**
pour faire passer son score Lynis (*Hardening index*) d'environ 60 à **100**.

```
Score Lynis : 62 -> 100
```

Le playbook vérifie les prérequis, installe tous les outils dont il a besoin,
sauvegarde la configuration, lance un audit initial, applique le durcissement,
déclare les exceptions justifiées, bascule le port SSH sans risque de coupure,
puis relance l'audit et affiche le score avec les tests encore incomplets.

---

## ⚠️ Disclaimer — lisez avant de lancer

Ce rôle applique un durcissement **agressif**, pensé pour un **serveur de lab,
de formation ou une VM**, pas pour être appliqué à l'aveugle en production.
Atteindre 100 sur Lynis impose des choix qui **modifient le comportement du
système**. Le play refuse de démarrer tant que vous n'avez pas confirmé avec
`-e lynis100_i_have_a_snapshot=true`.

| Domaine | Ce qui change | Impact à connaître |
|---|---|---|
| **SSH** | **Le port passe à 2222** (`lynis100_ssh_port`) | Clients, scripts, `scp -P`, MobaXterm/PuTTY à mettre à jour. **Inventaire : `ansible_port=2222` pour les exécutions suivantes** |
| **SSH** | `AllowUsers` = comptes humains (UID ≥ 1000) + l'utilisateur Ansible | **root ne peut plus se connecter en SSH** ; tout compte non listé est refusé |
| **SSH** | `MaxAuthTries 3`, `MaxSessions 2`, redirections TCP/agent/X11 coupées | Tunnels SSH et X11 impossibles |
| **fail2ban** | Bannissement 1 h après 5 échecs en 10 min | Ajoutez votre poste à `lynis100_fail2ban_ignoreip` |
| **Pare-feu** | nftables (ou ufw s'il est présent) : **entrant bloqué** sauf les ports TCP en écoute au lancement + SSH | Un service ajouté plus tard devra être ouvert. Ignoré si Docker est présent |
| **USB** | USBGuard bloque tout, les bus USB sont désactivés | **Clavier/souris USB inutilisables**. VM uniquement (sauf `lynis100_disable_usb_on_bare_metal`) |
| **Montages** | Options Lynis (`nodev`, `nosuid`, `noexec`) sur `/tmp`, `/dev`, `/dev/shm`, `/var`, `/var/log`, `/var/tmp`, `/boot`, `/home` s'ils sont séparés ; `/tmp` en tmpfs s'il n'existe pas | Rien ne s'exécute depuis `/tmp` ou `/dev/shm`. apt repasse `/tmp` en `exec` le temps d'une installation |
| **/proc** | `hidepid=2` | Chaque utilisateur ne voit que ses processus |
| **Comptes** | Expiration à 90 jours (min 1 jour) appliquée aux comptes existants, umask 027 | Changement de mot de passe obligatoire tous les 90 jours |
| **Shell** | `TMOUT=900` en lecture seule | **Shell inactif fermé après 15 minutes** |
| **Core dumps** | Désactivés | Plus de dump mémoire après un crash |
| **GRUB** | Mot de passe pour modifier les entrées (démarrage normal libre) | Mot de passe **obligatoire** dans les variables |
| **Modules noyau** | usb-storage, firewire, dccp, sctp, rds, tipc, cramfs, freevxfs, hfs, hfsplus, jffs2, udf, squashfs bloqués | Plus d'ISO en udf ; squashfs conservé si snapd est présent |
| **DNS** | dnsmasq en résolveur local si un seul DNS est configuré | `/etc/resolv.conf` réécrit |
| **Compilateurs** | gcc, g++, binutils supprimés après simulation apt | **rkhunter part avec binutils** (ClamAV le remplace). Suppression annulée si un autre paquet serait retiré |
| **nginx** (si installé) | TLS 1.2/1.3, vhost HTTPS **auto-signé** sur 443 si aucun certificat | Remplacez le certificat |
| **Paquets** | fail2ban, auditd, aide, clamav, usbguard, needrestart, debsums, sysstat, acct, unattended-upgrades, apt-listbugs, apt-listchanges, nftables, dnsmasq ; `apt upgrade` | ClamAV utilise environ 1 Go de RAM |

> **Faites un snapshot avant de lancer.** En cas d'erreur, les étapes sensibles
> (fstab, SSH, nginx, port SSH) se restaurent d'elles-mêmes, mais un snapshot
> reste le seul vrai retour arrière.

Une archive des fichiers modifiés est créée sur la cible dans
`/root/lynis-to-100-backup/<date>.tar.gz`.

Ce projet est fourni **sans garantie**. Vous êtes responsable de ce que vous
exécutez sur vos machines.

---

## Compatibilité

| Cible | État |
|---|---|
| Debian 13 (trixie) | Rôle **exécuté** sur VM VMware vierge (Debian 13.7, Lynis 3.1.4) : **63 → 99** au premier passage (seul FILE-6310 restait, désormais en exception) |
| Ubuntu 24.04 LTS | Rôle **exécuté** en conteneur systemd : 62 → 94 (le reste n'est pas applicable en conteneur), idempotent, bascule SSH validée |
| Debian 12, Ubuntu 22.04 | Supportés, non testés de bout en bout |
| Conteneurs | Refusés (sauf `lynis100_allow_container=true`, réservé aux tests) |

## Prérequis

**Sur le poste de contrôle**

- ansible-core ≥ 2.15
- Collections `ansible.posix` et `community.general` :
  `ansible-galaxy collection install -r requirements.yml`
- Accès SSH à la cible (clé conseillée)

**Sur la cible**

- Debian 12/13 ou Ubuntu 22.04/24.04 avec systemd, accès Internet aux dépôts apt
- Un compte non-root accessible en SSH, avec `sudo` **ou** le mot de passe root (`su`)
- 2 Go libres sur `/`
- Pour 100 : installer Debian avec le partitionnement **« Partitions /home, /var et /tmp séparées »** (LVM conseillé). Sinon, FILE-6310 (1 point par dossier non séparé) est ajouté en exception justifiée

Python 3, `python3-apt`, Lynis, `dig`, `nft`, `ss`, `findmnt`, `openssl`,
`grub-mkpasswd-pbkdf2` et tous les paquets de sécurité sont **installés par le
playbook**.

## Utilisation

```bash
git clone https://github.com/Narved-67/from-lynis-to-100.git
cd from-lynis-to-100
ansible-galaxy collection install -r requirements.yml

cp inventory.ini.example inventory.ini                         # IP, utilisateur
cp group_vars/lynis_targets.yml.example group_vars/lynis_targets.yml

# Mot de passe GRUB chiffré
mkdir -p group_vars/lynis_targets
ansible-vault create group_vars/lynis_targets/vault.yml
#   lynis100_grub_password: "MotDePasseGrubFort"

ansible-playbook site.yml -e lynis100_i_have_a_snapshot=true \
  --ask-become-pass --ask-vault-pass
```

`--ask-become-pass` demande le mot de passe `sudo`, ou le mot de passe root si
`ansible_become_method=su` (Debian installé avec un mot de passe root).

Après la première exécution :

1. Ajoutez `ansible_port=2222` dans `inventory.ini`.
2. Redémarrez la cible (`/tmp`, `/dev`, USB, GRUB, modules) ou relancez avec `-e lynis100_reboot=true`.
3. Vérifiez : `sudo lynis audit system --quick`.

Le playbook est **idempotent** : une seconde exécution ne modifie rien.

### Tags

Chaque étape peut être lancée ou exclue séparément :
`--tags ssh`, `--skip-tags usb,compilers`… Tags disponibles : `packages`,
`accounts`, `shell`, `kernel`, `mounts`, `ssh`, `firewall`, `usb`, `dns`,
`integrity`, `grub`, `banners`, `nginx`, `compilers`, `exceptions`, `audit`.

### Variables principales

Toutes sont documentées dans [`roles/lynis100/defaults/main.yml`](roles/lynis100/defaults/main.yml).

| Variable | Défaut | Rôle |
|---|---|---|
| `lynis100_i_have_a_snapshot` | `false` | **À passer à `true`** pour confirmer le disclaimer |
| `lynis100_ssh_port` | `2222` | Port SSH final (mettre l'actuel pour ne pas le changer) |
| `lynis100_ssh_allow_users` | `[]` (auto) | Comptes autorisés en SSH |
| `lynis100_fail2ban_ignoreip` | localhost | IP jamais bannies |
| `lynis100_firewall` | `true` | Pare-feu nftables/ufw |
| `lynis100_firewall_extra_tcp_ports` | `[]` | Ports TCP supplémentaires à ouvrir |
| `lynis100_disable_usb` | `true` | Désactivation de l'USB (VM) |
| `lynis100_grub_password` / `lynis100_grub_password_pbkdf2` | vide | Mot de passe GRUB (vault) ou son hash |
| `lynis100_remove_compilers` | `true` | Suppression des compilateurs |
| `lynis100_home_lv_size` | vide | Crée un LV `/home` (ex : `2g`) si `/` est sur LVM |
| `lynis100_upgrade_packages` | `true` | `apt upgrade` avant l'audit final |
| `lynis100_exceptions` | `true` | Écrit `/etc/lynis/custom.prf` |
| `lynis100_fail_below_score` | `0` | Fait échouer le play sous ce score |
| `lynis100_reboot` | `false` | Redémarre à la fin |

## Ce que fait le rôle

| Fichier | Tests Lynis couverts |
|---|---|
| `00_preflight.yml` | Prérequis : root, distribution, systemd, conteneur, disque, port SSH libre, AllowUsers, GRUB, apt, sauvegarde |
| `01_baseline.yml` | Audit initial |
| `02_packages.yml` | DEB-0280, DEB-0811, DEB-0831, DEB-0880, AUTH-9262, PKGS-7370/7392/7394/7420, ACCT-9622/9626/9628, FINT-4350, HRDN-7230, USB-3000 |
| `03_accounts.yml` | AUTH-9230, AUTH-9282, AUTH-9286, AUTH-9328, AUTH-9408 |
| `04_shell_coredump.yml` | SHLL-6220, KRNL-5820 |
| `05_kernel.yml` | KRNL-6000, USB-1000, STRG-1846, NETW-3200, FILE-6430 |
| `06_mounts.yml` | FILE-6310 (option LV `/home`), FILE-6344, FILE-6374 |
| `07_ssh_fail2ban.yml` | SSH-7408, SSH-7440, TOOL-5104 |
| `08_firewall.yml` | FIRE-4590 |
| `09_usb.yml` | USB-2000, USB-3000 |
| `10_dns.yml` | NETW-2705 |
| `11_audit_integrity.yml` | ACCT-9630, FINT-4402, PKGS-7370, MAIL-8818 |
| `12_updates_banners_grub.yml` | PKGS-7420, BANN-7126, BANN-7130, BOOT-5122, FILE-7524 |
| `13_nginx.yml` | HTTP-6710 |
| `14_compilers.yml` | HRDN-7220, HRDN-7222 |
| `15_exceptions.yml` | DEB-0810, PKGS-7346, exceptions |
| `16_ssh_port_switch.yml` | SSH-7408 (port) |
| `17_final_audit.yml` | Audit final |

### Gestion des erreurs

| Situation | Comportement |
|---|---|
| Prérequis manquant (OS, root, conteneur, disque, GRUB, AllowUsers sans l'utilisateur Ansible…) | Arrêt **avant toute modification** avec un message explicite |
| Paquet introuvable dans les dépôts | Signalé, les autres sont installés, l'exception correspondante est ajoutée si besoin |
| Verrou dpkg occupé | Attente jusqu'à 5 minutes, puis nouvelles tentatives |
| fstab invalide après modification | Restauration de `/etc/fstab` depuis l'archive |
| Configuration SSH invalide (`sshd -t`) | Drop-in retiré, rien n'est appliqué |
| Nouveau port SSH injoignable | Retour automatique à l'ancien port |
| nginx invalide après modification | Restauration de `nginx.conf` |
| Règles nftables invalides | Refusées avant écriture (`nft -c`) |
| Suppression des compilateurs qui entraînerait d'autres paquets | Annulée, compilateurs réservés à root |
| `custom.prf` avec caractères non ASCII | Refusé avant écriture (sinon Lynis s'arrête) |

## Exceptions documentées (`/etc/lynis/custom.prf`)

Certains tests ne peuvent pas être satisfaits sur un serveur de lab. Ils sont
exclus avec la fonction officielle `skip-test` de Lynis. **Ce n'est pas du
durcissement** : c'est un risque accepté, à justifier dans un compte rendu.

| Test | Justification |
|---|---|
| `skip-upgrade-test` | Lynis vient des dépôts de la distribution et se met à jour avec apt |
| BOOT-5180 | Test informatif (runlevel) |
| BOOT-5264 | Durcir chaque service systemd un par un sort du périmètre |
| LOGG-2154 | Pas de serveur syslog distant |
| TOOL-5002 | Gestion de configuration externe (ce playbook) |
| KRNL-6000 `kernel.modules_disabled` | 1 interdit tout chargement de module |
| MALW-3280 | ClamAV est actif, mais ce test ne détecte que les antivirus commerciaux ou Wazuh |
| DEB-0510 | **Si `/` n'est pas chiffré** : chiffrer imposerait une réinstallation |
| DEB-0810 | **Si apt-listbugs n'existe pas** dans les dépôts (cas d'Ubuntu) |
| FILE-6310 | **Si /home ou /var ne sont pas séparés** : repartitionner imposerait une réinstallation (`lynis100_exception_unpartitioned`) |

## Pièges connus (gérés par le rôle)

| Problème | Cause | Solution intégrée |
|---|---|---|
| `Fatal error: unexpected characters in profile` | Accents ou commentaires en fin de ligne dans `custom.prf` | Profil ASCII, contrôlé avant écriture |
| usbguard « aucune version installable » | **apt-listbugs épingle les paquets bogués à -30000** | Épinglages retirés au départ, apt-listbugs installé en dernier |
| SSH injoignable après durcissement | Le client utilise encore le port 22 | Bascule en 3 étapes avec retour arrière, `ansible_port` mis à jour |
| USB-2000 à 0 malgré USBGuard | Lynis exige `authorized=0` sur chaque bus | Service `lynis100-usb-deauthorize` |
| KRNL-5820 à 2/3 | Ligne `hard core 0` collée à `# End of file` | Saut de ligne vérifié + fichier dans `limits.d` |
| `Missing privilege separation directory: /run/sshd` | `ssh.socket` n'a pas encore lancé sshd | Dossier créé avant `sshd -t` |
| HRDN-7220 bloqué | rkhunter dépend de binutils | rkhunter remplacé par ClamAV si les compilateurs sont supprimés |

## Références

- [Lynis — CISOfy](https://cisofy.com/lynis/) et [code source des tests](https://github.com/CISOfy/lynis)
- [Documentation Linux de Stéphane Robert](https://www.stephane-robert.info/docs/admin-serveurs/linux/)
- [Journal des vérifications du rôle](docs/VERIFICATION.md)

## Licence

MIT — voir [LICENSE](LICENSE).
