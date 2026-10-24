# wordpress (Helm chart)

Deploys the image from this repository: WordPress as `www-data` on port 8080
with a read-only root filesystem and an immutable docroot (code is in the
image), a PVC for `wp-content/uploads` only, and either a
bundled MariaDB StatefulSet or an external database. Optional OIDC login,
standard `Ingress`, NetworkPolicies, Velero backup annotations, `helm test`.

The chart renders **no Secrets**. It reads `<fullname>-credentials` with keys
`mariadb-root-password` (bundled DB only), `mariadb-password`,
`wordpress-password`, the eight salts (`auth-key`, `secure-auth-key`,
`logged-in-key`, `nonce-key`, `auth-salt`, `secure-auth-salt`,
`logged-in-salt`, `nonce-salt`) and, with OIDC, `oauth-client-secret` (or
`oauth.existingSecret` / `oauth.existingSecretKey`).

`app.image.tag` is required; pin a digest.

Every start a `postStart` script (WP-CLI) installs WordPress if needed and then
enforces the `wordpress.*` values, the theme and plugins. Its log is the
container log (`[setup-wp]` lines).

See [DEPLOY.md](../../../../DEPLOY.md) for installation and all values in
[values.yaml](values.yaml).
