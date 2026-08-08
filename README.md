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

You will need the **handoff sheet** supplied with your licence. It carries three
things the installer asks for, and none of them can be guessed:

| On the sheet | The installer asks for it as |
|---|---|
| **Licence ID** (also the `licence_id` field of your `licence.json`) | the registry login |
| **Mot de passe** | the registry password |
| **Clé publique de l'éditeur** | the publisher public key — paste it exactly as printed, literal `\n` included |

> ⚠️ Without the public key the server cannot verify your licence: it will start
> and run, but it behaves as **unlicensed**, and nothing in the interface says the
> licence you installed is being ignored.

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

Every question the installer asks can be answered up front with an environment
variable. Anything left unset takes its default, so a scripted install never
stops to wait for input:

```bash
sudo SIGNFLOW_REGISTRY_USER=SF-2026-ACME \
     SIGNFLOW_REGISTRY_PASSWORD=... \
     ORG_NAME="Acme Retail" \
     ADMIN_EMAIL=admin@acme.com \
     MEDIA_DATA_PATH=/mnt/storage/signflow-media \
     SIGNFLOW_HARDEN=y \
     bash install-ubuntu.sh
```

| Variable | Default | What it answers |
|---|---|---|
| `SIGNFLOW_REGISTRY_USER` | — **required** | Registry login (your licence id) |
| `SIGNFLOW_REGISTRY_PASSWORD` | — **required** | Registry password |
| `ORG_NAME` | `SignFlow` | Organisation shown in the interface and on reports |
| `ADMIN_EMAIL` | `admin@signflow.io` | Administrator account (a **real** domain) |
| `MEDIA_DATA_PATH` | `/var/lib/signflow/media` | Where media are stored |
| `LICENCE_PUBLIC_KEY` | *(none)* | Publisher public key, supplied with your licence |
| `LICENCE_FILE` | *(none)* | Path to your `licence.json` |
| `SIGNFLOW_HARDEN` | `y` | Firewall + key-only SSH + fail2ban |
| `SIGNFLOW_BACKUP_DIR` | *(none — skipped)* | Daily database backup target |
| `SIGNFLOW_BACKUP_RETENTION` | `14` | Days of backups to keep |

The two registry variables are the only ones with no usable default: without a
terminal to ask, the installer stops immediately and says so, rather than
failing later with an unrelated error.

