// Checks CalendarScope — which accounts Sayline is allowed to read.
//
// The refuse-empty rule is the one that matters. An empty selection makes
// the whole feature silently dead: every query returns nothing, which is
// indistinguishable from a free afternoon and from a broken setup. It is
// also a slip anyone can make by turning switches off one at a time.
//
// Run: swiftc -o /tmp/chk Sources/Sayline/CalendarScope.swift \
//        eval/scope-checks/main.swift && /tmp/chk
import Foundation

var bad = 0
func check(_ label: String, _ ok: Bool) {
    if ok { print("  ok    \(label)") } else { print("  FAIL  \(label)"); bad += 1 }
}
func reset() {
    CalendarScope.selected = nil
    UserDefaults.standard.removeObject(forKey: "com.abhishektigga.sayline.knownCalendarSources")
}

let work = "src-work", personal = "src-personal", icloud = "src-icloud"
let all = [work, personal, icloud]

print("everything is included until someone says otherwise")
reset()
check("default is not narrowed", !CalendarScope.isNarrowed)
check("an unknown account still counts as selected", CalendarScope.isSelected("anything"))

print("\nnarrowing")
reset()
check("turning one off is accepted", CalendarScope.set(personal, enabled: false, allKnown: all))
check("  it is now narrowed", CalendarScope.isNarrowed)
check("  work still selected", CalendarScope.isSelected(work))
check("  personal is not", !CalendarScope.isSelected(personal))

print("\nturning everything back on returns to the plain 'all' state")
_ = CalendarScope.set(personal, enabled: true, allKnown: all)
check("not narrowed again", !CalendarScope.isNarrowed)

print("\nthe last account cannot be turned off")
reset()
_ = CalendarScope.set(personal, enabled: false, allKnown: all)
_ = CalendarScope.set(icloud, enabled: false, allKnown: all)
check("only work remains", CalendarScope.selected == [work])
check("turning off the last one is REFUSED", !CalendarScope.set(work, enabled: false, allKnown: all))
check("  and it is still selected", CalendarScope.isSelected(work))
check("  so a query can never be empty", CalendarScope.selected?.isEmpty == false)

print("\nan empty set written directly degrades to 'all', never to 'nothing'")
reset()
CalendarScope.selected = []
check("empty reads back as all", !CalendarScope.isNarrowed)

print("\naccounts added later are included, and reported")
reset()
_ = CalendarScope.noteSources([work, personal])          // first ever look
_ = CalendarScope.set(personal, enabled: false, allKnown: all)
let fresh = CalendarScope.noteSources([work, personal, "src-new"])
check("the new one is reported", fresh == ["src-new"])
check("  and included despite the scope", CalendarScope.isSelected("src-new"))
check("  while the deselected one stays off", !CalendarScope.isSelected(personal))

print("\nnothing is reported on the very first run — everything is new then")
reset()
check("first look reports nothing", CalendarScope.noteSources(all).isEmpty)

print("\n\(bad == 0 ? "all passed" : "\(bad) FAILED")")
exit(bad == 0 ? 0 : 1)
