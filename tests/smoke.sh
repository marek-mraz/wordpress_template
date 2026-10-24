#!/usr/bin/env bash
# Smoke test for the built WordPress image.
# Usage: IMAGE=<tag> tests/smoke.sh
#
# Boots the image the way the platform's securityDefaults would run it
# (uid 33, read-only root fs, tmpfs /tmp, no capabilities, port 8080) against
# MariaDB and a Keycloak with the platform's client layout, then checks:
# hardening headers / blocked files / no version leaks, non-root processes,
# an immutable docroot (only uploads writable, salts required, DB schema
# upgraded on start), and the OIDC flow end to end (login
# redirect, code exchange, user creation + client-role mapping, cross-client
# role rejection, forged/replayed state, logout). A second container checks
# classic mode (root master, port 80, www-data workers).
# Needs only docker (no bind mounts, works against a remote daemon).
set -euo pipefail
IMAGE="${IMAGE:?set IMAGE to the image tag to test}"
DB_IMAGE=mariadb:11.8@sha256:f16d7a344413e519dff518f27bdb221388f84b0d274c97c4fb5f2cb0dc1b34fa
KC_IMAGE=quay.io/keycloak/keycloak:26.6.4@sha256:0aae0de7fca85525f727d3354df17896092de8bb26ae4c12d89c77e5df8cbce4

P=wp-smoke; NET=$P-net; DB=$P-db; KC=$P-kc; WP=$P-wp; WP80=$P-wp80; WPN=$P-nosalt
SALTS=()
for k in AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT; do
    SALTS+=(-e "WORDPRESS_$k=$(openssl rand -hex 32)")
done
WPURL=http://wpsite:8080
KC_INT=http://keycloak:8080      # back channel (token/userinfo/jwks), like the in-cluster service
KC_PUB=http://kc-public:8080     # browser-facing hostname = issuer, like idm.<domain>

cleanup() {
    docker rm -fv "$WPN" "$WP" "$WP80" "$P-wpfresh" "$KC" "$DB" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
}
[ -n "${KEEP:-}" ] || trap cleanup EXIT   # KEEP=1 leaves the containers for debugging
cleanup

fail() { echo "FAIL: $*" >&2; docker logs --tail 40 "$WP" 2>&1 | grep -v '" 200 \|" 302 ' >&2 || true; exit 1; }
ok() { echo "ok: $*"; }
in_wp() { docker exec -i "$WP" bash -c "$1"; }
wpcli() { docker exec "$WP" wp --path=/usr/src/wordpress "$@" 2> >(grep -v oidc-mu-plugin >&2); }

echo "==> tooling: php + wp-cli present, no build tools"
docker run --rm --entrypoint bash "$IMAGE" -ec '
    php -v | head -1
    wp --version --allow-root
    for b in composer gcc make git pecl phpize gs; do
        ! command -v "$b" >/dev/null || { echo "build/attack-surface tool present: $b"; exit 1; }
    done'

echo "==> custom PHP lints"
docker run --rm --entrypoint bash "$IMAGE" -ec \
    'for f in /usr/src/wordpress/wp-content/mu-plugins/*.php /usr/src/wordpress/wp-config*.php; do php -l "$f"; done'

echo "==> docroot baked into the image, owned by root; only uploads owned by www-data"
docker run --rm --entrypoint bash "$IMAGE" -ec '
    cd /usr/src/wordpress
    for d in plugins/daggerhart-openid-connect-generic plugins/mcp-adapter plugins/redirection \
             plugins/lightbox-photoswipe themes/twentytwentyfive; do test -d "wp-content/$d"; done
    for f in harden oidc oidc-pkce meta-description; do test -f "wp-content/mu-plugins/$f.php"; done
    test ! -e wp-content/plugins/akismet && test ! -e wp-content/plugins/hello.php && test ! -e /var/www/html/index.php && test ! -e /var/www/html/wp-includes
    grep -q "wp-config-image.php" wp-config.php
    [ -z "$(find . -path ./wp-content/uploads -prune -o ! -user root -print -o -perm /022 -print | head -1)" ] \
        || { echo "not root-owned or group/other-writable: $(find . -path ./wp-content/uploads -prune -o ! -user root -print -o -perm /022 -print | head -3)"; exit 1; }
    [ "$(stat -c %U wp-content/uploads)" = www-data ]'

