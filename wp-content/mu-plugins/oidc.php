<?php
/**
 * Plugin Name: OIDC login
 * Description: OpenID Connect (Keycloak) settings from OIDC_* env, client-role -> WordPress role mapping, local password login off while OIDC is configured.
 */

function oidc_log($message) {
    $ts = date('Y-m-d H:i:s');
    $line = "[{$ts}] [oidc-mu-plugin] {$message}" . PHP_EOL;
    file_put_contents('php://stderr', $line);
}

// 1. Env lookup: getenv / $_ENV only (no $_SERVER) to avoid header/CGI pollution of OIDC secrets.
function get_env_value($key) {
    $v = getenv($key);
    if ($v !== false && $v !== '') {
        return $v;
    }
    if (isset($_ENV[$key]) && $_ENV[$key] !== '') {
        return $_ENV[$key];
    }
    return false;
}

// 2. Define Constants
// This locks the fields in the WP Admin UI (greys them out)
if (get_env_value('OIDC_CLIENT_ID')) {
    if (!defined('OIDC_CLIENT_ID')) define('OIDC_CLIENT_ID', get_env_value('OIDC_CLIENT_ID'));
    if (!defined('OIDC_CLIENT_SECRET')) define('OIDC_CLIENT_SECRET', get_env_value('OIDC_CLIENT_SECRET'));
    if (!defined('OIDC_CLIENT_SCOPE')) define('OIDC_CLIENT_SCOPE', get_env_value('OIDC_SCOPE'));
    if (!defined('OIDC_ENDPOINT_LOGIN_URL')) define('OIDC_ENDPOINT_LOGIN_URL', get_env_value('OIDC_ENDPOINT_LOGIN'));
    if (!defined('OIDC_ENDPOINT_USERINFO_URL')) define('OIDC_ENDPOINT_USERINFO_URL', get_env_value('OIDC_ENDPOINT_USERINFO'));
    if (!defined('OIDC_ENDPOINT_TOKEN_URL')) define('OIDC_ENDPOINT_TOKEN_URL', get_env_value('OIDC_ENDPOINT_TOKEN'));
    if (!defined('OIDC_ENDPOINT_LOGOUT_URL')) define('OIDC_ENDPOINT_LOGOUT_URL', get_env_value('OIDC_ENDPOINT_LOGOUT'));
    if (!defined('OIDC_JWKS_URI')) define('OIDC_JWKS_URI', get_env_value('OIDC_JWKS_URI'));
    if (!defined('OIDC_ISSUER')) define('OIDC_ISSUER', get_env_value('OIDC_ISSUER'));
    
    // Lock boolean settings if defined
    if (!defined('OIDC_LINK_EXISTING_USERS')) define('OIDC_LINK_EXISTING_USERS', get_env_value('OIDC_LINK_EXISTING_USERS') === 'true');
    if (!defined('OIDC_CREATE_IF_DOES_NOT_EXIST')) define('OIDC_CREATE_IF_DOES_NOT_EXIST', get_env_value('OIDC_CREATE_IF_NOT_EXISTS') === 'true');
    if (!defined('OIDC_REDIRECT_USER_BACK')) define('OIDC_REDIRECT_USER_BACK', get_env_value('OIDC_REDIRECT_BACK') === 'true');
    if (!defined('OIDC_ENFORCE_PRIVACY')) define('OIDC_ENFORCE_PRIVACY', get_env_value('OIDC_ENFORCE_PRIVACY') === 'true');
}

// Security Fix: Removed global SSRF bypass filters (`http_request_host_is_external` and `reject_unsafe_urls`).
// The OIDC plugin natively bypasses SSRF protection safely using `wp_remote_post` instead of `wp_safe_remote_post`
// because `allow_internal_idp` is set to 1 below.

// 3. Inject Values into the Settings Object via WP Core Option Filters
add_filter('option_openid_connect_generic_settings', 'oidc_inject_settings');
add_filter('default_option_openid_connect_generic_settings', 'oidc_inject_settings');

