<?php
// Build time only: download the WordPress.org translations for core and the
// bundled plugins/themes into wp-content/languages. The docroot is read-only
// at runtime, so a language cannot be installed later; bake it in here.
// Only WordPress.org projects are asked for: the wpackagist plugins in
// composer.json and the bundled twenty* themes (a custom theme or plugin with
// a colliding slug would otherwise get a stranger's translations).
//   php bake-translations.php /usr/src/wordpress composer.json sk_SK [de_DE ...]
$root = rtrim($argv[1] ?? '', '/');
$composer = $argv[2] ?? '';
$langs = array_slice($argv, 3);
if (!$langs) {
    exit(0);
}

function fail(string $msg): never
{
    fwrite(STDERR, "bake-translations: $msg\n");
    exit(1);
}

function get(string $url): string
{
    $body = @file_get_contents($url, false, stream_context_create(['http' => ['timeout' => 60]]));
    return $body === false ? fail("download failed: $url") : $body;
}

function header_version(string $file, string $required): ?string
{
    $head = (string) file_get_contents($file, false, null, 0, 8192);
    if ($required && !preg_match("/^[ \\t\\/*#@]*$required:/mi", $head)) {
        return null;
    }
    return preg_match('/^[ \t\/*#@]*Version:\s*(\S+)/mi', $head, $m) ? $m[1] : null;
}

include "$root/wp-includes/version.php";
$items = ['core:' => ['core', '', $wp_version, '']];
$require = json_decode((string) @file_get_contents($composer), true)['require'] ?? fail("cannot read $composer");
foreach (array_keys($require) as $pkg) {
    if (!str_starts_with($pkg, 'wpackagist-plugin/')) {
        continue;
    }
    $slug = substr($pkg, strlen('wpackagist-plugin/'));
    foreach (glob("$root/wp-content/plugins/$slug/*.php") as $f) {
        if ($v = header_version($f, 'Plugin Name')) {
            $items["plugins:$slug"] = ['plugins', $slug, $v, 'plugins/'];
        }
    }
}
foreach (glob("$root/wp-content/themes/twenty*/style.css") as $f) {
    if ($v = header_version($f, 'Theme Name')) {
        $slug = basename(dirname($f));
        $items["themes:$slug"] = ['themes', $slug, $v, 'themes/'];
    }
}

foreach ($items as [$type, $slug, $version, $dir]) {
    $query = http_build_query($slug ? ['slug' => $slug, 'version' => $version] : ['version' => $version]);
    $api = json_decode(get("https://api.wordpress.org/translations/$type/1.0/?$query"), true);
    $found = [];
    foreach ($api['translations'] ?? [] as $t) {
        if (!in_array($t['language'] ?? '', $langs, true)) {
            continue;
        }
        if (parse_url($t['package'] ?? '', PHP_URL_HOST) !== 'downloads.wordpress.org') {
            fail("unexpected package URL for $type $slug: " . ($t['package'] ?? ''));
        }
        $tmp = tempnam(sys_get_temp_dir(), 'l10n');
        file_put_contents($tmp, get($t['package']));
        $zip = new ZipArchive();
        if ($zip->open($tmp) !== true) {
            fail("cannot open {$t['package']}");
        }
        // Flat .mo/.po/.json files only: no paths, no PHP (.l10n.php is code).
        $names = [];
        for ($i = 0; $i < $zip->numFiles; $i++) {
            $name = $zip->getNameIndex($i);
            if (preg_match('/^[A-Za-z0-9_.-]+\.(mo|po|json)$/', $name) && !str_contains($name, '..')) {
                $names[] = $name;
            }
        }
        if (!$names || !$zip->extractTo("$root/wp-content/languages/$dir", $names)) {
            fail("cannot unpack {$t['package']}");
        }
        $zip->close();
        unlink($tmp);
        $found[] = $t['language'];
    }
    echo "$type " . ($slug ?: 'wordpress') . " $version: " . ($found ? implode(' ', $found) : 'no translation') . "\n";
    if ($type === 'core' && count($found) !== count($langs)) {
        fail('core has no translation for ' . implode(' ', array_diff($langs, $found)));
    }
}