echo "==> start MariaDB + Keycloak"
docker network create "$NET" >/dev/null
docker run -d --name "$DB" --network "$NET" \
    -e MARIADB_DATABASE=wp -e MARIADB_USER=wp -e MARIADB_PASSWORD=wp \
    -e MARIADB_ROOT_PASSWORD=root "$DB_IMAGE" >/dev/null
docker run -d --name "$KC" --network "$NET" --network-alias keycloak --network-alias kc-public \
    -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD=admin \
    -e KC_HOSTNAME="$KC_PUB" -e KC_HOSTNAME_BACKCHANNEL_DYNAMIC=true \
    "$KC_IMAGE" start-dev >/dev/null
until docker exec "$DB" healthcheck.sh --connect --innodb_initialized >/dev/null 2>&1; do sleep 1; done

echo "==> boot hardened: uid 33, read-only rootfs, cap-drop ALL, :8080"
docker run -d --name "$WP" --network "$NET" --network-alias wpsite \
    --user 33:33 --read-only --tmpfs /tmp:rw,exec,mode=1777 --tmpfs /usr/src/wordpress/wp-content/uploads:rw,uid=33,gid=33,mode=0755 --cap-drop ALL --security-opt no-new-privileges \
    -e APACHE_PORT=8080 "${SALTS[@]}" \
    -e WORDPRESS_DB_HOST="$DB" -e WORDPRESS_DB_USER=wp -e WORDPRESS_DB_PASSWORD=wp -e WORDPRESS_DB_NAME=wp \
    -e OIDC_CLIENT_ID=wp -e OIDC_CLIENT_SECRET=smoke-secret -e OIDC_SCOPE="openid email profile" \
    -e OIDC_ENDPOINT_LOGIN="$KC_PUB/realms/smoke/protocol/openid-connect/auth" \
    -e OIDC_ENDPOINT_LOGOUT="$KC_PUB/realms/smoke/protocol/openid-connect/logout" \
    -e OIDC_ENDPOINT_TOKEN="$KC_INT/realms/smoke/protocol/openid-connect/token" \
    -e OIDC_ENDPOINT_USERINFO="$KC_INT/realms/smoke/protocol/openid-connect/userinfo" \
    -e OIDC_JWKS_URI="$KC_INT/realms/smoke/protocol/openid-connect/certs" \
    -e OIDC_ISSUER="$KC_PUB/realms/smoke" \
    -e OIDC_IDENTITY_KEY=preferred_username -e OIDC_NICKNAME_KEY=preferred_username \
    -e OIDC_EMAIL_FORMAT="{email}" -e OIDC_DISPLAYNAME_FORMAT="{given_name} {family_name}" \
    -e OIDC_LINK_EXISTING_USERS=true -e OIDC_CREATE_IF_NOT_EXISTS=true -e OIDC_REDIRECT_BACK=true \
    "$IMAGE" >/dev/null
code=000
for _ in $(seq 1 60); do
    code=$(in_wp "curl -s -o /dev/null -w '%{http_code}' $WPURL/wp-admin/install.php" || echo 000)
    [ "$code" = 200 ] && break
    sleep 2
done
[ "$code" = 200 ] || fail "install.php returned $code"
ok "installer served by apache+php against MariaDB"
wpcli core install --url="$WPURL" --title=Smoke --admin_user=admin --admin_password="$(openssl rand -hex 12)" \
    --admin_email=admin@example.com --skip-email >/dev/null
wpcli plugin activate daggerhart-openid-connect-generic >/dev/null

echo "==> non-root"
users=$(in_wp 'ps -eo user= | sort -u | tr "\n" " "')
[ "$users" = "www-data " ] || fail "processes not all www-data: $users"
in_wp 'printf "#!/bin/sh\necho setup-ok\n" > /usr/local/bin/setup-wp.sh && chmod +x /usr/local/bin/setup-wp.sh && /usr/local/bin/setup-wp.sh' \
    | grep -q setup-ok || fail "chart postStart path (/usr/local/bin/setup-wp.sh) not writable"
ok "all processes www-data on a read-only rootfs; chart postStart script path writable"

