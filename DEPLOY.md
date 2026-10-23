# Build, publish and deploy

Three ways to run the image in production, from least to most integrated:

1. [Publish the image](#1-publish-the-image) (needed for all of them)
2. [Plain Helm](#2-plain-helm): any Kubernetes cluster, bundled MariaDB
3. [Platform component](#3-platform-component): a CIVITAS/CORE-style
   `platform-deployment` repo with Keycloak, APISIX, shared MariaDB and the
   secrets generator

## 1. Publish the image

Push this repository to GitHub. On every push to `main`, `docker-build.yml`
builds the image, runs `tests/smoke.sh` and pushes it to
`ghcr.io/<owner>/<repo>`. Tags: `<wordpress-version>-<run-number>` (e.g.
`7.1.3-12`), `latest`, the branch name and the short commit SHA.

- The package is private at first. Make it public in GitHub (Packages →
  package settings), or give the cluster a pull secret.
- Deploy by **digest**, never by a moving tag:

  ```sh
  docker buildx imagetools inspect ghcr.io/<owner>/<repo>:7.1.3-12 --format '{{json .Manifest.Digest}}'
  # tag value for Helm: "7.1.3-12@sha256:<digest>"
  ```

- `security.yml` scans every day. A red run means a fixable HIGH/CRITICAL
  vulnerability: let Dependabot bump the base image or plugin, or rebuild.

## 2. Plain Helm

Requirements: Kubernetes ≥ 1.29 (the volumes use `ReadWriteOncePod`), a
default StorageClass, an ingress controller. cert-manager is optional.

The chart creates no Secrets. Create one with generated passwords first. It
must be named `<release>-wordpress-credentials` (or `<release>-credentials`
when the release name contains "wordpress"):

```sh
NS=mysite RELEASE=mysite
kubectl create namespace $NS
kubectl -n $NS create secret generic $RELEASE-wordpress-credentials \
  --from-literal=mariadb-root-password="$(openssl rand -hex 24)" \
  --from-literal=mariadb-password="$(openssl rand -hex 24)" \
  --from-literal=wordpress-password="$(openssl rand -hex 16)"
  # with OIDC also: --from-literal=oauth-client-secret='<client secret from Keycloak>'
```

`values-mysite.yaml`:

```yaml
app:
  image:
    repository: ghcr.io/<owner>/<repo>
    tag: "7.1.3-12@sha256:<digest>"
wordpress:
  siteTitle: "My Site"
  adminEmail: you@example.com
  language: en_US
ingress:
  className: nginx                 # or traefik, ...
  host: www.example.com
  tlsSecretName: www-example-com-tls
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
networkPolicy:
  ingressNamespace: ingress-nginx  # namespace of your ingress controller
```

```sh
helm upgrade --install $RELEASE component/wordpress/charts/wordpress -n $NS -f values-mysite.yaml
kubectl -n $NS rollout status deploy/$RELEASE-wordpress-web --timeout=10m
helm test $RELEASE -n $NS
```

On first start the pod installs WordPress (`wp core install`), then on every
start enforces title, URLs, language, timezone, permalinks, theme and plugins
from the values. Log in at `/wp-admin` as `admin` with `wordpress-password`
from the secret.

**OIDC login (Keycloak)**: create a confidential client with the standard flow,
redirect URI `https://www.example.com/*`, client roles `admin`, `editor`,
`author`, `contributor`, `subscriber`, and a "User Client Role" mapper that
puts this client's roles into the ID token and userinfo
(`resource_access.${client_id}.roles`). `component/wordpress/keycloak-clients.yaml`
shows the exact client. Enable PKCE (S256) on the client. Then:

```yaml
oauth:
  enabled: true
  clientId: mysite
  issuer: https://auth.example.com/realms/myrealm
  endpointLogin: https://auth.example.com/realms/myrealm/protocol/openid-connect/auth
  endpointLogout: https://auth.example.com/realms/myrealm/protocol/openid-connect/logout
  endpointToken: https://auth.example.com/realms/myrealm/protocol/openid-connect/token
  endpointUserInfo: https://auth.example.com/realms/myrealm/protocol/openid-connect/userinfo
  jwksUri: https://auth.example.com/realms/myrealm/protocol/openid-connect/certs
```

With OIDC on, password login is off. Users log in through Keycloak and get the
WordPress role of their highest client role.

**External database**: `database.enabled: false` plus `database.host`,
`database.user`, `database.name`; `mariadb-password` in the secret is that
user's password.

**Backups**: the chart only annotates the volumes for Velero file-system
backup, and MariaDB dumps itself into its volume before each Velero backup
(`backup.enabled: true` adds a daily Schedule for the release). Without
Velero, back up the two PVCs (`/var/www/html`, `/var/lib/mysql`) yourself.

## 3. Platform component

For a `platform-deployment` repo where `global.instances` describes the sites
(one namespace per instance, Keycloak realms in `global.realms`). The
component adds, per WordPress instance:

| File | Creates |
|---|---|
| `helmfile.yaml.gotmpl` | release `wordpress-<id>` in namespace `<instanceSlug>-<id>`, OIDC wired to the realm |
| `secrets.yaml` | `wordpress-<id>-credentials` (generated passwords) |
| `keycloak-clients.yaml` | Keycloak client `<id>` with role tiers, PKCE-ready, own-roles mapper |
| `mariadb.yaml` | database + least-privilege user on the shared MariaDB server |
| `apisix-routes.yaml` | `domains[0]` serves the site, every other domain 301s to it; login, xmlrpc and MCP routes |
| `apisix-plugins.yaml` | security headers + HSTS, 64 MB body cap, login rate limit, xmlrpc 403, MCP IP allowlist |
| `networkpolicies*.yaml` | ingress from APISIX only; egress to DNS, Linkerd, MariaDB, Keycloak, the internet (no private ranges) |

### Install

1. Copy the component into the platform repo:

   ```sh
   cp -r component/wordpress <platform-deployment>/components/
   ```

2. Make sure `wordpress` is in the `components:` list
   (`defaults/environment/global.yaml`), together with `secrets`,
   `networkpolicies`, `mariadb`, `keycloak` and `apisix`.

3. Pin your image in `components/wordpress/values/production-values.yaml.gotmpl`
   (`app.image.repository`, `app.image.tag: "<tag>@sha256:<digest>"`).

4. Add the site to `deployment/environments/<env>/global.yaml.gotmpl`:

   ```yaml
   global:
     realms:
       - name: myrealm
         domain: auth.example.com
     instances:
       mysite:
         component: wordpress
         realm: myrealm
         domains:
           - www.example.com      # canonical URL
           - example.com          # 301 -> www.example.com
         # Optional: MCP endpoint (/wp-json/mcp/*) is 403 unless the caller is listed.
         # mcpAllowlist: ["203.0.113.7/32"]
         values:
           wordpress:
             siteTitle: "My Site"
             language: en_US
           # app:
           #   theme: mytheme
           #   plugins: "redirection lightbox-photoswipe mcp-adapter"
   ```

5. Check offline, from the platform repo root:

   ```sh
   helmfile -f deployment/helmfile.yaml template -e production --selector component=wordpress --skip-deps -q
   python3 <skills>/civitas-component-builder/scripts/validate_components.py --repo .
   helmfile -f deployment/helmfile.yaml diff -e production --selector component=wordpress
   ```

6. Deploy in dependency order, one component at a time, reading each `diff`
   first:

   ```sh
   for c in secrets keycloak mariadb networkpolicies apisix wordpress; do
     helmfile -f deployment/helmfile.yaml diff -e production --selector component=$c
     helmfile -f deployment/helmfile.yaml sync -e production --selector component=$c
   done
   ```

   `secrets` generates the passwords and the Keycloak client secret,
   `keycloak` imports the client, `mariadb` creates the database and user,
   `apisix` adds routes and TLS for the domains. Point DNS at the cluster
   before `apisix`: Let's Encrypt HTTP-01 needs it.

7. Give users access in Keycloak: assign one client role of client `mysite`
   (`admin`, `editor`, ...). Then check the site over real TLS
   (`curl -sI https://www.example.com/`, no `-k`) and log in.

### MCP (AI agents editing the site)

1. Add `mcp-adapter` to `app.plugins` and the caller's IP to `mcpAllowlist`.
2. Create an application password: `wp user application-password create <user> mcp --porcelain`.
3. Endpoint: `POST https://<site>/wp-json/mcp/mcp-adapter-default-server` with HTTP Basic auth (`<user>:<application password>`).

### Upgrades

Bump the base image (Dependabot opens the PR), merge, pin the new digest and
`sync` the `wordpress` component. On start the pod upgrades core in the
volume and runs `wp core update-db`; it never downgrades.

### Operating notes

- Single replica + `Recreate`: a rollout means a few seconds of 503. Scaling
  out needs a ReadWriteMany volume.
- Readiness probes use `/index.php?rest_route=/`, not `/wp-login.php`: with
  OIDC auto-login every `wp-login.php` hit writes a state row.
- A slow page that trips the APISIX route timeout (30 s) is usually app-level,
  e.g. a gallery of missing images. Render it inside the pod to tell app time
  from network time.
