import Foundation

var bad = 0
func check(_ name: String, _ ok: Bool) {
    print("  \(ok ? "ok  " : "FAIL") \(name)"); if !ok { bad += 1 }
}
func eq<T: Equatable>(_ name: String, _ got: T, _ want: T) {
    print("  \(got == want ? "ok  " : "FAIL") \(name)")
    if got != want { bad += 1; print("        want: \(want)\n        got : \(got)") }
}

typealias C = ShareLink.Candidate
let priyaS = C(name: "Priya Sharma", numbers: [("_$!<Mobile>!$_", "+91 98765 43210")])
let priyaM = C(name: "Priya Mehta",  numbers: [("_$!<Mobile>!$_", "+91 91234 56789")])
let rohan  = C(name: "Rohan Gupta",  numbers: [("_$!<Home>!$_", "+91 22 5555 0000"),
                                               ("_$!<Mobile>!$_", "+91 99999 11111")])
let twoHome = C(name: "Sneha Rao", numbers: [("_$!<Home>!$_", "+91 22 1111 2222"),
                                             ("_$!<Work>!$_", "+91 22 3333 4444")])
let local  = C(name: "Local Only", numbers: [("_$!<Mobile>!$_", "98765 43210")])

// Decision 5 — deterministic, and ambiguity is asked rather than guessed.
print("recipient resolution")
eq("one match resolves to its number", ShareLink.resolve(spoken: "Rohan", in: [priyaS, rohan]),
   .resolved(name: "Rohan Gupta", number: "+919999911111"))
eq("two Priyas ask instead of picking",
   ShareLink.resolve(spoken: "Priya", in: [priyaS, priyaM, rohan]),
   .ambiguous(name: "Priya", options: ["Priya Sharma", "Priya Mehta"]))
eq("the mobile wins over a home line",
   ShareLink.resolve(spoken: "Rohan", in: [rohan]),
   .resolved(name: "Rohan Gupta", number: "+919999911111"))
eq("two numbers and no mobile asks",
   ShareLink.resolve(spoken: "Sneha", in: [twoHome]),
   .ambiguous(name: "Sneha Rao", options: ["+91 22 1111 2222", "+91 22 3333 4444"]))
eq("an unknown name fails visibly with what was heard",
   ShareLink.resolve(spoken: "Priyanka", in: [priyaS, rohan]),
   .notFound(spoken: "Priyanka"))
eq("a number with no country code asks once",
   ShareLink.resolve(spoken: "Local", in: [local]),
   .needsCountryCode(name: "Local Only", number: "9876543210"))
eq("a surname finds the card too", ShareLink.resolve(spoken: "Sharma", in: [priyaS]),
   .resolved(name: "Priya Sharma", number: "+919876543210"))
eq("the full name resolves", ShareLink.resolve(spoken: "Priya Sharma", in: [priyaS, priyaM]),
   .resolved(name: "Priya Sharma", number: "+919876543210"))

// The boundary that protects the worst failure this feature can produce.
print("\nmatching is whole-name-part, never substring")
check("\"Ann\" does not match \"Joanna\"", !ShareLink.matches(spoken: "Ann", name: "Joanna Reed"))
check("\"Priy\" does not match \"Priya\"", !ShareLink.matches(spoken: "Priy", name: "Priya Sharma"))
check("case does not matter", ShareLink.matches(spoken: "priya", name: "Priya Sharma"))
check("diacritics do not matter", ShareLink.matches(spoken: "Jose", name: "José Álvarez"))
check("an empty spoken name matches nobody", !ShareLink.matches(spoken: "", name: "Priya"))

print("\nnumber normalization")
eq("spaces and dashes go", ShareLink.normalize("+91-98765 43210"), "+919876543210")
eq("brackets go", ShareLink.normalize("(555) 010-9999"), "5550109999")
eq("a leading plus survives", ShareLink.normalize("+1 555 010 9999"), "+15550109999")
check("a plain local number has no country code", !ShareLink.hasCountryCode("9876543210"))
check("a + number does", ShareLink.hasCountryCode("+919876543210"))

// Decision 12 — the URL gets its own line so the preview renders.
print("\nmessage shape")
eq("note then URL on its own line",
   ShareLink.message(note: "this is the pricing article", url: URL(string: "https://x.com/a")!),
   "this is the pricing article\nhttps://x.com/a")
