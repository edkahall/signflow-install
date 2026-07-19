# SignFlow CMS — Installation

Digital signage platform: centralised content management, scheduling, and control
of a screen fleet (Linux, Raspberry Pi, Windows, Android, ChromeOS, BrightSign).

This repository contains **only what is needed to install** SignFlow. The application
ships as container images — nothing is compiled on your server.

---

## Requirements

| | Minimum | Recommended |
|---|---|---|
| Operating system | Ubuntu 22.04 | Ubuntu 24.04 |
| CPU | 4 cores | 8 cores or more |
| Memory | 8 GB | 16 GB |
| Disk | 100 GB | 500 GB or more (depending on media volume) |

Video transcoding is the most demanding task: size generously if you plan to serve
a lot of video, or 4K content.

Docker is installed automatically if missing.

You will need **image registry credentials**, supplied with your licence.

---

## Install

```bash
curl -fsSL https://github.com/edkahall/signflow-install/archive/refs/heads/main.tar.gz | tar xz
cd signflow-install-main
sudo bash install-ubuntu.sh
```

> This method only requires `curl` and `tar`, present on every Ubuntu installation.
> **`git` is not installed by default on Ubuntu Server**, so `git clone` would fail
> on a fresh machine before anything could be installed. If you already have git,
> cloning works just as well.

The script prompts for your registry credentials, then runs through: prerequisites,
secret generation, image download, startup, database migrations, health checks,
auto-start, network access, and administrator account creation.

Allow about ten minutes, most of it downloading (roughly 1 GB).

At the end, the access URL and the **administrator password** are displayed.
Write the password down — it is never shown again.

### Unattended install

```bash
sudo SIGNFLOW_REGISTRY_USER=... SIGNFLOW_REGISTRY_PASSWORD=... bash install-ubuntu.sh
```

---

## After installation

The interface is available at `http://<server-address>:8080`.

**Back up `/opt/signflow/.env`.** It holds the encryption keys for this installation —
in particular `CMS_VAULT_KEY`, without which any stored API keys become permanently
unreadable.

### Settings worth checking

Edit `/opt/signflow/.env`, then run `docker compose up -d` to apply.

- **`SIGNFLOW_TZ`** — time zone. It governs how schedules and opening hours are
  interpreted: a wrong value shifts your entire playout.
- **`MINIO_PUBLIC_ENDPOINT`** — the address browsers and players use to download
  media. Auto-detected; correct it if your server has several network interfaces.
  Never use `localhost`: every machine would query itself and no media would load.
- **`SMTP_*`** — required for scheduled reports and email alerts.
- **`ANTHROPIC_API_KEY`** — enables the AI assistant and feed summaries. Optional.

---

## Operations

```bash
cd /opt/signflow

docker compose ps                  # service status
docker compose logs -f backend     # logs
systemctl stop signflow            # stop
systemctl start signflow           # start
```

### Updating

```bash
cd /opt/signflow
docker compose pull
docker compose up -d
docker compose exec backend alembic upgrade head
```

Pin a version in `.env` (`SIGNFLOW_VERSION=1.0.0`) rather than tracking `latest`:
two servers installed a month apart would otherwise run different code, and any
incident would become impossible to reproduce.

### Backups

Three things to back up:

1. **`/opt/signflow/.env`** — encryption keys, irreplaceable;
2. **the database** — `docker compose exec -T postgres pg_dump -U signflow -Fc signflow > backup.dump`;
3. **the media** — Docker volume `signflow_minio_data`.

Images need no backup: they can always be pulled again.

---

## Transport encryption

The default installation runs over **plain HTTP**, which is acceptable on a trusted
local network. As soon as the server is reachable from the internet, put a TLS
reverse proxy in front (Caddy, or nginx with Let's Encrypt) and switch
`PUBLIC_WEB_URL` to `https://`.

---

## Troubleshooting

**The interface does not respond** — run `docker compose ps`: every service should
be `Up`. Otherwise `docker compose logs <service> --tail 50`.

**Media does not display** — `MINIO_PUBLIC_ENDPOINT` most likely points to an address
that browsers and players cannot reach.

**Players stay offline** — check that their `BACKEND_URL` matches
`http://<server-address>:8080` and that the port is open on the firewall.

**Schedules fire at the wrong time** — check `SIGNFLOW_TZ`.

---

## Support

Contact your SignFlow provider, including the output of:

```bash
cd /opt/signflow && docker compose ps && docker compose logs --tail 100
```