function oidc_inject_settings($settings) {
    if (!is_array($settings)) {
        $settings = array();
    }

    if (!get_env_value('OIDC_CLIENT_ID')) {
        return $settings;
    }

    $settings['client_id']       = get_env_value('OIDC_CLIENT_ID');
    $settings['client_secret']   = get_env_value('OIDC_CLIENT_SECRET');
    $settings['scope']           = get_env_value('OIDC_SCOPE');
    
    $settings['endpoint_login']       = get_env_value('OIDC_ENDPOINT_LOGIN');
    $settings['endpoint_userinfo']    = get_env_value('OIDC_ENDPOINT_USERINFO');
    $settings['endpoint_token']       = get_env_value('OIDC_ENDPOINT_TOKEN');
    $settings['endpoint_end_session'] = get_env_value('OIDC_ENDPOINT_LOGOUT');
    
    if (get_env_value('OIDC_JWKS_URI')) {
        $settings['jwks_uri'] = get_env_value('OIDC_JWKS_URI');
        $settings['endpoint_jwks'] = get_env_value('OIDC_JWKS_URI');
    }
    if (get_env_value('OIDC_ISSUER')) {
        $settings['issuer'] = get_env_value('OIDC_ISSUER');
    }

    $settings['identity_key']       = get_env_value('OIDC_IDENTITY_KEY');
    $settings['nickname_key']       = get_env_value('OIDC_NICKNAME_KEY');
    $settings['email_format']       = get_env_value('OIDC_EMAIL_FORMAT');
    $settings['displayname_format'] = get_env_value('OIDC_DISPLAYNAME_FORMAT');

    // Handle Booleans
    $settings['link_existing_users']      = get_env_value('OIDC_LINK_EXISTING_USERS') === 'true' ? 1 : 0;
    $settings['create_if_does_not_exist'] = get_env_value('OIDC_CREATE_IF_NOT_EXISTS') === 'true' ? 1 : 0;
    $settings['redirect_user_back']       = get_env_value('OIDC_REDIRECT_BACK') === 'true' ? 1 : 0;
    $settings['identify_with_username']   = get_env_value('OIDC_IDENTIFY_WITH_USERNAME') === 'true' ? 1 : 0;
    $settings['token_refresh_enable']     = get_env_value('OIDC_ENABLE_REFRESH_TOKEN') === 'true' ? 1 : 0;
    $settings['enforce_privacy']          = get_env_value('OIDC_ENFORCE_PRIVACY') === 'true' ? 1 : 0;

    // ENFORCEMENT: Force SSO Auto-Login Flow (Bypasses rendering of local login form)
    $settings['login_type'] = 'auto';
    $settings['http_request_timeout'] = 15;
    $settings['no_sslverify'] = 0;
    $settings['allow_internal_idp'] = 1;

    return $settings;
}


add_action( 'openid-connect-generic-update-user-using-current-claim', 'oidc_assign_roles_hierarchy', 10, 2 );

function oidc_assign_roles_hierarchy( $user, $user_claim ) {
    
    // --- SETTINGS: Define your Keycloak Role Names here ---
    $role_for_admin       = 'admin'; 
    $role_for_editor      = 'editor';
    $role_for_author      = 'author';
    $role_for_contributor = 'contributor';
    $role_for_subscriber  = 'subscriber';
    $client_id            = get_env_value('OIDC_CLIENT_ID') ? get_env_value('OIDC_CLIENT_ID') : 'default_client_id';
    // -----------------------------------------------------

    // Only trust client-specific roles (resource_access[client_id].roles) to avoid cross-app role bleed.
    $app_roles = array();
    if ( ! empty( $user_claim['resource_access'][ $client_id ]['roles'] ) && is_array( $user_claim['resource_access'][ $client_id ]['roles'] ) ) {
        $app_roles = $user_claim['resource_access'][ $client_id ]['roles'];
    }

    oidc_log( '=== ROLE CHECK FOR: ' . $user->user_login . ' ===' );
    oidc_log( 'Client ID used: ' . $client_id );
    oidc_log( 'resource_access.' . $client_id . '.roles: ' . json_encode( $user_claim['resource_access'][ $client_id ]['roles'] ?? '(absent)' ) );
    oidc_log( 'App roles used for WP mapping: ' . json_encode( $app_roles ) );

    // Assign WordPress role (strict in_array avoids PHP 7.x type juggling on loose ==).
    if ( in_array( $role_for_admin, $app_roles, true ) ) {
        oidc_log( 'MATCH: "' . $role_for_admin . '" → setting ADMINISTRATOR' );
        $user->set_role( 'administrator' );
    } 
    elseif ( in_array( $role_for_editor, $app_roles, true ) ) {
        oidc_log( 'MATCH: "' . $role_for_editor . '" → setting EDITOR' );
        $user->set_role( 'editor' );
    } 
    elseif ( in_array( $role_for_author, $app_roles, true ) ) {
        oidc_log( 'MATCH: "' . $role_for_author . '" → setting AUTHOR' );
        $user->set_role( 'author' );
    }
    elseif ( in_array( $role_for_contributor, $app_roles, true ) ) {
        oidc_log( 'MATCH: "' . $role_for_contributor . '" → setting CONTRIBUTOR' );
        $user->set_role( 'contributor' );
    }
    elseif ( in_array( $role_for_subscriber, $app_roles, true ) ) {
        oidc_log( 'MATCH: "' . $role_for_subscriber . '" → setting SUBSCRIBER' );
        $user->set_role( 'subscriber' );
    }
    else {
        oidc_log( 'No matching client roles → denying session (no role strip)' );
        wp_logout();
        wp_die(
            'Unauthorized: You do not have permission to access this application. Please contact your system administrator.',
            'Forbidden',
            array( 'response' => 403 )
        );
    }
}

