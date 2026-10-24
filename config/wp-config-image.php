<?php
// Loaded by the baked wp-config.php (the upstream wp-config-docker.php, which
// reads everything else from WORDPRESS_* env vars). The docroot is part of the
// image, owned by root and read-only for PHP: WordPress never changes its own
// code. A new core, plugin or theme version is a new image (CI: Trivy gate).
define('DISALLOW_FILE_MODS', true);          // no installs/updates from wp-admin
define('DISALLOW_FILE_EDIT', true);          // no theme/plugin file editor
define('AUTOMATIC_UPDATER_DISABLED', true);  // no background updates
define('WP_AUTO_UPDATE_CORE', false);
define('WP_TEMP_DIR', '/tmp');
define('FS_METHOD', 'direct');              // uploads: plain file writes, no FTP fallback

// Salts sign every login cookie and nonce. The upstream template falls back to
// a public placeholder when they are missing; refuse to run instead.
foreach (['AUTH_KEY', 'SECURE_AUTH_KEY', 'LOGGED_IN_KEY', 'NONCE_KEY',
          'AUTH_SALT', 'SECURE_AUTH_SALT', 'LOGGED_IN_SALT', 'NONCE_SALT'] as $wp_salt) {
    $wp_salt_file = getenv("WORDPRESS_{$wp_salt}_FILE");
    $wp_salt_value = $wp_salt_file ? (string) @file_get_contents($wp_salt_file) : (string) getenv("WORDPRESS_$wp_salt");
    if (strlen(trim($wp_salt_value)) < 32) {
        error_log("wp-config: WORDPRESS_$wp_salt is missing or shorter than 32 characters");
        if (PHP_SAPI === 'cli') {
            fwrite(STDERR, "WordPress is not configured: WORDPRESS_$wp_salt is missing.\n");
            exit(1);
        }
        http_response_code(503);
        exit("WordPress is not configured.\n");
    }
}
unset($wp_salt, $wp_salt_file, $wp_salt_value);
