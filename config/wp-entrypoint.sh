#!/usr/bin/env bash
# Runs before the upstream entrypoint/Apache on every container start.
# 1. The upstream entrypoint copies WordPress core into the docroot only on the
#    first install, so a new image never upgraded an existing site (prod ran
#    6.9.4 on a 7.0.2 image). Upgrade core (never downgrade; wp-content,
#    .htaccess and wp-config.php untouched) and its DB schema.
# 2. Sync the bundled mu-plugins/plugins/themes before Apache starts (a fresh
#    docroot gets them from docker-entrypoint.sh), so
#    OPcache (validate_timestamps=0) never caches a file that is replaced later.
# 3. See below: first install into a root-owned volume as non-root.
set -Eeuo pipefail

src=/usr/src/wordpress
ver() { php -r 'include $argv[1]; echo $wp_version;' "$1/wp-includes/version.php"; }

if [ -f wp-includes/version.php ]; then
	have=$(ver .)
	want=$(ver "$src")
	if php -r 'exit(version_compare($argv[1], $argv[2], ">") ? 0 : 1);' "$want" "$have"; then
		echo >&2 "Upgrading WordPress core in $PWD from $have to $want"
		# Files owned by another uid can't be chmod'ed without CAP_FOWNER; tar still
		# writes their content but exits 2, which used to kill the first boot and
		# skip update-db on the restart (2026-10-22 rollout).
		tar --create --file - --directory "$src" --exclude ./wp-content --exclude ./.htaccess . \
			| tar --extract --file - --no-overwrite-dir --no-same-permissions \
			|| echo >&2 "WARN: core copy reported errors (see above)"
	fi
	# Every boot, not only after a copy: a no-op when the schema is current.
	if [ -s wp-config.php ]; then
		wp core update-db --allow-root --path="$PWD" >&2 || echo >&2 "WARN: wp core update-db failed (admin will be prompted)"
	fi
	for d in mu-plugins plugins themes; do
		mkdir -p "wp-content/$d"
		cp -af "$src/wp-content/$d/." "wp-content/$d/" 2>/dev/null || true
	done
elif [ "$(id -u)" != 0 ] && [ ! -e index.php ]; then
	# 3. Fresh volume, non-root (Kubernetes fsGroup: the volume root is owned by
	#    root, group-writable). The upstream copy chmods "." despite
	#    --no-overwrite-dir, tar exits 2 and the first start crashes. Copy here;
	#    the upstream entrypoint then finds WordPress and skips its copy.
	echo >&2 "Installing WordPress $(ver "$src") into $PWD"
	tar --create --file - --directory "$src" . \
		| tar --extract --file - --no-overwrite-dir --no-same-permissions \
		|| echo >&2 "WARN: core copy reported errors (see above)"
fi

exec docker-entrypoint.sh "$@"