echo "==> headers, blocked files, version leaks"
hdr=$(in_wp "curl -s -D - -o /dev/null $WPURL/")
for h in 'X-Content-Type-Options: nosniff' 'X-Frame-Options: SAMEORIGIN' 'Referrer-Policy: strict-origin-when-cross-origin' 'Permissions-Policy:' 'Server: Apache'; do
    grep -qi "^$h" <<<"$hdr" || fail "missing header: $h"
done
! grep -qiE '^X-Powered-By|^Server: Apache/' <<<"$hdr" || fail "version leak in headers: $hdr"
for f in readme.html license.txt xmlrpc.php wp-config.php wp-config-image.php wp-config-docker.php wp-config-sample.php .htaccess; do
    c=$(in_wp "curl -s -o /dev/null -w '%{http_code}' $WPURL/$f")
    [ "$c" = 403 ] || fail "/$f returned $c, expected 403"
done
in_wp 'mkdir -p /usr/src/wordpress/wp-content/uploads && echo "<?php echo 1;" > /usr/src/wordpress/wp-content/uploads/x.php'
c=$(in_wp "curl -s -o /dev/null -w '%{http_code}' $WPURL/wp-content/uploads/x.php")
[ "$c" = 403 ] || fail "PHP in uploads returned $c, expected 403"
ver=$(docker exec "$WP" php -r 'include "/usr/src/wordpress/wp-includes/version.php"; echo $wp_version;')
body=$(in_wp "curl -s $WPURL/; curl -s $WPURL/feed/")
! grep -qE "ver=$ver|name=\"generator\"|<generator>|WordPress $ver" <<<"$body" || fail "WordPress version $ver leaks in HTML/feed"
ok "security headers, 403 on sensitive files + uploads PHP, no version in headers/HTML/feed"

echo "==> immutable docroot: code and config read-only, uploads writable, schema upgraded on start"
for f in index.php wp-config.php wp-includes/version.php .htaccess wp-content/x.php \
         wp-content/plugins/x.php wp-content/themes/x.php wp-content/mu-plugins/x.php wp-content/languages/x.php; do
    ! in_wp "touch /usr/src/wordpress/$f" 2>/dev/null || fail "www-data can write /usr/src/wordpress/$f"
done
in_wp 'touch /usr/src/wordpress/wp-content/uploads/ok && rm /usr/src/wordpress/wp-content/uploads/ok' || fail "uploads not writable"
[ "$(wpcli eval 'echo (int) wp_is_file_mod_allowed("smoke"), (int) DISALLOW_FILE_EDIT, (int) AUTOMATIC_UPDATER_DISABLED;')" = 011 ] \
    || fail "file mods / file editor / auto-updates not disabled"
restart() {
    docker restart "$WP" >/dev/null
    for _ in $(seq 1 30); do in_wp "curl -sf -o /dev/null $WPURL/wp-login.php?action=postpass" 2>/dev/null && return; sleep 1; done
    fail "no response after restart"
}
want=$(wpcli option get db_version)
wpcli option update db_version 1 >/dev/null; restart
[ "$(wpcli option get db_version)" = "$want" ] || fail "database schema not upgraded on start"
ok "nothing outside uploads writable, file mods + auto-updates off, update-db on start"

echo "==> no salts: refuses to run"
docker run -d --name "$WPN" --network "$NET" --user 33:33 --read-only --tmpfs /tmp:rw,exec,mode=1777 --cap-drop ALL \
    -e APACHE_PORT=8080 -e WORDPRESS_DB_HOST="$DB" -e WORDPRESS_DB_USER=wp -e WORDPRESS_DB_PASSWORD=wp -e WORDPRESS_DB_NAME=wp \
    "$IMAGE" >/dev/null
c=000
for _ in $(seq 1 30); do
    c=$(docker exec "$WPN" curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/ 2>/dev/null) || c=000
    [ "$c" != 000 ] && break
    sleep 1
done
[ "$c" = 503 ] || fail "without salts / returned $c, expected 503"
docker logs "$WPN" 2>&1 | grep "WORDPRESS_AUTH_KEY is missing" >/dev/null || fail "no log line for the missing salts"
docker rm -f "$WPN" >/dev/null
ok "503 and a log line without salts"

