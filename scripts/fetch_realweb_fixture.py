#!/usr/bin/env python3
"""Snapshot a real website as a SELF-CONTAINED single HTML file.

See scripts/fetch_realweb_fixture.sh for the rationale (the host harnesses read
one local file and do not fetch subresources, so we inline them to keep the
hambrowse-vs-chromium comparison honest).

Inlines: <link rel=stylesheet href=...> -> <style>...</style>
         <script src=...>              -> <script>...</script>
Leaves images alone (both engines fail/succeed identically on a missing image).
Caps total output so the engine's 4MB file buffer is not overrun.
"""
import re
import sys
import urllib.parse
import urllib.request

UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
      "Chrome/126.0 Safari/537.36")
CAP = 3_600_000          # stay under the engine's 4MiB file_buf
PER_RES_CAP = 2_400_000


def get(url, timeout=25):
    req = urllib.request.Request(url, headers={"User-Agent": UA,
                                               "Accept": "*/*"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read(), r.geturl()


def main():
    url, out = sys.argv[1], sys.argv[2]
    raw, final = get(url)
    html = raw.decode("utf-8", "replace")

    def abs_url(u):
        return urllib.parse.urljoin(final, u)

    n_css = n_js = n_fail = 0

    def sub_link(m):
        nonlocal n_css, n_fail
        tag = m.group(0)
        if "stylesheet" not in tag.lower():
            return tag
        href = re.search(r'href\s*=\s*["\']([^"\']+)["\']', tag, re.I)
        if not href:
            return tag
        try:
            body, _ = get(abs_url(href.group(1)))
            body = body[:PER_RES_CAP].decode("utf-8", "replace")
        except Exception as e:                       # noqa: BLE001
            n_fail += 1
            return "<!-- CSS FETCH FAILED %s -->" % e
        n_css += 1
        return "<style>\n%s\n</style>" % body.replace("</style", "<\\/style")

    html = re.sub(r"<link\b[^>]*>", sub_link, html, flags=re.I)

    def sub_script(m):
        nonlocal n_js, n_fail
        tag, rest = m.group(1), m.group(2)
        src = re.search(r'src\s*=\s*["\']([^"\']+)["\']', tag, re.I)
        if not src:
            return m.group(0)
        try:
            body, _ = get(abs_url(src.group(1)))
            body = body[:PER_RES_CAP].decode("utf-8", "replace")
        except Exception as e:                       # noqa: BLE001
            n_fail += 1
            return "<!-- JS FETCH FAILED %s -->" % e
        n_js += 1
        keep = ""
        tm = re.search(r'\btype\s*=\s*["\']([^"\']+)["\']', tag, re.I)
        if tm and "module" in tm.group(1):
            keep = ' type="module"'
        body = body.replace("</script", "<\\/script")
        return "<script%s>\n%s\n</script>" % (keep, body)

    html = re.sub(r"<script\b([^>]*)>(.*?)</script\s*>", sub_script, html,
                  flags=re.I | re.S)

    if len(html) > CAP:
        sys.stderr.write("[fetch] TRUNCATED %d -> %d bytes\n" % (len(html), CAP))
        html = html[:CAP] + "\n<!-- TRUNCATED -->\n</body></html>"

    with open(out, "w") as f:
        f.write(html)
    print("[fetch] %s -> %s  %d bytes  (%d css, %d js inlined, %d failed)"
          % (url, out, len(html), n_css, n_js, n_fail))


if __name__ == "__main__":
    main()
