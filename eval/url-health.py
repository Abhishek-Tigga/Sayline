#!/usr/bin/env python3
"""Checks every URL the catalog can produce against the live web.

Separate from catalog-checks (which is offline and fast) because this
needs the network and takes a minute. Run it periodically, not on every
build.

What it can and cannot do is worth being clear about: this DETECTS a
stale URL, it does not fix one. The catalog is compiled into the app, so
a fix ships in an app update. What this buys is finding out before a
user does — and at runtime a dead entry already degrades to the site's
home rather than a 404, so a stale row is a worse answer, not a broken
one.

Only 404 and 410 count as failures, matching AgentRouter.verifiedPage:
Amazon answers 503 and LinkedIn 999 to non-browser requests, and neither
means the page is gone.
"""
import re, subprocess, sys, urllib.request, urllib.error
from concurrent.futures import ThreadPoolExecutor

SRC = "Sources/Sayline/WebsiteCatalog.swift"
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
      "AppleWebKit/537.36 (KHTML, like Gecko) Safari/537.36")


def urls_from_catalog():
    """Asks the catalog itself, so this can never drift from the source."""
    helper = '''
import Foundation
for site in WebsiteCatalog.sites {
    print("home\\t\\(site.label)\\t\\(site.home)")
    for (region, variant) in site.regional.sorted(by: { $0.key < $1.key }) {
        print("regional \\(region)\\t\\(site.label)\\t\\(variant.home)")
    }
    for (intent, path) in site.personalPages.sorted(by: { $0.key < $1.key }) {
        print("own page \\"\\(intent)\\"\\t\\(site.label)\\t\\(site.home + path)")
    }
}
'''
    import os, tempfile
    d = tempfile.mkdtemp()
    open(os.path.join(d, "main.swift"), "w").write(helper)
    binary = os.path.join(d, "list")
    r = subprocess.run(["swiftc", "-o", binary, SRC, os.path.join(d, "main.swift")],
                       capture_output=True, text=True)
    if r.returncode:
        sys.exit("could not build the catalog lister:\n" + r.stderr[:1500])
    out = subprocess.run([binary], capture_output=True, text=True).stdout
    return [line.split("\t") for line in out.strip().splitlines() if "\t" in line]


def check(row):
    kind, label, url = row
    req = urllib.request.Request(url, method="HEAD", headers={"User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            code = r.status
    except urllib.error.HTTPError as e:
        code = e.code
    except Exception as e:
        return (row, None, type(e).__name__)
    return (row, code, None)


def main():
    rows = urls_from_catalog()
    print(f"checking {len(rows)} URLs from {SRC}\n")
    dead, ambiguous, unknown = [], [], []
    with ThreadPoolExecutor(max_workers=12) as pool:
        for row, code, err in pool.map(check, rows):
            kind, label, url = row
            own_page = kind.startswith("own page")
            if code in (404, 410) and own_page:
                # Cannot tell a moved URL from a login wall from out here.
                # GitHub answers 404 to logged-out requests for /pulls and
                # /issues, and both are perfectly alive in a signed-in
                # browser. Reported for a human to open, not failed.
                ambiguous.append((label, kind, url, code))
                print(f"  CHECK {code}  {label:14} {kind:18} {url}")
            elif code in (404, 410):
                dead.append((label, kind, url, code))
                print(f"  DEAD  {code}  {label:14} {kind:18} {url}")
            elif code is None:
                unknown.append((label, kind, url, err))
                print(f"  ?     ---  {label:14} {kind:18} {url}  ({err})")

    alive = len(rows) - len(dead) - len(ambiguous) - len(unknown)
    print(f"\n{alive} alive, {len(dead)} dead, {len(ambiguous)} to check by hand, "
          f"{len(unknown)} unreachable")
    if ambiguous:
        print("\nCHECK rows are the user's own pages answering 404 to a request "
              "with no cookies. Open each in a signed-in browser: a working page "
              "means the row is fine, a real 404 means it moved.")
    if dead:
        print("\nDead entries need a source change in " + SRC +
              " and an app release. Until then they degrade to the site's home.")
    return 1 if dead else 0


if __name__ == "__main__":
    sys.exit(main())