// =========================================================================
// PHASE 5: LOCAL AUTHENTICATION DEPRECATION & LOCKDOWN
// =========================================================================

// 5.2. Application Passwords stay ENABLED (forced past the is_ssl() check —
// TLS terminates at the proxy): they are the only auth path for REST/MCP
// clients (mcp-adapter). Interactive password login stays dead (5.4).
add_filter('wp_is_application_passwords_available', '__return_true');

// 5.1, 5.3, 5.4: local-password lockdown, only when OIDC is configured; without it
// (local dev, a site without Keycloak) the normal WordPress login keeps working.
if (get_env_value('OIDC_CLIENT_ID')) {
    // 5.1. Hide and Disable Password Modification in the User Profile
    add_filter('show_password_fields', '__return_false');

    // 5.3. Eradicate Local Password Reset Workflows
    add_filter('allow_password_reset', '__return_false');

    add_action('login_init', function() {
        if (isset($_GET['action']) && in_array($_GET['action'], array('lostpassword', 'retrievepassword'))) {
            wp_redirect(home_url(), 301);
            exit;
        }
    });

    add_filter('gettext', function($text) {
        if ($text === 'Lost your password?') {
            return '';
        }
        return $text;
    });

    // 5.4. Disable local username/password except optional break-glass from OIDC_BREAK_GLASS_IP (env only).
    function oidc_break_glass_authenticate( $user, $username, $password ) {
        $trusted = get_env_value( 'OIDC_BREAK_GLASS_IP' );
        if ( $trusted === false || $trusted === '' ) {
            return $user;
        }
        $ip = isset( $_SERVER['REMOTE_ADDR'] ) ? $_SERVER['REMOTE_ADDR'] : '';
        if ( $ip === '' || $ip !== $trusted ) {
            return $user;
        }
        if ( $username === null || $username === '' || $password === null || $password === '' ) {
            return $user;
        }
        return wp_authenticate_username_password( $user, $username, $password );
    }

    add_filter( 'authenticate', 'oidc_break_glass_authenticate', 20, 3 );
    remove_filter( 'authenticate', 'wp_authenticate_username_password', 20, 3 );
    // Core also accepts email + password; without this the lockdown above is bypassable.
    remove_filter( 'authenticate', 'wp_authenticate_email_password', 20, 3 );
}

// 6. Ensure valid email for new users (Keycloak admin might not have an email)
add_filter( 'openid-connect-generic-alter-user-data', 'oidc_ensure_valid_email', 10, 2 );
function oidc_ensure_valid_email( $user_data, $user_claim ) {
    oidc_log( 'Creating/Updating user: ' . ( $user_data['user_login'] ?? '' ) );
    if ( empty( $user_data['user_email'] ) || ! is_email( $user_data['user_email'] ) ) {
        $fallback = sanitize_title( $user_data['user_login'] ) . '@' . (isset($_SERVER['HTTP_HOST']) ? $_SERVER['HTTP_HOST'] : 'localhost');
        oidc_log( 'WARNING: Invalid or missing email in claim. Falling back to: ' . $fallback );
        $user_data['user_email'] = $fallback;
    }
    return $user_data;
}