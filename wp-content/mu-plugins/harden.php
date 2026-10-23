<?php
/**
 * Plugin Name: hardening
 * Description: Attack-surface trims: XML-RPC off, no user enumeration, no version leak.
 */

// XML-RPC fully off (also 403-blocked at the apisix edge).
add_filter('xmlrpc_enabled', '__return_false');
remove_action('wp_head', 'rsd_link');
add_filter('wp_headers', function ($headers) {
    unset($headers['X-Pingback']);
    return $headers;
});

// No anonymous user enumeration via REST.
add_filter('rest_endpoints', function ($endpoints) {
    if (!is_user_logged_in()) {
        unset($endpoints['/wp/v2/users'], $endpoints['/wp/v2/users/(?P<id>[\d]+)']);
    }
    return $endpoints;
});

// No ?author=N / author archive enumeration.
add_action('template_redirect', function () {
    if (is_author() && !is_user_logged_in()) {
        wp_redirect(home_url(), 301);
        exit;
    }
});

// No users in wp-sitemap.xml.
add_filter('wp_sitemaps_add_provider', function ($provider, $name) {
    return 'users' === $name ? false : $provider;
}, 10, 2);

// No WP version leak.
remove_action('wp_head', 'wp_generator');
add_filter('the_generator', '__return_empty_string');

// Core asset URLs carry ?ver=<wp_version>; swap it for a keyed hash so cache
// busting still works but the version is not readable.
function harden_mask_core_ver($src) {
    static $mask = null;
    $v = $GLOBALS['wp_version'];
    if (!is_string($src) || !preg_match('/[?&]ver=' . preg_quote($v, '/') . '(&|$)/', $src)) {
        return $src;
    }
    $mask = $mask ?? substr(wp_hash($v), 0, 8);
    return add_query_arg('ver', $mask, $src);
}
add_filter('style_loader_src', 'harden_mask_core_ver', 9999);
add_filter('script_loader_src', 'harden_mask_core_ver', 9999);
add_filter('x_redirect_by', '__return_false');

// Safe defaults when wp-config.php does not set them (the chart does, but only
// after first boot): no theme/plugin code editor, no background auto-updates
// (the image owns core and bundled plugins).
defined('DISALLOW_FILE_EDIT') || define('DISALLOW_FILE_EDIT', true);
defined('AUTOMATIC_UPDATER_DISABLED') || define('AUTOMATIC_UPDATER_DISABLED', true);