echo "==> Keycloak realm, client (platform layout), users"
for _ in $(seq 1 90); do in_wp "curl -sf -o /dev/null $KC_INT/realms/master" && break; sleep 2; done
in_wp "KC=$KC_INT WPURL=$WPURL bash -s" <<'EOF' || fail "keycloak setup"
set -euo pipefail
j() { php -r '$d=json_decode(stream_get_contents(STDIN),true); foreach(explode(".",$argv[1]) as $k) $d=$d[$k]; echo is_array($d)?json_encode($d):$d;' "$1"; }
tok=$(curl -sf -d grant_type=password -d client_id=admin-cli -d username=admin -d password=admin \
    "$KC/realms/master/protocol/openid-connect/token" | j access_token)
api() { curl -sf -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' "$@"; }
A=$KC/admin/realms
api -d '{"realm":"smoke","enabled":true}' "$A"
# mirrors platform-deployment components/wordpress/keycloak-clients.yaml
api -d '{"clientId":"wp","enabled":true,"publicClient":false,"secret":"smoke-secret","standardFlowEnabled":true,
  "directAccessGrantsEnabled":false,"redirectUris":["'"$WPURL"'/*"],"attributes":{"post.logout.redirect.uris":"+","pkce.code.challenge.method":"S256"},
  "protocolMappers":[{"name":"own-client-roles-in-id-token","protocol":"openid-connect",
  "protocolMapper":"oidc-usermodel-client-role-mapper","config":{"usermodel.clientRoleMapping.clientId":"wp",
  "claim.name":"resource_access.${client_id}.roles","jsonType.label":"String","multivalued":"true",
  "id.token.claim":"true","access.token.claim":"true","userinfo.token.claim":"true"}}]}' "$A/smoke/clients"
api -d '{"clientId":"otherapp","enabled":true,"publicClient":false,"secret":"x","redirectUris":["http://otherapp/*"]}' "$A/smoke/clients"
cid=$(api "$A/smoke/clients?clientId=wp" | j 0.id)
oid=$(api "$A/smoke/clients?clientId=otherapp" | j 0.id)
for r in admin editor subscriber; do api -d "{\"name\":\"$r\"}" "$A/smoke/clients/$cid/roles"; done
api -d '{"name":"admin"}' "$A/smoke/clients/$oid/roles"
# alice=wp.admin  bob=wp.editor  carol=otherapp.admin only (must be refused)
for u in alice:wp:admin bob:wp:editor carol:otherapp:admin; do
    IFS=: read -r name client role <<<"$u"
    api -d '{"username":"'"$name"'","enabled":true,"email":"'"$name"'@example.com","emailVerified":true,
      "firstName":"'"$name"'","lastName":"Smoke","credentials":[{"type":"password","value":"pw-'"$name"'","temporary":false}]}' "$A/smoke/users"
    uid=$(api "$A/smoke/users?username=$name&exact=true" | j 0.id)
    c=$([ "$client" = wp ] && echo "$cid" || echo "$oid")
    rr=$(api "$A/smoke/clients/$c/roles/$role")
    api -d "[$rr]" "$A/smoke/users/$uid/role-mappings/clients/$c"
done
EOF
ok "realm smoke: client wp (+client-role mapper), otherapp, users alice/bob/carol"

