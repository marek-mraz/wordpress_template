#!/usr/bin/env bash
# Chart check: lint, render with and without OIDC, syntax-check the postStart
# setup script embedded in the Deployment, refuse a render without an image tag.
# Usage (repo root): bash tests/chart.sh   (needs helm)
set -euo pipefail
C=component/wordpress/charts/wordpress
helm lint "$C" --set-string app.image.tag=ci
for oidc in false true; do
    script=$(helm template ci "$C" --set-string app.image.tag=ci --set oauth.enabled=$oidc \
        | sed -n '/> \/usr\/local\/bin\/setup-wp.sh$/,/^ *EOF$/p' | sed '1d;$d')
    [ -n "$script" ] || { echo "setup-wp.sh not found in the rendered Deployment"; exit 1; }
    bash -n <<<"$script"
done
if helm template ci "$C" >/dev/null 2>&1; then echo "rendered without app.image.tag"; exit 1; fi
echo "chart ok"
