# churchcrm-docker

Production Docker packaging for [ChurchCRM](https://github.com/churchcrm/crm) —
a church membership and management CRM.

> **This is unaffiliated third-party packaging.** ChurchCRM is built and
> maintained by the ChurchCRM contributors. This repository contains deployment
> configuration only and modifies no application code. See
> [`NOTICE`](NOTICE) for full attribution, and [`LICENSE`](LICENSE) for the
> upstream MIT license (`Copyright (c) 2023 ChurchCRM`).

## Why this exists

Upstream ships good Dockerfiles, but you cannot deploy from them as published:

1. **No images are published.** Upstream's `docker-release.yml` workflow
   triggers on `release: published` and has **zero runs**, so the tags in their
   `docker/DOCKER_RELEASE.md` (`latest-php8-apache`, `<version>-php8-apache`) do
   not exist. The only images in the `churchcrm/crm` Docker Hub repository are
   from **2018** and predate PHP 8.
2. **The example compose files do not work.** Upstream states it plainly:
   *"they are not working release-image recipes."* They mount an empty named
   volume over the document root, so the application never appears.

This repository builds from the **official, checksum-verified release artifact**
and supplies a stack verified end to end.

## Quick start

```bash
git clone https://github.com/Dvalin21/churchcrm-docker.git
cd churchcrm-docker

cp .env.example .env
$EDITOR .env          # set the two passwords and CRM_PUBLIC_URL

./build.sh            # build the image (~2 min)
docker compose up -d
```

That is the whole install. There is **no browser setup wizard** — see
[How configuration works](#how-configuration-works).

Then open your CRM URL and sign in:

| | |
|---|---|
| Username | `Admin` |
| Password | `changeme` |

**The application forces a password change on first login.** Do it immediately.

## How configuration works

The application image contains **no `Include/Config.php`** — upstream's release
builder rejects any archive containing one, so no image can ship it. Left alone,
that file is created by a browser wizard and lands in the container's writable
layer, which means **every image upgrade discards your database credentials**
while the database volume survives.

`render-config.sh` generates `Include/Config.php` from `.env` on every start
instead. Consequences:

- configuration survives image upgrades and container recreation;
- there is no wizard step;
- the schema and admin account are created automatically on first request.

If you would rather supply your own config, mount it over
`/var/www/html/Include/Config.php` and `render-config.sh` will leave it alone.

### `.env` values that matter

| Variable | Notes |
|---|---|
| `MYSQL_PASSWORD`, `MYSQL_ROOT_PASSWORD` | **Required.** Generate with `openssl rand -base64 24`. |
| `CRM_PUBLIC_URL` | **Required.** Must match your reverse proxy exactly, trailing `/` included. Validated as `^https?://\S+/$`. |
| `CRM_ROOT_PATH` | Empty for a root install; e.g. `/churchcrm` for a subdirectory. |
| `CRM_BIND_ADDR` | Defaults to `127.0.0.1`. Use `0.0.0.0` only if the proxy is not local. |
| `CRM_PORT` | Host port, defaults to `80`. |
| `CRM_TRUSTED_PROXY` | CIDR allowed to set `X-Forwarded-For`. Narrow it to your proxy's address. |

## Behind a reverse proxy

The stack is built for TLS termination in front of it.

- **Client IPs.** The application reads `$_SERVER['REMOTE_ADDR']` in four
  places, so without help every audit-log entry would show your proxy's IP.
  `remoteip.conf` loads `mod_remoteip` to rewrite it from `X-Forwarded-For`,
  restricted to `CRM_TRUSTED_PROXY` so a client cannot forge its own IP.
- **HTTPS.** The application already honours `X-Forwarded-Proto` itself for the
  `Secure` session cookie, so nothing extra is needed — but your proxy must set
  that header.
- The app binds to `127.0.0.1:80` by default. If your proxy runs in a container,
  either share the network or set `CRM_BIND_ADDR=0.0.0.0` and firewall it.

## What is persisted

| Volume | Contents |
|---|---|
| `db-data` | All CRM data. **This is the only thing that truly matters.** |
| `images-data` | Member photo and family image uploads. |
| `app-logs` | Application logs. |

The document root is deliberately **not** a volume. Upstream warns that a reused
volume strands stale application code across upgrades.

## Upgrades

```bash
# edit VERSION and SHA256 at the top of build.sh, then:
./build.sh
docker compose up -d
```

`Config.php` is regenerated from `.env`, the database volume is untouched, and
the application runs its own schema migrations. **Back up the database first.**

## Backups

```bash
docker compose exec -T db mariadb-dump -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" \
  "$MYSQL_DATABASE" | gzip > backup-$(date +%F).sql.gz
```

Restore:

```bash
gunzip -c backup-2026-01-01.sql.gz | docker compose exec -T db \
  mariadb -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE"
```

Also back up the `.env`. It holds your database credentials, and without it a
new container cannot rebuild `Config.php`.

## Verification

```bash
./test/smoke.sh
```

Brings the stack up from a clean state and checks the build, configuration
generation and escaping, persistence across restart and recreation, upload
permissions, healthchecks, reverse-proxy header handling, backup and restore,
the empty-password guard, and non-root execution — while scanning container
logs for PHP fatals, warnings and Apache errors.

## Requirements

Docker with Compose v2, `git`, `curl`, `python3`. Roughly 2 GB of disk for the
image and 2 GB RAM for MariaDB plus PHP.

## Credits

ChurchCRM and every part of it belong to the
[ChurchCRM contributors](https://github.com/churchcrm/crm/graphs/contributors).
This repository reuses their `Dockerfile.churchcrm-apache-php8`,
`prepare-release-context.py` and `apache/default.conf` unmodified, and builds the
application from their published release artifacts.

The Docker packaging in the upstream repository — the production Dockerfiles,
the release publish workflow, the checksum verification, the security review in
`docker/DOCKER_RELEASE.md` — was written by the ChurchCRM maintainers. This
project builds on that work rather than replacing it.

Base images: [`php:8.4.25-apache-trixie`](https://hub.docker.com/_/php) (PHP
License 3.01) and [`mariadb`](https://hub.docker.com/_/mariadb) (LGPL-2.1).

## License

MIT, matching upstream. `Copyright (c) 2023 ChurchCRM`.