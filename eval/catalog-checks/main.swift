// Checks the deterministic half of web routing — the part the LLM eval
// cannot see. run_eval.py scores what the model emits; these assert what
// our own code does with it afterwards. Both bugs from 2026-08-10 lived
// here, not in the model: "my Amazon orders" opened amazon.com because
// the model has no region, and "my LinkedIn messages" became a search
// because nothing claimed the query before the search template did.
//
// Run: swift eval/catalog-checks.swift
import Foundation

var failures = 0
func check(_ label: String, _ actual: String?, _ expected: String) {
    if actual == expected {
        print("  ok    \(label)")
    } else {
        print("  FAIL  \(label)\n        expected: \(expected)\n        actual:   \(actual ?? "nil")")
        failures += 1
    }
}

func page(_ site: String, _ query: String) -> String? {
    WebsiteCatalog.site(matching: site)
        .flatMap { WebsiteCatalog.personalPage(site: $0, query: query) }?
        .absoluteString
}

print("region detected as \(WebsiteCatalog.region)\n")

print("the user's own pages, with region applied")
check("amazon orders",       page("Amazon", "my orders"),                "https://www.amazon.in/gp/css/order-history")
check("amazon cart",         page("Amazon", "my cart"),                  "https://www.amazon.in/gp/cart/view.html")
check("linkedin messages",   page("LinkedIn", "my LinkedIn messages"),   "https://www.linkedin.com/messaging/")
check("linkedin saved jobs", page("LinkedIn", "my saved jobs"),          "https://www.linkedin.com/my-items/saved-jobs/")
check("youtube subs",        page("YouTube", "my subscriptions"),        "https://www.youtube.com/feed/subscriptions")
check("youtube watch later", page("YouTube", "watch later"),             "https://www.youtube.com/playlist?list=WL")
check("github pull requests",page("GitHub", "my pull requests"),         "https://github.com/pulls")

print("\nan explicitly named country wins over the detected one")
check("amazon uk orders",    WebsiteCatalog.site(matching: "Amazon UK").flatMap {
    WebsiteCatalog.personalPage(site: $0, query: "my orders", region: "GB")}?.absoluteString,
    "https://www.amazon.co.uk/gp/css/order-history")

print("\nordinary searches must not be captured by the table")
for q in ["wireless mouse", "best headphones", "orders of magnitude explained", "cart abandonment rate"] {
    check("not personal: \(q)", page("Amazon", q) ?? "search", "search")
}

print("\nregion correction of a URL the model supplied")
func fixed(_ raw: String, _ hint: String?) -> String? {
    URL(string: raw).map { WebsiteCatalog.regionalized($0, siteHint: hint).absoluteString }
}
check("amazon.com -> .in",   fixed("https://www.amazon.com/gp/css/order-history", "Amazon"),
                             "https://www.amazon.in/gp/css/order-history")
check("apple.com -> /in",    fixed("https://www.apple.com/iphone/", "Apple"),
                             "https://www.apple.com/in/iphone/")
check("already regional",    fixed("https://www.apple.com/in/iphone/", "Apple India"),
                             "https://www.apple.com/in/iphone/")
check("no variant, untouched", fixed("https://www.youtube.com/feed/history", "YouTube"),
                             "https://www.youtube.com/feed/history")

print("\n\(failures == 0 ? "all checks passed" : "\(failures) FAILED")")
exit(failures == 0 ? 0 : 1)