> The administrator password and two-factor key are printed at the end as
> usual — capture the output, they are shown only once.

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
sudo systemctl stop signflow       # stop
sudo systemctl start signflow      # start
```

> **When do you need `sudo`?** `systemctl` always does. The `docker compose`
> commands do **not**, because the installer added the account that ran it to the
> `docker` group. Two cases still require care:
> - **Right after installation**, that group membership is not active in your
>   current session — log out and back in, or prefix docker commands with `sudo`
>   until you do.
> - **Any other account** on the machine must either be added to the `docker`
>   group (`sudo usermod -aG docker <user>`) or use `sudo`.
>
> ⚠️ Membership of the `docker` group grants root-equivalent access to the host.
> Grant it deliberately, not to every user on the machine.

### Updating

When a newer version is published, an **"update available" bell appears in the
top bar** for organisation admins. It shows which version to install, what
changed, whether the update is a security fix, and the exact command to run — so
you never have to watch for releases yourself. (A server built from source shows
no bell: there is no pinned version to compare.)

The server probes the release manifest every **15 minutes**, so the bell can lag
a new release by up to that long — including security releases. If you have been
told a version exists and the bell has not appeared yet, that is the reason;
`bash update.sh <version>` works immediately regardless of the bell.

```bash
cd /opt/signflow
bash update.sh <version>     # the version shown by the bell, e.g. 1.0.9
```

> Always pass the version the bell shows. Passing an **older** version downgrades
> the application against a database that has already been migrated forward, which
> is not a supported state.

The script pins the version, pulls the images, restarts, migrates the database,
**re-indexes the product documentation** and checks that everything came back up.

Two of those steps are easy to miss when updating by hand, and both fail
quietly:

- **Registry login.** The installer runs under `sudo`, so `docker login` stored
  the credentials for *root*. Running `docker compose pull` as your own user
  then fails with *"repository does not exist or may require authorization"* —
  a message that sends you looking for a missing image rather than a missing
  login. Fix it once, using **your own registry credentials** — the username is
  your licence id (e.g. `SF-2026-ACME`), supplied with your licence:
  ```bash
  docker login registry.dernoult.net:8443 -u <your-licence-id>
  ```
- **Documentation index.** The AI assistant answers from an indexed copy of the
  manual. Indexing happens at install time, so an installation created before a
  release that adds documentation would never catch up — with no error anywhere,
  just an assistant that does not know the feature you are asking about.

Always pin a version rather than tracking `latest`: two servers installed a
month apart would otherwise run different code, and any incident would become
impossible to reproduce.

### Backups

Three things to back up:

1. **`/opt/signflow/.env`** — encryption keys, irreplaceable;
2. **the database** — `docker compose exec -T postgres pg_dump -U signflow -Fc signflow > backup.dump`;
3. **the media** — the directory named by `MEDIA_DATA_PATH` in `.env`
   (default `/var/lib/signflow/media`). It is a plain host directory, so a
   file-level backup of that path is enough.

Images need no backup: they can always be pulled again.

### Large fleets — the nginx connection ceiling

A screen is not a visitor who comes and goes: it holds **one WebSocket open
permanently**, and a proxied WebSocket costs **two** connections — one to the
screen, one to the backend. Ubuntu ships nginx with `worker_connections 768`,
which caps the fleet at roughly **1500 screens** whatever the hardware (measured
on a 4-core bench: refusals started at 1600 while the machine was at 30% CPU;
tuned, the same machine held 1999 screens without a single refusal).

The installer applies the tuning, so a **new** installation needs nothing. On a
server installed before this version, the update applies it too — but only if it
can obtain root. An update run **without a terminal** (automation, cron) cannot
ask for your password, so it prints a warning and skips it. In that case, run it
once, by hand:

```bash
cd /opt/signflow
sudo bash tune-nginx.sh            # apply (idempotent — safe to re-run)
sudo bash tune-nginx.sh --status   # what nginx is configured for
sudo bash tune-nginx.sh --off      # restore the file as it was before us
```

> This is the one setting that lives in a file belonging to the distribution
> (`/etc/nginx/nginx.conf`) rather than to SignFlow, which is why it needs root
> and cannot ship as a drop-in: `worker_connections` sits in the `events` block,
> and `conf.d/` is included inside `http`. The original file is backed up, the
> result is checked with `nginx -t`, and any change is rolled back if that fails.

### Reconnection bursts — how many backend processes

When a site gets its power back, or after a server restart, every screen
reconnects at once. Until now the backend answered them **one at a time**: a
single Python process pins **one core** and cannot use the others. Measured on a
16-core server (2026-08-08): during a 400-screen burst that process sat at 101%
of one core while the machine as a whole was at **4%**. The server was not
short of power — it was using a sixteenth of it.

The backend now runs **one process per core, minus one, capped at 8**, worked out
at startup. Nothing to configure. On the two benches this divided the
reconnection delay by **2.5 to 3.8** (400 screens: 4.9 s → 1.9 s on a 4-core VM,
3.5 s → 0.9 s on a 16-core server), with no error.

To pin the value — a machine shared with other services, for instance — set it in
`.env` and recreate the container:

```bash
echo 'WEB_CONCURRENCY=2' >> /opt/signflow/.env   # 1 = previous behaviour
docker compose up -d backend                    # `restart` is NOT enough
```

> **The database pools are not multiplied by that number.** The connection budget
> (`CMS_DB_CONNECTION_BUDGET`, 60 by default) is *global* and is shared out
> between the processes, so adding processes never adds connections — PostgreSQL
> counts connections, not processes, and a database that refuses a connection does
> not degrade, it breaks. With a single process the pools are exactly what they
> have always been. If you raise `max_connections` on PostgreSQL, raise the budget
> here to match, keeping a reserve for the Celery services and for maintenance.

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

### Adding — or removing — a GPU later

Fitting a card months after the install is a supported path. Install your
vendor's driver first, until `nvidia-smi` answers, then:

```bash
cd /opt/signflow
sudo bash setup-gpu.sh            # detect, wire, restart, and verify
sudo bash setup-gpu.sh --status   # what the worker can really use
sudo bash setup-gpu.sh --off      # back to CPU encoding
```

> ⚠️ **This script never installs a GPU driver**, by design. Installing a
> proprietary driver on a server that is not ours can break the display stack and
> require a reboot to recover. If no driver answers, the script says so and
> changes nothing.

> ⚠️ Enabling NVIDIA support restarts the Docker daemon: running containers bounce
> for a few seconds. Screens are not affected — players keep playing their cached
> content and reconnect on their own.

The script ends by asking the worker, **inside its own container**, which encoders
it can really use — so it cannot report a success it did not achieve. Passing a
device through is not proof that it works.

The wiring itself lives in `/opt/signflow/docker-compose.override.yml`. `--off`
moves it aside rather than deleting it, and refuses to touch an override you wrote
yourself.

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

> If that command shows `rejectedIdentifier ... forbidden by policy`, the example
> domain is still in your Caddyfile — replace **both** occurrences.

### 6. Close MinIO's plain port — do not skip this either

Until now MinIO was published on port **9000 in plain HTTP**. Docker publishes it
through its own iptables rules, which **bypass ufw**: the firewall reports the port
as closed while the whole internet can reach it. Now that Caddy serves the media
over TLS on 9443, bind it back to the loopback:

```bash
# /opt/signflow/.env
MINIO_BIND=127.0.0.1
```

```bash
cd /opt/signflow && docker compose up -d --force-recreate minio
```

Caddy runs on the host network, so it still reaches MinIO on `127.0.0.1:9000`.

### 7. Verify — do not skip this

Log in over HTTPS **and open a media item**. A padlock on the login page proves
nothing about the media path, which is exactly where this setup breaks.

Then check the exposure from **outside** the machine — both halves matter, because
closing the port without checking the media reproduces the same trap in reverse:

```bash
curl -sI https://<your-domain>:9443/minio/health/live   # expected: 200
curl -sI --max-time 5 http://<your-domain>:9000/        # expected: connection refused
```

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
