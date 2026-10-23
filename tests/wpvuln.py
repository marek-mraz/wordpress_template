#!/usr/bin/env python3
"""WordPress core/plugin/theme vulnerability check against wpvulnerability.net.

Trivy does not know WordPress plugin CVEs, so this reads what the image ships:
  - core version from the Dockerfile `FROM wordpress:<x.y.z>`
  - plugins/themes from composer.lock (wpackagist-plugin/*, wpackagist-theme/*)
  - plugins baked from release zips in the Dockerfile (.../releases/download/v<ver>/<slug>.zip)
  - themes in wp-content/themes (style.css `Version:`)
Slugs the API does not know (commercial/custom code) are listed as "not checked".
Exits 1 if any installed version falls in a known vulnerable range, 2 on API errors.
Usage: python3 tests/wpvuln.py [--self-test]   (run from the repo root; stdlib only)
"""
import json, os, re, sys, urllib.request

API = "https://www.wpvulnerability.net"


def ver(v):
    """'5.9' -> (5, 9, 0, 0); numeric parts only, padded so 5.9 == 5.9.0."""
    t = tuple(int(x) for x in re.findall(r"\d+", str(v)))
    return t + (0,) * (4 - len(t))


def hits(version, vulns):
    """Vulnerabilities whose range contains version."""
    v, out = ver(version), []
    for vu in vulns or []:
        op = vu.get("operator") or {}
        lo, hi = op.get("min_version"), op.get("max_version")
        if lo and not (v > ver(lo) if op.get("min_operator") == "gt" else v >= ver(lo)):
            continue
        if hi and not (v <= ver(hi) if op.get("max_operator") == "le" else v < ver(hi)):
            continue
        ids = [s.get("id") for s in vu.get("source") or [] if str(s.get("id", "")).startswith("CVE-")]
        out.append("%s [%s]%s" % (vu.get("name"), ", ".join(ids) or "no CVE",
                                  " UNFIXED" if str(op.get("unfixed")) == "1" else ""))
    return out


def fetch(kind, slug):
    req = urllib.request.Request("%s/%s/%s/" % (API, kind, slug), headers={"User-Agent": "wpvuln-ci"})
    with urllib.request.urlopen(req, timeout=30) as r:
        d = json.load(r)
    if d.get("error"):
        raise RuntimeError("%s/%s: API error %s" % (kind, slug, d.get("message")))
    return d.get("data") or {}


def check(kind, slug, version):
    """-> (status, details). status: ok | vuln | unchecked"""
    if not version:
        return "unchecked", "no Version header (custom)"
    d = fetch(kind, slug if kind != "core" else version)
    if kind != "core" and not d.get("name"):
        return "unchecked", "not on wordpress.org (commercial/custom)"
    found = hits(version, d.get("vulnerability"))
    return ("vuln", "; ".join(found)) if found else ("ok", "")


def inventory():
    items = []
    df = open("Dockerfile").read()
    m = re.search(r"^FROM wordpress:(\d+(?:\.\d+)*)", df, re.M)
    items.append(("core", "wordpress", m.group(1) if m else None))
    for p in json.load(open("composer.lock"))["packages"]:
        if p["type"] in ("wordpress-plugin", "wordpress-theme"):
            items.append((p["type"][10:], p["name"].split("/", 1)[1], p["version"].lstrip("v")))
    for ver_, slug in re.findall(r"releases/download/v?([0-9][^/\s]*)/([A-Za-z0-9_-]+)\.zip", df):
        items.append(("plugin", slug, ver_))
    tdir = "wp-content/themes"
    for slug in sorted(os.listdir(tdir)):
        css = os.path.join(tdir, slug, "style.css")
        if os.path.isfile(css):
            m = re.search(r"^\s*Version:\s*(\S+)", open(css, errors="replace").read(), re.M)
            items.append(("theme", slug, m.group(1) if m else None))
    return items


def self_test():
    assert ver("5.9") == ver("5.9.0") < ver("5.10") < ver("5.13.0")
    vulns = fetch("plugin", "lightbox-photoswipe").get("vulnerability")
    assert any("CVE-2026-14833" in h for h in hits("5.8.3", vulns)), "5.8.3 must flag CVE-2026-14833"
    assert not any("CVE-2026-14833" in h for h in hits("5.13.0", vulns)), "5.13.0 must not flag it"
    print("self-test OK: lightbox-photoswipe 5.8.3 -> CVE-2026-14833, 5.13.0 clean")


def main():
    if "--self-test" in sys.argv:
        return self_test()
    bad = 0
    for kind, slug, version in inventory():
        try:
            status, info = check(kind, slug, version)
        except Exception as e:  # network/API failure must not pass silently
            print("ERROR       %-6s %s %s: %s" % (kind, slug, version, e))
            sys.exit(2)
        bad += status == "vuln"
        print("%-11s %-6s %s %s%s" % ({"ok": "OK", "vuln": "VULNERABLE", "unchecked": "NOT CHECKED"}[status],
                                      kind, slug, version or "-", "  " + info if info else ""))
    print("mu-plugins (custom, not checked): %s" % " ".join(sorted(os.listdir("wp-content/mu-plugins"))))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
