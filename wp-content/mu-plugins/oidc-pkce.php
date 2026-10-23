<?php
/**
 * Plugin Name: OIDC PKCE (S256)
 * Description: Adds PKCE to daggerhart-openid-connect-generic, which has no upstream support.
 */

// The verifier lives 5 minutes in a transient keyed by the OIDC state parameter.
add_filter( 'openid-connect-generic-auth-url', 'oidc_pkce_add_challenge' );
function oidc_pkce_add_challenge( $url ) {
    $query = wp_parse_url( $url, PHP_URL_QUERY );
    parse_str( $query ? $query : '', $params );
    if ( empty( $params['state'] ) ) {
        return $url;
    }
    $verifier = rtrim( strtr( base64_encode( random_bytes( 64 ) ), '+/', '-_' ), '=' );
    set_transient( 'oidc_pkce_' . $params['state'], $verifier, 300 );
    $challenge = rtrim( strtr( base64_encode( hash( 'sha256', $verifier, true ) ), '+/', '-_' ), '=' );
    return add_query_arg( array(
        'code_challenge'        => $challenge,
        'code_challenge_method' => 'S256',
    ), $url );
}

add_filter( 'openid-connect-generic-alter-request', 'oidc_pkce_add_verifier', 20, 2 );
function oidc_pkce_add_verifier( $request, $operation ) {
    if ( 'get-authentication-token' !== $operation ) {
        return $request;
    }
    $state = isset( $_GET['state'] ) ? sanitize_text_field( wp_unslash( $_GET['state'] ) ) : '';
    if ( '' === $state ) {
        return $request;
    }
    $verifier = get_transient( 'oidc_pkce_' . $state );
    if ( false !== $verifier ) {
        $request['body']['code_verifier'] = $verifier;
        delete_transient( 'oidc_pkce_' . $state );
    }
    return $request;
}