eq("no note means the bare URL, never a generated sentence",
   ShareLink.message(note: nil, url: URL(string: "https://x.com/a")!), "https://x.com/a")
eq("a whitespace-only note counts as none",
   ShareLink.message(note: "   ", url: URL(string: "https://x.com/a")!), "https://x.com/a")

// The encoding cases the design names by hand.
print("\npercent-encoding")
check("emoji survive",
      ShareLink.encode("ship it 🚀").contains("%F0%9F%9A%80"))
check("a newline is encoded, not dropped",
      ShareLink.encode("one\ntwo").contains("%0A"))
check("an ampersand cannot split the query",
      !ShareLink.encode("https://x.com/?utm=a&b=c").contains("&"))
check("a question mark is encoded",
      !ShareLink.encode("https://x.com/?q=1").contains("?"))
check("a plus is encoded, so it cannot become a space",
      !ShareLink.encode("a+b").contains("+"))
check("spaces do not survive raw", !ShareLink.encode("a b").contains(" "))

print("\nURL construction")
let msg = ShareLink.message(note: "look", url: URL(string: "https://x.com/?a=1&b=2")!)
let wa = ShareLink.whatsappURL(number: "+919876543210", message: msg)!
check("scheme is whatsapp://send", wa.absoluteString.hasPrefix("whatsapp://send?"))
check("the + is stripped from the phone", wa.absoluteString.contains("phone=919876543210"))
check("the shared URL's own query is not split off",
      !wa.absoluteString.contains("b=2") || wa.absoluteString.contains("%26b%3D2"))
check("nothing in the URL sends", !wa.absoluteString.lowercased().contains("send=true"))
let selfWa = ShareLink.whatsappURL(number: nil, message: msg)!
check("a self send omits the phone entirely", !selfWa.absoluteString.contains("phone="))
let fallback = ShareLink.waMeURL(number: "+919876543210", message: msg)!
check("wa.me carries the number in the path",
      fallback.absoluteString.hasPrefix("https://wa.me/919876543210?text="))

// Decision 12 — odd URLs ship as-is; we do not judge shareworthiness.
print("\nodd URLs ship unjudged")
for raw in ["http://localhost:3000/x", "file:///Users/a/b.pdf", "https://x.com/#frag"] {
    let u = URL(string: raw)!
    check("\(raw) survives into the message",
          ShareLink.message(note: nil, url: u) == raw)
}


// The narrowing an ambiguity answer performs. `resolve` is where a wrong
// recipient would come from, so the second pass is tested the same way
// the first is: by the matching rule, not by list position.
print("\nnarrowing after a disambiguation answer")
let bothPriyas = [priyaS, priyaM]
eq("answering with a surname narrows to one",
   ShareLink.resolve(spoken: "Sharma", in: bothPriyas),
   .resolved(name: "Priya Sharma", number: "+919876543210"))
eq("answering with the full name narrows to one",
   ShareLink.resolve(spoken: "Priya Mehta", in: bothPriyas),
   .resolved(name: "Priya Mehta", number: "+919123456789"))
eq("answering with the ambiguous first name again stays ambiguous",
   ShareLink.resolve(spoken: "Priya", in: bothPriyas),
   .ambiguous(name: "Priya", options: ["Priya Sharma", "Priya Mehta"]))
check("an answer naming nobody narrows to nobody",
      bothPriyas.filter { ShareLink.matches(spoken: "Sneha", name: $0.name) }.isEmpty)

// The country-code answer, which is concatenated onto a local number.
print("\ncountry code answers")
eq("a spoken +91 makes a dialable number",
   ShareLink.normalize("+91" + "9876543210"), "+919876543210")
check("the result now passes the country-code test",
      ShareLink.hasCountryCode(ShareLink.normalize("+91" + "9876543210")))
check("a bare 91 without the plus does not",
      !ShareLink.hasCountryCode(ShareLink.normalize("91" + "9876543210")))

// The self-number answer path strips speech punctuation before storing.
print("\nself number answers")
eq("spoken digits with spaces normalize",
   ShareLink.normalize("+91 98765 43210".filter { $0.isNumber || $0 == "+" }),
   "+919876543210")
check("a number spoken without a country code is refused",
      !ShareLink.hasCountryCode(ShareLink.normalize("9876543210")))

print("\n\(bad == 0 ? "all passed" : "\(bad) FAILED")")
exit(bad == 0 ? 0 : 1)