echo "==> OIDC end to end"
in_wp "WPURL=$WPURL KC_PUB=$KC_PUB bash -s" <<'EOF' || fail "OIDC flow"
set -euo pipefail
die() { echo "  $*" >&2; exit 1; }
# login <user> -> sets globals: J (cookie jar), CB (callback URL), RES ("code location")
login() {
    J=/tmp/jar-$1; rm -f "$J"
    local auth page action
    auth=$(curl -s -o /dev/null -w '%{redirect_url}' -c "$J" -b "$J" "$WPURL/wp-login.php")
    [[ "$auth" == "$KC_PUB/realms/smoke/protocol/openid-connect/auth?"*client_id=wp* ]] || die "wp-login did not redirect to Keycloak: $auth"
    [[ "$auth" == *code_challenge_method=S256* ]] || die "no PKCE challenge in the auth URL: $auth"
    page=$(curl -s -c "$J" -b "$J" "$auth")
    action=$(grep -o 'id="kc-form-login"[^>]*action="[^"]*"' <<<"$page" | sed 's/.*action="//;s/"$//;s/&amp;/\&/g')
    [ -n "$action" ] || die "no Keycloak login form"
    CB=$(curl -s -o /dev/null -w '%{redirect_url}' -c "$J" -b "$J" \
        --data-urlencode "username=$1" --data-urlencode "password=pw-$1" --data-urlencode credentialId= "$action")
    [[ "$CB" == "$WPURL/wp-admin/admin-ajax.php?action=openid-connect-authorize"*code=* ]] || die "Keycloak did not return a code to WP: $CB"
    RES=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' -c "$J" -b "$J" "$CB")
}
logged_in() { grep -q 'wordpress_logged_in_' "$1" && [ "$(curl -s -o /dev/null -w '%{http_code}' -b "$1" "$WPURL/wp-admin/profile.php")" = 200 ]; }

login alice
[[ "$RES" == 302* ]] || die "alice callback: $RES"
logged_in "$J" || die "alice has no WP session"
[ "$(wp user get alice --field=roles 2>/dev/null)" = administrator ] || die "alice role: $(wp user get alice --field=roles 2>/dev/null)"
[ "$(wp user get alice --field=user_email 2>/dev/null)" = alice@example.com ] || die "alice email not mapped"
echo "  ok: wp-login -> Keycloak -> code exchange -> user alice created, wp.admin -> administrator"
replay=$CB; ajar=$J

login bob
logged_in "$J" || die "bob has no WP session"
[ "$(wp user get bob --field=roles 2>/dev/null)" = editor ] || die "bob role"
echo "  ok: bob wp.editor -> editor"

login carol
[[ "$RES" == 403* ]] || die "carol (only otherapp.admin) got: $RES"
! logged_in "$J" || die "carol got a session"
echo "  ok: carol (admin of another client only) refused with 403, no session"

J=/tmp/jar-forged; rm -f "$J"
r=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' -c "$J" "$WPURL/wp-admin/admin-ajax.php?action=openid-connect-authorize&state=forged&code=abc")
[[ "$r" == "302 $WPURL/wp-login.php?login-error=invalid-state"* ]] || die "forged state: $r"
! grep -q wordpress_logged_in_ "$J" || die "forged state set a cookie"
r=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' -c "$J" "$replay")
[[ "$r" == "302 $WPURL/wp-login.php?login-error="* ]] || die "replayed code: $r"
! grep -q wordpress_logged_in_ "$J" || die "replayed code set a cookie"
echo "  ok: forged state and replayed code rejected"

J=$ajar
out=$(curl -s -b "$J" "$WPURL/wp-admin/")
lo=$(grep -oE 'wp-login.php\?action=logout(&amp;|&#038;)_wpnonce=[a-f0-9]+' <<<"$out" | head -1 | sed -E 's/&(amp|#038);/\&/' || true)
[ -n "$lo" ] || die "no logout link in wp-admin"
kclo=$(curl -s -o /dev/null -w '%{redirect_url}' -c "$J" -b "$J" "$WPURL/$lo")
[[ "$kclo" == "$KC_PUB/realms/smoke/protocol/openid-connect/logout?id_token_hint="* ]] || die "logout did not go to Keycloak end-session: $kclo"
! logged_in "$J" || die "WP session survived logout"
back=$(curl -s -o /dev/null -w '%{redirect_url}' -c "$J" -b "$J" "$kclo")
[[ "$back" == "$WPURL"* ]] || die "Keycloak logout did not return to WP: $back"
auth=$(curl -s -o /dev/null -w '%{redirect_url}' -c "$J" -b "$J" "$WPURL/wp-login.php")
curl -s -c "$J" -b "$J" "$auth" | grep -q 'id="kc-form-login"' || die "Keycloak SSO session survived logout"
echo "  ok: logout -> Keycloak end-session (id_token_hint) -> back to site; WP + Keycloak sessions gone"
EOF
ok "OIDC end to end (PKCE enforced by Keycloak)"

