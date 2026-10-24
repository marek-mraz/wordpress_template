# wordpress_template

A production WordPress image plus everything needed to run it on Kubernetes:
a Helm chart, and a drop-in component for a
CIVITAS/CORE-style
`platform-deployment` repository (Keycloak, APISIX, shared MariaDB,
secrets generator, NetworkPolicies, Linkerd).

Fork it, add your theme, push: CI builds, tests and publishes the image.

## What you get

**Image** (`Dockerfile`), based on the official `wordpress:<ver>-php8.5-apache`,
pinned by digest:

- **Immutable docroot**: core, plugins, themes, mu-plugins, translations and
  `wp-config.php` are baked into `/var/www/html`, owned by root and read-only
  for PHP. Only `wp-content/uploads` is writable (the volume). WordPress cannot
  install or update code at runtime (`DISALLOW_FILE_MODS`, auto-updates off);
  a new version is a new image, so the image you scan is the code that runs.
- Configuration from env only (upstream `wp-config-docker.php`); the eight
  `WORDPRESS_*` salts are required, without them every request gets a 503.
- Runs as `www-data` (uid 33) on a read-only root filesystem with every
  capability dropped (`APACHE_PORT=8080`, writable `/tmp` and
  `wp-content/uploads`). Plain `docker run` (root master on port 80) still works.
- Plugins pinned in `composer.json`/`composer.lock` (wpackagist):
  OpenID Connect Generic, Redirection, Lightbox with PhotoSwipe. WordPress MCP
  Adapter from its release zip, checksummed. Page-cache plugins that write
  drop-ins into `wp-content` do not fit a read-only docroot.
- Translations: `--build-arg WP_LANGUAGES="sk_SK"` bakes the WordPress.org
  translations for core and the bundled plugins/themes into the image.
- mu-plugins in `wp-content/mu-plugins/`:
  - `oidc.php`: OIDC settings from `OIDC_*` env; Keycloak **client** roles
    (`admin`, `editor`, `author`, `contributor`, `subscriber`) map to WordPress
    roles; a user without one is refused. While OIDC is configured, password
    login and password reset are off (break-glass: `OIDC_BREAK_GLASS_IP`).
    Application passwords stay on for REST/MCP clients.
  - `oidc-pkce.php`: PKCE (S256) for the OIDC plugin.
  - `harden.php`: XML-RPC off, no user enumeration (REST, `?author=`,
    sitemap), no WordPress version in HTML, feeds or asset URLs, no file editor,
    no background auto-updates.
  - `meta-description.php`: `<meta name="description">` and Open Graph tags.
- Apache: no version banner, security headers, 403 on `readme.html`,
  `wp-config*`, `xmlrpc.php`, logs and any PHP inside `uploads/`; no
  `.htaccess` (rewrite rules in the server config); browser caching for static
  assets; prefork sized for one small site per pod.
- `wp-entrypoint.sh`: on every start runs `wp core update-db`, so the database
  schema follows the image.
- WP-CLI included; no compiler, composer, git or ghostscript in the image.

**CI** (`.github/workflows/`):

- `docker-build.yml`: builds, runs `tests/smoke.sh`, pushes
  `ghcr.io/<owner>/<repo>` with tags `<wp-version>-<run>`, `latest`, the branch
  and the short SHA.
- `security.yml`: daily Trivy scan (HIGH/CRITICAL with a fix) and a
  wpvulnerability.net check of core, plugins and themes (`tests/wpvuln.py`).
- Dependabot for composer, Docker base images and Actions, with a 7-day
  cooldown. Every Action is pinned by SHA.

**Kubernetes**: `component/wordpress/charts/wordpress` (Helm chart) and
`component/wordpress/` (platform component). See [DEPLOY.md](DEPLOY.md).

## Layout

```
Dockerfile, composer.json, composer.lock   image
config/                                    Apache, PHP, entrypoint
wp-content/mu-plugins/                     always-on code (OIDC, PKCE, hardening, meta)
wp-content/themes/, wp-content/plugins/    your own theme/plugins (copied into the image)
tests/smoke.sh                             image test: hardening, non-root, immutable docroot, OIDC e2e
tests/wpvuln.py                            WordPress vulnerability check
compose.yaml, .env.example                 local run
component/wordpress/                       platform component (+ Helm chart in charts/wordpress)
DEPLOY.md                                  build, publish and deploy
```

## Run locally

```sh
cp .env.example .env        # set DB_PASSWORD
docker compose up --build
```

Open http://localhost:8080 and run the installer. The container runs exactly
as on Kubernetes: uid 33, read-only root filesystem, no capabilities.

## Customize

- **Plugin from wordpress.org**: `composer require wpackagist-plugin/<slug>:<exact-version>`
  (commit `composer.lock`), or list it in the chart's `app.plugins` to install it
  at start.
- **Your theme**: put it in `wp-content/themes/<name>/` and set `app.theme: <name>`.
  Do not commit themes or fonts whose license forbids redistribution.
- **PHP/Apache knobs**: env vars (below), or the chart's `app.phpIni` /
  `app.apacheConf`, which load last.

| Variable | Default | |
|---|---|---|
| `APACHE_PORT` | `80` | the chart sets `8080` (non-root) |
| `APACHE_START_SERVERS` / `_MIN_SPARE_SERVERS` / `_MAX_SPARE_SERVERS` | `2` / `1` / `3` | prefork |
| `APACHE_MAX_REQUEST_WORKERS` | `10` | concurrent PHP requests |
| `APACHE_MAX_CONNECTIONS_PER_CHILD` | `1000` | recycles workers |
| `PHP_MEMORY_LIMIT` | `128M` | per request |
| `PHP_OPCACHE_MEMORY_CONSUMPTION` | `64` | MB |
| `PHP_OPCACHE_VALIDATE_TIMESTAMPS` | `0` | `1` while editing code in a running container |
| `OIDC_*` | unset | see `.env.example`; unset = normal WordPress login |

## Test

```sh
docker build -t wordpress-test .
IMAGE=wordpress-test bash tests/smoke.sh   # needs only docker
python3 tests/wpvuln.py                    # WordPress CVEs (stdlib only)
```

The smoke test boots MariaDB and Keycloak and checks headers, blocked files,
version leaks, non-root processes, the immutable docroot (nothing but uploads
writable, salts required, schema upgrade on start), and
the full OIDC flow: login, PKCE, role mapping, a user of another client being
refused, forged state, replayed code, logout.

## License

GPL-2.0-or-later, like WordPress. See [LICENSE](LICENSE).
