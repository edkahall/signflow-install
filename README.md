# SignFlow CMS — installation

Plateforme d'affichage dynamique : gestion centralisée des contenus, programmation,
et pilotage d'un parc d'écrans (Linux, Raspberry Pi, Windows, Android, ChromeOS,
BrightSign).

Ce dépôt contient **uniquement ce qu'il faut pour installer** SignFlow. L'application
est distribuée sous forme d'images conteneurisées : rien n'est compilé sur votre serveur.

---

## Prérequis

| | Minimum | Recommandé |
|---|---|---|
| Système | Ubuntu 22.04 | Ubuntu 24.04 |
| Processeur | 4 cœurs | 8 cœurs ou plus |
| Mémoire | 8 Go | 16 Go |
| Disque | 100 Go | 500 Go et plus (selon le volume de médias) |

Le transcodage vidéo est la tâche la plus exigeante : prévoyez large si vous diffusez
beaucoup de vidéo ou de la 4K.

Docker est installé automatiquement s'il est absent.

Vous aurez besoin des **identifiants du registre d'images**, fournis avec votre licence.

---

## Installation

```bash
git clone https://github.com/<organisation>/signflow-install.git
cd signflow-install
sudo bash install-ubuntu.sh
```

Le script demande vos identifiants de registre, puis enchaîne : prérequis, secrets,
téléchargement des images, démarrage, migrations, vérification, démarrage automatique,
accès réseau, et création du compte administrateur.

Comptez une dizaine de minutes, dont l'essentiel en téléchargement (environ 1 Go).

À la fin, l'adresse d'accès et le **mot de passe administrateur** sont affichés.
Notez-le : il n'est plus jamais montré.

### Installation non interactive

```bash
sudo SIGNFLOW_REGISTRY_USER=... SIGNFLOW_REGISTRY_PASSWORD=... bash install-ubuntu.sh
```

---

## Après l'installation

L'interface est accessible sur `http://<adresse-du-serveur>:8080`.

**Sauvegardez `/opt/signflow/.env`.** Il contient les clés de chiffrement de
l'installation — en particulier `CMS_VAULT_KEY`, sans laquelle les clés d'API
enregistrées deviennent définitivement illisibles.

### Réglages à vérifier

Éditez `/opt/signflow/.env`, puis `docker compose up -d` pour appliquer.

- **`SIGNFLOW_TZ`** — fuseau horaire. Il détermine l'interprétation des programmations
  et des heures d'ouverture : une valeur erronée décale toute la diffusion.
- **`MINIO_PUBLIC_ENDPOINT`** — adresse à laquelle les navigateurs et les players
  téléchargent les médias. Détectée automatiquement, à corriger si votre serveur a
  plusieurs interfaces réseau. Ne mettez jamais `localhost` : chaque poste
  s'interrogerait lui-même et aucun média ne s'afficherait.
- **`SMTP_*`** — nécessaire aux rapports planifiés et aux alertes par courriel.
- **`ANTHROPIC_API_KEY`** — active l'assistant IA et les résumés de flux. Facultative.

---

## Exploitation

```bash
cd /opt/signflow

docker compose ps                  # état des services
docker compose logs -f backend     # journaux
systemctl stop signflow            # arrêt
systemctl start signflow           # démarrage
```

### Mise à jour

```bash
cd /opt/signflow
docker compose pull
docker compose up -d
docker compose exec backend alembic upgrade head
```

Épinglez une version dans `.env` (`SIGNFLOW_VERSION=1.0.0`) plutôt que d'utiliser
`latest` : deux serveurs installés à un mois d'écart ne tourneraient pas le même code,
et un incident deviendrait irreproductible.

### Sauvegarde

Trois éléments à sauvegarder :

1. **`/opt/signflow/.env`** — clés de chiffrement, irremplaçables ;
2. **la base de données** — `docker compose exec -T postgres pg_dump -U signflow -Fc signflow > sauvegarde.dump` ;
3. **les médias** — volume Docker `signflow_minio_data`.

Les images n'ont pas besoin d'être sauvegardées : elles se retéléchargent.

---

## Chiffrement des échanges

L'installation par défaut fonctionne en **HTTP non chiffré**, ce qui convient à un
réseau local maîtrisé. Dès que le serveur est accessible depuis Internet, placez un
reverse-proxy TLS devant (Caddy, ou nginx avec Let's Encrypt) et passez `PUBLIC_WEB_URL`
en `https://`.

---

## Diagnostic

**L'interface ne répond pas** — `docker compose ps` : tous les services doivent être
`Up`. Sinon `docker compose logs <service> --tail 50`.

**Les médias ne s'affichent pas** — `MINIO_PUBLIC_ENDPOINT` pointe probablement une
adresse que les navigateurs et players ne peuvent pas joindre.

**Les players restent hors ligne** — vérifiez que leur `BACKEND_URL` correspond à
`http://<adresse-du-serveur>:8080` et que le port est ouvert sur le pare-feu.

**Les programmations se déclenchent à la mauvaise heure** — `SIGNFLOW_TZ`.

---

## Support

Contactez votre fournisseur SignFlow, en joignant la sortie de :

```bash
cd /opt/signflow && docker compose ps && docker compose logs --tail 100
```
