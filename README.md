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

At the end, the access URL, the **administrator password** and the **two-factor
enrolment key** are displayed. Write all three down — they are never shown again.

> ⚠️ **Two-factor authentication is mandatory on the administrator account.** Have
> an authenticator app ready (Google Authenticator, Aegis, Bitwarden, 1Password…)
> before you start: the password alone will not get you in.
>
> If you lose the key, retrieve it with:
> ```bash
> cd /opt/signflow && docker compose exec -T -e SHOW_TOTP_EMAIL=<your-admin-email> \
>   backend python3 /app/scripts/show_totp.py
> ```

> ⚠️ **The administrator address must use a real domain.** Reserved suffixes
> (`.local`, `.test`, `.invalid`, `.lan`…) are rejected by the API: the account
> would be created and then be impossible to log into, with the interface
> reporting invalid credentials while the address is the actual problem. The
> installer refuses them outright.

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

Pin a version in `.env` (`SIGNFLOW_VERSION=1.0.1`) rather than tracking `latest`:
two servers installed a month apart would otherwise run different code, and any
incident would become impossible to reproduce.

### Backups

Three things to back up:

1. **`/opt/signflow/.env`** — encryption keys, irreplaceable;
2. **the database** — `docker compose exec -T postgres pg_dump -U signflow -Fc signflow > backup.dump`;
3. **the media** — the directory named by `MEDIA_DATA_PATH` in `.env`
   (default `/var/lib/signflow/media`). It is a plain host directory, so a
   file-level backup of that path is enough.

Images need no backup: they can always be pulled again.

### Hardware video acceleration

Transcoding is the heaviest thing this server does, and the installer sets up GPU
encoding on its own when it can. It reports what it settled on at the end, and
again during the health checks.

| Hardware | What the installer does |
|---|---|
| **NVIDIA** (with a working driver) | Installs `nvidia-container-toolkit`, configures the Docker runtime, restarts Docker |
| **Intel / AMD** | Passes the DRM render node (`/dev/dri`) into the transcoding worker |
| **Neither** | Nothing — encoding runs on CPU (`libx264`). Everything works, just slower |

> ⚠️ **No GPU driver is ever installed.** Installing a proprietary driver on a
> server that is not ours can break the display stack and require a reboot to
> recover. NVIDIA acceleration is enabled **only if `nvidia-smi` already answers** —
> the card being present is not enough, the driver has to be loaded and healthy.

The GPU wiring lives in `/opt/signflow/docker-compose.override.yml`. **Delete that
file and restart to go back to CPU encoding** — useful if you suspect the GPU.

SignFlow does not blindly trust the hardware: it *tests* each encoder (NVENC,
QuickSync, VAAPI) before using it and falls back to CPU on its own. So a GPU that
turns out to be unusable degrades quietly instead of breaking transcoding — which
is also why the installer checks, and tells you, whether acceleration really came
up rather than assuming it did.

To check at any time:

```bash
cd /opt/signflow
docker compose exec celery-media python3 -c \
  "from app.core import encoders; print(encoders.detect_hw_encoders())"
```

An empty result means CPU encoding.

### Where the media are stored

The installer asks for this and writes it to `MEDIA_DATA_PATH`. It is worth
answering deliberately: **media are the only dataset that grows without bound**,
and left to itself Docker would put them under `/var/lib/docker` — on the system
disk, usually the smallest one in the machine.

- **Local disk** — the recommended answer. Mount your large disk, then give its
  path (for example `/mnt/storage/signflow-media`).
- **NAS** — fine as a **block device** (iSCSI mounted as ext4/xfs). Avoid NFS and
  especially SMB/CIFS: MinIO relies on POSIX semantics that file shares do not
  guarantee, and the failure mode is not a clean error at startup but stalls and
  possible corruption under load. The installer warns and asks for confirmation.
- **An existing S3 service** — if you already run object storage (some NAS
  provide an S3 endpoint), you can skip the bundled MinIO entirely: point
  `MINIO_ENDPOINT`, `MINIO_ACCESS_KEY` and `MINIO_SECRET_KEY` at it and remove
  the `minio` service from the compose file.

> ⚠️ **Choose before the first start.** Changing `MEDIA_DATA_PATH` later does not
> move anything: you must stop the stack, copy the directory across, then start
> again. The database keeps the object names, so a partial copy shows up as
> media that exist in the interface but fail to load on the screens.

---

## Serving over HTTPS

The default installation runs over **plain HTTP**, which is acceptable on a trusted
local network. As soon as the server is reachable from the internet, put a TLS
reverse proxy in front.

> ⚠️ **Media storage must move to HTTPS at the same time.** Once the interface is
> served over TLS, a page loaded over HTTPS cannot fetch media over plain HTTP —
> browsers block it as *mixed content*. Every image and video simply disappears,
> with no visible error other than a console warning. Proxying only the web
> interface is therefore not enough: MinIO needs its own TLS host.

### 1. Point a DNS name at the server

Create an `A` record for, say, `signage.example.com`. Ports **80** and **443** must
reach the machine — port 80 is required for certificate issuance and renewal.

### 2. Create `/opt/signflow/tls/Caddyfile`

Replace `signage.example.com` with your own name.

```caddyfile
{
    email admin@example.com
}

signage.example.com {
    encode zstd gzip
    header {
        Strict-Transport-Security "max-age=31536000"
        X-Content-Type-Options "nosniff"
        -Server
    }
    reverse_proxy 127.0.0.1:8080 {
        header_up X-Forwarded-Proto https
    }
}

# Media, downloaded directly by browsers and players through signed URLs.
signage.example.com:9443 {
    header {
        X-Content-Type-Options "nosniff"
        -Server
    }
    reverse_proxy 127.0.0.1:9000
}
```

### 3. Create `/opt/signflow/tls/docker-compose.yml`

```yaml
services:
  caddy:
    image: caddy:2
    container_name: signflow_caddy
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config

volumes:
  caddy_data:
  caddy_config:
```

`network_mode: host` lets Caddy reach nginx and MinIO on the loopback interface.
The `caddy_data` volume holds the certificates — keep it, or every restart would
request new ones and hit Let's Encrypt rate limits.

### 4. Update `/opt/signflow/.env`

```bash
PUBLIC_WEB_URL=https://signage.example.com
MINIO_PUBLIC_ENDPOINT=signage.example.com:9443
MINIO_PUBLIC_USE_SSL=true
CORS_ORIGINS=["https://signage.example.com"]
```

### 5. Start everything

```bash
cd /opt/signflow/tls && docker compose up -d
cd /opt/signflow && docker compose up -d
```

Certificates are issued within a minute. Check with
`docker logs signflow_caddy | grep -i certificate`.

### 6. Verify — do not skip this

Log in over HTTPS **and open a media item**. A padlock on the login page proves
nothing about the media path, which is exactly where this setup breaks.

### If port 443 is already taken

Caddy defaults to the TLS-ALPN challenge on port 443, which cannot work when that
port belongs to another service. Force HTTP-01 instead by adding to each site block:

```caddyfile
    tls {
        issuer acme {
            disable_tlsalpn_challenge
        }
    }
```

Port 80 then becomes the only validation path — it must stay reachable, including
for renewals every 60 days.

### Player configuration

Once TLS is in place, players must use the HTTPS address:
`BACKEND_URL = https://signage.example.com`

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
