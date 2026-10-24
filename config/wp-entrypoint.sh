#!/usr/bin/env bash
# Runs before the upstream entrypoint/Apache on every container start.
# The docroot (core, plugins, themes, wp-config.php) is baked into the image,
# read-only and owned by root, so a new image is a new site version and nothing
# is copied here. Only the database schema follows the code: run update-db (a
# no-op when current). wp-content/uploads is the only volume.
set -Eeuo pipefail

if wp core is-installed --allow-root --path="$PWD" 2>/dev/null; then
	wp core update-db --allow-root --path="$PWD" >&2 || echo >&2 "WARN: wp core update-db failed (admin will be prompted)"
fi

exec docker-entrypoint.sh "$@"
