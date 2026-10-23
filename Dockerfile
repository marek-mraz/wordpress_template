# --- build stage: composer-managed plugins + release zips (nothing else ships)
FROM composer:2.10.3@sha256:af98f42dfff7c68ba8d53c2164fd9fde1087b7d449514baa38c418b1f6bc4bac AS build
WORKDIR /build
COPY composer.json composer.lock ./
RUN composer install --no-dev --no-scripts --no-autoloader --no-interaction

# MCP Adapter — GitHub release zip (pinned + checksummed). 0.7.1 carries the
# session-storage security fix (WordPress/mcp-adapter#386) that 0.5.0 lacks.
ADD --checksum=sha256:c8bc28f83d3c39beffa2add4f6becc0b1ae54097df433697d1dbe6520a80d769 \
    https://github.com/WordPress/mcp-adapter/releases/download/v0.7.1/mcp-adapter.zip /tmp/mcp.zip
RUN unzip -q /tmp/mcp.zip -d wp-content/plugins/

# --- runtime
FROM wordpress:7.1.3-php8.5-apache@sha256:574ea6f58239fba5fc95fe22e03683777259534498ab8e0ea3f6f176a9d620d1

# Security updates newer than the base image; drop the compiler toolchain the
# php image keeps for docker-php-ext-install and ghostscript (only used for PDF
# thumbnails, a long CVE history). 'less' is the pager WP-CLI uses.
# Akismet/Hello Dolly are not used; the chart copies image plugins to every site.
RUN apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends less \
    && apt-get purge -y --auto-remove $PHPIZE_DEPS libc6-dev ghostscript \
    && rm -rf /var/lib/apt/lists/* \
    && rm -rf /usr/src/wordpress/wp-content/plugins/akismet /usr/src/wordpress/wp-content/plugins/hello.php \
    && rm -f /usr/local/etc/php/conf.d/docker-php-ext-bcmath.ini /usr/local/bin/pear* /usr/local/bin/pecl /usr/local/bin/phpize /usr/local/bin/php-config

# WP-CLI (pinned release, checksum = published .sha512 verified at pin time)
ADD --chmod=755 --checksum=sha256:ce34ddd838f7351d6759068d09793f26755463b4a4610a5a5c0a97b68220d85c \
    https://github.com/wp-cli/wp-cli/releases/download/v2.12.0/wp-cli-2.12.0.phar /usr/local/bin/wp

# Plugins/themes/mu-plugins, owned by www-data
COPY --from=build --chown=www-data:www-data /build/wp-content/ /usr/src/wordpress/wp-content/
COPY --chown=www-data:www-data wp-content/ /usr/src/wordpress/wp-content/

# Apache/PHP defaults sized for one small site per pod; every knob below is an
# env var, so the chart can override without rebuilding.
# Run/lock dirs live under /tmp so the image also runs as uid 33 on a read-only
# root filesystem (needs writable /tmp + /var/www/html and APACHE_PORT=8080).
ENV APACHE_PORT=80 \
    APACHE_RUN_DIR=/tmp/apache2/run \
    APACHE_LOCK_DIR=/tmp/apache2/lock \
    APACHE_PID_FILE=/tmp/apache2/run/apache2.pid \
    APACHE_START_SERVERS=2 \
    APACHE_MIN_SPARE_SERVERS=1 \
    APACHE_MAX_SPARE_SERVERS=3 \
    APACHE_MAX_REQUEST_WORKERS=10 \
    APACHE_MAX_CONNECTIONS_PER_CHILD=1000 \
    PHP_MEMORY_LIMIT=128M \
    PHP_OPCACHE_MEMORY_CONSUMPTION=64 \
    PHP_OPCACHE_VALIDATE_TIMESTAMPS=0 \
    WP_CLI_CACHE_DIR=/tmp/wp-cli-cache
COPY config/apache-wordpress.conf /etc/apache2/conf-available/wordpress.conf
COPY config/php-wordpress.ini /usr/local/etc/php/conf.d/wordpress.ini
COPY config/wp-entrypoint.sh /usr/local/bin/wp-entrypoint.sh
# The chart's postStart writes /usr/local/bin/setup-wp.sh; the symlink lands
# that write in /tmp so it also works with a read-only root filesystem.
RUN sed -i 's/^Listen 80$/Listen ${APACHE_PORT}/' /etc/apache2/ports.conf \
    && sed -i 's/^<VirtualHost \*:80>$/<VirtualHost *:${APACHE_PORT}>/' /etc/apache2/sites-available/000-default.conf \
    && a2enmod -q headers \
    && a2dismod -q -f autoindex status negotiation auth_basic authn_file authz_user \
    && a2disconf -q serve-cgi-bin \
    && a2enconf -q wordpress \
    && ln -s /tmp/setup-wp.sh /usr/local/bin/setup-wp.sh \
    && apache2ctl -t

ENTRYPOINT ["wp-entrypoint.sh"]
CMD ["apache2-foreground"]
