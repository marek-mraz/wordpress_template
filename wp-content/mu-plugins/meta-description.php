<?php
/**
 * Plugin Name: meta description
 * Description: <meta name="description"> + og tags from the tagline (front page) or the post excerpt.
 */

add_action('wp_head', function () {
    if (is_singular() && !is_front_page()) {
        $post = get_queried_object();
        $text = has_excerpt($post) ? get_the_excerpt($post) : $post->post_content;
        $title = get_the_title($post);
    } else {
        $text = get_bloginfo('description');
        $title = get_bloginfo('name');
    }
    $desc = wp_html_excerpt(trim(preg_replace('/\s+/', ' ', wp_strip_all_tags(strip_shortcodes((string) $text)))), 155, '…');
    if ($desc === '') {
        $desc = get_bloginfo('description');
    }
    if ($desc === '') {
        return;
    }
    printf("<meta name=\"description\" content=\"%s\">\n", esc_attr($desc));
    printf("<meta property=\"og:title\" content=\"%s\">\n", esc_attr(wp_strip_all_tags($title)));
    printf("<meta property=\"og:description\" content=\"%s\">\n", esc_attr($desc));
    printf("<meta property=\"og:site_name\" content=\"%s\">\n", esc_attr(get_bloginfo('name')));
}, 1);
