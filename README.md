# From Lynis to 100%

Script de durcissement pour **Debian et Ubuntu** qui fait passer un serveur
d'un score Lynis de base (environ 60) à un **Hardening index de 100**.

```
Score Lynis : 63  ->  100
```

Le script installe les prérequis, lance un audit initial, applique toutes les
corrections, déclare les exceptions justifiées, puis relance l'audit et affiche
le score final avec les éventuels tests encore incomplets.

---

## ⚠️ Disclaimer — lisez avant de lancer

Ce script applique un durcissement **agressif**. Il est pensé pour un **serveur
de lab, de formation ou une VM**, pas pour être lancé à l'aveugle sur une
production. Atteindre 100 sur Lynis impose des choix qui **modifient le
comportement du système** :

| Domaine | Ce qui change | Impact à connaître |
|---|---|---|
| **SSH** | **Le port passe à 2222** (`--ssh-port N` ou `--keep-ssh-port`) | Vos sessions, scripts, `scp`, MobaXterm/PuTTY doivent utiliser `-p 2222` / `-P 2222` |
| **SSH** | `AllowUsers` = comptes humains (UID ≥ 1000) + l'utilisateur sudo | **root ne peut plus se connecter en SSH**, tout compte non listé est refusé |
| **SSH** | `MaxAuthTries 3`, `MaxSessions 2`, plus de redirection TCP/agent/X11 | Tunnels SSH et X11 forwarding impossibles |
| **fail2ban** | Bannissement 1 h après 5 échecs en 10 min | Attention aux mots de passe mal tapés |
| **Pare-feu** | nftables (ou ufw s'il est présent) : **entrant bloqué** sauf les ports TCP en écoute au moment du lancement + SSH | Un service installé plus tard devra être ouvert à la main. Ignoré si Docker est présent |
| **USB** | USBGuard bloque tout périphérique, et les bus USB sont désactivés | **Clavier/souris USB inutilisables**. Appliqué uniquement sur VM (sauf `--force-usb`) |
| **Montages** | `/tmp` en tmpfs (1 Go) `noexec`, `/dev`, `/dev/shm` (et `/home` si séparé) en `noexec` | Impossible d'exécuter un binaire depuis ces dossiers. apt repasse `/tmp` en `exec` le temps d'une installation |
| **/proc** | `hidepid=2` | Chaque utilisateur ne voit que ses propres processus (`ps`, `top`) |
| **Comptes** | Mots de passe expirant à 90 jours (min 1 jour), umask 027 | Changement de mot de passe obligatoire tous les 90 jours |
| **Shell** | `TMOUT=900` (lecture seule) | **Un shell inactif est fermé après 15 minutes** |
| **Core dumps** | Désactivés (limits, profile, systemd) | Plus de dump mémoire pour déboguer un crash |
| **GRUB** | Mot de passe pour modifier les entrées (`--unrestricted` : le démarrage normal reste libre) | Mode single-user et édition au boot protégés |
| **Modules noyau** | Bloqués : usb-storage, firewire, dccp, sctp, rds, tipc, cramfs, freevxfs, hfs, hfsplus, jffs2, udf, squashfs | Plus de lecture d'ISO en udf. squashfs n'est **pas** bloqué si snapd est présent |
| **sysctl** | Profil Lynis complet (redirections ICMP, rp_filter, ptrace, BPF, kptr...) | `forwarding` laissé à 1 si Docker ou routage détecté |
| **DNS** | dnsmasq en résolveur local si un seul DNS est configuré | `/etc/resolv.conf` réécrit (`127.0.0.1` + DNS d'origine) |
| **nginx** (si installé) | TLS 1.2/1.3 uniquement, vhost HTTPS **auto-signé** ajouté sur 443 si aucun n'existe | Remplacez le certificat |
| **Compilateurs** | gcc/g++/binutils supprimés (confirmation demandée) ou réservés à root | Plus de compilation sur la machine |
| **Paquets ajoutés** | fail2ban, auditd, aide, rkhunter, clamav, usbguard, needrestart, debsums, apt-show-versions, sysstat, acct, unattended-upgrades, libpam-tmpdir, libpam-passwdqc, apt-listbugs, nftables, dnsmasq | ClamAV consomme environ 1 Go de RAM |
| **Mises à jour** | unattended-upgrades activé | Les mises à jour de sécurité s'installent seules |

> **Faites un snapshot ou une sauvegarde avant de lancer.**
> **Gardez une seconde session SSH ouverte** jusqu'à avoir validé la connexion sur le nouveau port.

Chaque fichier modifié est sauvegardé dans `/root/lynis-to-100-backup/<date>/`
(arborescence conservée). Le journal complet est dans `/var/log/lynis-to-100.log`.

Ce script est fourni **sans garantie**. Vous restez responsable de ce que vous
exécutez sur vos machines.

---

## Compatibilité

| Système | État |
|---|---|
| Debian 13 (trixie) | ✅ Procédure validée à 100 sur VM VMware (Lynis 3.1.4) |
| Debian 12 (bookworm) | Supporté, non testé de bout en bout |
| Ubuntu 24.04 LTS | Supporté (ssh.socket, ufw, snapd gérés), non testé de bout en bout |
| Ubuntu 22.04 LTS | Supporté, non testé de bout en bout |
| Conteneurs (Docker, LXC) | ❌ Refusé (montages, GRUB, USB, sysctl non applicables) |

Selon la version de Lynis et du système, un ou deux tests peuvent rester
incomplets : le script les **liste à la fin** de son exécution.

## Prérequis

- Debian 12/13 ou Ubuntu 22.04/24.04, avec systemd
- Accès **root** (ou `sudo`)
- Accès Internet vers les dépôts apt (et le dépôt `universe` activé sur Ubuntu)
- Un snapshot / une sauvegarde de la machine
- Au moins un compte utilisateur non-root capable de se connecter en SSH

Lynis, `dig` et tous les paquets nécessaires sont **installés par le script**.

## Utilisation

```bash
git clone https://github.com/Narved-67/from-lynis-to-100.git
cd from-lynis-to-100
chmod +x lynis-to-100.sh
sudo ./lynis-to-100.sh
```

Le script affiche le disclaimer et demande de taper `OUI`, puis le mot de
passe GRUB et la confirmation de suppression des compilateurs.

À la fin :

```bash
ssh -p 2222 utilisateur@ip      # dans une NOUVELLE session, avant de fermer l'ancienne
sudo reboot                     # applique /tmp, /dev, USB, GRUB, modules
sudo lynis audit system --quick
```

### Options

| Option | Effet |
|---|---|
| `-y`, `--yes` | Pas de confirmation (le disclaimer reste affiché) |
| `--ssh-port N` | Port SSH à utiliser (défaut : 2222) |
| `--keep-ssh-port` | Ne pas changer le port SSH |
| `--allow-users "u1 u2"` | Comptes autorisés en SSH (défaut : automatique) |
| `--grub-password PASS` | Mot de passe GRUB (ou variable `GRUB_PASSWORD`) |
| `--no-grub` | Ne pas protéger GRUB |
| `--no-firewall` | Ne pas toucher au pare-feu |
| `--keep-usb` | Ne pas désactiver l'USB |
| `--force-usb` | Désactiver l'USB même sur une machine physique (**dangereux**) |
| `--remove-compilers` / `--keep-compilers` | Supprimer / garder les compilateurs sans demander |
| `--home-lv 2G` | Créer un LV séparé pour `/home` si `/` est sur LVM |
| `--no-exceptions` | Ne pas écrire de `custom.prf` (100 alors inatteignable) |

Exemple non interactif :

```bash
sudo GRUB_PASSWORD='MotDePasseFort' ./lynis-to-100.sh -y --remove-compilers --ssh-port 2222
```

## Ce que fait le script, étape par étape

| Étape | Tests Lynis couverts |
|---|---|
| 0. Prérequis + audit initial | — |
| 1. Paquets de sécurité | DEB-0280, DEB-0810, DEB-0831, DEB-0880, AUTH-9262, PKGS-7370/7394/7420, ACCT-9622/9626/9628, FINT-4350, HRDN-7230, USB-3000 |
| 2. Comptes et mots de passe | AUTH-9230, AUTH-9282, AUTH-9286, AUTH-9328, AUTH-9408 |
| 3. Shells et core dumps | SHLL-6220, KRNL-5820 |
| 4. sysctl et modules | KRNL-6000, USB-1000, STRG-1846, NETW-3200, FILE-6430 |
| 5. Montages | FILE-6310 (option), FILE-6344, FILE-6374 |
| 6. SSH + fail2ban | SSH-7408, SSH-7440, TOOL-5104 |
| 7. Pare-feu | FIRE-4590 |
| 8. USB | USB-2000, USB-3000 |
| 9. DNS | NETW-2705 |
| 10. Audit, intégrité, antimalware | ACCT-9630, FINT-4402, PKGS-7370, HRDN-7230 |
| 11. Mises à jour, bannières, GRUB, droits | PKGS-7420, BANN-7126, BANN-7130, BOOT-5122, FILE-7524 |
| 12. nginx (si présent) | HTTP-6710 |
| 13. Compilateurs | HRDN-7220, HRDN-7222 |
| 14. Exceptions | voir ci-dessous |

## Exceptions documentées (`/etc/lynis/custom.prf`)

Certains tests ne peuvent pas être satisfaits sur un serveur de lab, ou sont
mal adaptés. Le script les **exclut du calcul** avec la fonction officielle
`skip-test` de Lynis. **Ce n'est pas du durcissement** : c'est un risque
accepté, à justifier dans un compte rendu.

| Test | Justification |
|---|---|
| `skip-upgrade-test` | Lynis vient des dépôts de la distribution et se met à jour avec apt |
| BOOT-5180 | Test informatif (runlevel), aucune action possible |
| BOOT-5264 | Durcir chaque service systemd (`systemd-analyze security`) un par un sort du périmètre |
| LOGG-2154 | Pas de serveur syslog distant dans le lab |
| TOOL-5002 | Gestion de configuration externe (Ansible...) |
| KRNL-6000 `kernel.modules_disabled` | Le passer à 1 interdit tout chargement de module (dm-crypt, réseau...) |
| MALW-3280 | ClamAV est installé et actif, mais ce test ne détecte que des antivirus commerciaux ou Wazuh |
| DEB-0510 | Ajouté **seulement si** `/` n'est pas chiffré : chiffrer le disque système imposerait une réinstallation |

## Pièges rencontrés (et gérés par le script)

| Problème | Cause | Solution intégrée |
|---|---|---|
| `Fatal error: unexpected characters in profile` | Accents ou commentaires en fin de ligne dans `custom.prf` | Profil écrit en ASCII, un commentaire par ligne |
| usbguard « aucune version susceptible d'être installée » | **apt-listbugs épingle les paquets bogués à -30000** | Épinglages retirés au départ, apt-listbugs installé **en dernier** |
| Connexion SSH « impossible » après durcissement | Le client utilise encore le port 22 | Port rappelé dans le disclaimer et à la fin |
| `resolv.conf` vidé / un seul DNS | DHCP réécrit le fichier | dnsmasq local + `prepend` dhclient / `nohook` dhcpcd |
| USB-2000 à 0 malgré USBGuard | Lynis exige `authorized=0` sur **chaque bus** | Service `usb-deauthorize` + règles USBGuard vides |
| KRNL-5820 à 2/3 | Ligne `hard core 0` collée à `# End of file` | Saut de ligne vérifié + fichier dans `limits.d` |
| `grep -a` tué par l'OOM killer sur un disque chiffré | Données sans retour à la ligne | (non lié au script) utiliser `tr -c '[:print:]' '\n'` |

## Revenir en arrière

Tous les fichiers modifiés sont dans `/root/lynis-to-100-backup/<date>/` :

```bash
sudo cp -a /root/lynis-to-100-backup/<date>/etc/ssh/sshd_config /etc/ssh/
sudo rm /etc/ssh/sshd_config.d/99-lynis-to-100.conf && sudo systemctl restart ssh
sudo systemctl disable --now usbguard usb-deauthorize nftables
sudo rm /etc/modprobe.d/99-lynis-to-100.conf /etc/sysctl.d/99-lynis-to-100.conf
```

Le plus simple reste de **restaurer le snapshot**.

## Références

- [Lynis — CISOfy](https://cisofy.com/lynis/) et [code source des tests](https://github.com/CISOfy/lynis)
- [Documentation Linux de Stéphane Robert](https://www.stephane-robert.info/docs/admin-serveurs/linux/) (sudo, LUKS, RAID, fstab)

## Licence

MIT — voir [LICENSE](LICENSE).