echo "==> local password login: on without OIDC, off with it"
pw='echo has_filter("authenticate","wp_authenticate_username_password") ? "on" : "off";'
[ "$(docker exec "$WP" env -u OIDC_CLIENT_ID wp --path=/usr/src/wordpress eval "$pw" 2>/dev/null)" = on ] || fail "password login off without OIDC"
[ "$(docker exec "$WP" wp --path=/usr/src/wordpress eval "$pw" 2>/dev/null)" = off ] || fail "password login on with OIDC"
ok "password login follows OIDC_CLIENT_ID"

echo "==> classic mode (plain docker run): root master on :80, www-data workers, OIDC redirect"
docker run -d --name "$WP80" --network "$NET" "${SALTS[@]}" \
    -e WORDPRESS_DB_HOST="$DB" -e WORDPRESS_DB_USER=wp -e WORDPRESS_DB_PASSWORD=wp -e WORDPRESS_DB_NAME=wp \
    -e OIDC_CLIENT_ID=wp -e OIDC_ENDPOINT_LOGIN="$KC_PUB/realms/smoke/protocol/openid-connect/auth" "$IMAGE" >/dev/null
loc=
for _ in $(seq 1 60); do
    loc=$(docker exec "$WP80" curl -s -o /dev/null -w '%{redirect_url}' http://localhost/wp-login.php 2>/dev/null || true)
    [ -n "$loc" ] && break
    sleep 2
done
[[ "$loc" == "$KC_PUB/realms/smoke/protocol/openid-connect/auth?"* ]] || fail "port-80 mode: wp-login redirect $loc"
[ "$(docker exec "$WP80" ps -o user= -p 1)" = root ] || fail "port-80 mode: master not root"
[ "$(docker exec "$WP80" sh -c 'ps -eo user=,args= | grep "[a]pache2" | grep -v ^root | cut -d" " -f1 | sort -u')" = www-data ] \
    || fail "port-80 mode: workers not www-data"
ok "root master, www-data workers, wp-login -> Keycloak"

echo "==> meta description"
docker exec "$WP80" wp option update blogdescription "Smoke tagline" --allow-root --path=/usr/src/wordpress >/dev/null
head=$(docker exec "$WP80" curl -s -H "Host: ${WPURL#http://}" http://localhost/)
grep -q '<meta name="description" content="Smoke tagline">' <<<"$head" \
    || { grep -oE '<title>[^<]*|<meta [^>]*>' <<<"$head" | head; echo "${head:0:300}"; fail "no meta description from tagline"; }
grep -q '<meta property="og:description" content="Smoke tagline">' <<<"$head" || fail "no og:description"
ok "meta description + og tags"

echo "==> Kubernetes-style uploads volume (root-owned, group 33): first start, uploads writable"
WPF=$P-wpfresh
docker rm -f "$WPF" >/dev/null 2>&1 || true
docker run -d --name "$WPF" --network "$NET" --user 33:33 --read-only --cap-drop ALL "${SALTS[@]}" \
    --tmpfs /tmp:rw,exec,mode=1777 --tmpfs /usr/src/wordpress/wp-content/uploads:rw,uid=0,gid=33,mode=2775 -e APACHE_PORT=8080 \
    -e WORDPRESS_DB_HOST="$DB" -e WORDPRESS_DB_USER=wp -e WORDPRESS_DB_PASSWORD=wp -e WORDPRESS_DB_NAME=wp "$IMAGE" >/dev/null
for _ in $(seq 1 30); do docker exec "$WPF" curl -sf -o /dev/null http://localhost:8080/wp-login.php?action=postpass 2>/dev/null && break; sleep 2; done
[ "$(docker inspect -f '{{.State.Running}} {{.RestartCount}}' "$WPF")" = "true 0" ] || { docker logs --tail 20 "$WPF" >&2; fail "first start on a root-owned volume crashed"; }
docker exec "$WPF" sh -c 'mkdir -p /usr/src/wordpress/wp-content/uploads/2026/10 && touch /usr/src/wordpress/wp-content/uploads/2026/10/a.jpg' \
    || fail "uploads on a root-owned group-33 volume not writable"
docker rm -f "$WPF" >/dev/null
ok "root-owned group-33 uploads volume: starts, uploads writable as uid 33"

echo "PASS: $IMAGE"
