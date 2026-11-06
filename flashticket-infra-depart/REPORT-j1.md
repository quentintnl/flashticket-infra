# REPORT J1 - FlashTicket

## Scores

| Mesure                                       | Avant                         | Après                                       |
| -------------------------------------------- | ----------------------------- | ------------------------------------------- |
| Lynis (indice de durcissement)               | [64](preuves/lynis-avant.txt) | [64](preuves/lynis-dernier-indice.txt)      |
| `systemd-analyze security ticketpdf.service` | 1.1                           | [1.1 OK](preuves/systemd-analyze-apres.txt) |

Le relevé Lynis & 'systemd-analyze security ticketpdf.service' « avant » a été fait après le durcissement SSH, sysctl et pare-feu, ce qui peut expliquer l'absence d'écart.

## Refus AppArmor

Lecture de `/etc/ssh/sshd_config` par ticketpdf, hors de son profil ([capture](preuves/apparmor-denied.txt), [profil en enforce](preuves/aa-status.txt)) :

```text
Nov 06 15:05:00 gracious-bee kernel: audit: type=1400 audit(1793977500.826:349): apparmor="DENIED" operation="open" class="file" profile="/opt/ticketpdf/bin/ticketpdf" name="/etc/ssh/sshd_config" pid=229353 comm="ticketpdf" requested_mask="r" denied_mask="r" fsuid=999 ouid=0
```

## Schéma réseau

VPC `10.0.0.0/16`, 2 zones de disponibilité ([network.tf](network/network.tf)) :

```text
Internet (443)     Admin (22)
       |               |
       v               v
+-----------------------------+
| Public                      |
| 10.0.1.0/24 | 10.0.2.0/24   |
+-----------------------------+
       | 8443, 22
       v
+-----------------------------+
| Applicatif                  |
| 10.0.11.0/24 | 10.0.12.0/24 |
+-----------------------------+
       | 5432
       v
+-----------------------------+
| Données                     |
| 10.0.21.0/24 | 10.0.22.0/24 |
+-----------------------------+
```
