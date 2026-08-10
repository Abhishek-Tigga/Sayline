# Web search — manual test checklist

Say each phrase in agent mode (hold the hotkey, then Space). Tick what
lands correctly. Region on this Mac reads as **IN**, so the expected
domains below are the Indian ones — on a US Mac the same phrases should
give `.com` with no `/in` segment, and that difference is itself a test.

Anything that fails here is worth more than a failing eval case: the eval
sends clean text, and this sends whatever the transcriber heard. The
"Search for iPhone page in Apple India website" bug passed the eval and
failed live for exactly that reason.

## 1. Open a site

| Say | Expect |
|---|---|
| ☐ "Open YouTube" | `youtube.com` |
| ☐ "Open Gmail" | `mail.google.com` |
| ☐ "Open Figma" | `figma.com` |
| ☐ "Open Amazon" | `amazon.in` — region applied, not `.com` |
| ☐ "Open the Apple website" | `apple.com/in` |
| ☐ "Open Hacker News" | `news.ycombinator.com` — tests an alias, not a literal name |

## 2. Search on a site

| Say | Expect |
|---|---|
| ☐ "Search for noise cancelling headphones on Amazon" | `amazon.in/s?k=...` |
| ☐ "Find sourdough recipes on YouTube" | YouTube results, not a video |
| ☐ "Look up transformers on Wikipedia" | Wikipedia results |
| ☐ "Search GitHub for swift audio libraries" | GitHub results |

## 3. Canonical page vs search results

This is the one that broke live. The verb doesn't decide — whether the
site *has* a real page for that thing decides.

| Say | Expect |
|---|---|
| ☐ "Search for iPhone page in Apple India website" | `apple.com/in/iphone/` — a page, despite the word "search" |
| ☐ "Open the iPhone 15 Pro page on Apple" | `apple.com/in/iphone-15-pro/` |
| ☐ "Search for best iPhone 15 covers on Amazon" | `amazon.in/s?k=...` — results, because there's no canonical page for this |
| ☐ "Open the MacBook Air page" | `apple.com/in/macbook-air/` |

A 404 should never reach you. We check the URL before opening and fall
back to search if it's dead — so a wrong guess degrades to results,
never to a broken tab.

## 4. Verticals

Different tabs are different URLs, not one URL filtered. Before this
existed, "people from Razorpay" landed on the mixed tab where people sit
below posts.

| Say | Expect |
|---|---|
| ☐ "Find people from Razorpay on LinkedIn" | `/search/results/people/` |
| ☐ "Show me product managers at Razorpay on LinkedIn" | people tab, role in the query |
| ☐ "Look for design jobs on LinkedIn" | `/jobs/search/` |
| ☐ "Find Razorpay company page on LinkedIn" | `/search/results/companies/` |
| ☐ "Search GitHub users for tim cook" | `type=users` |
| ☐ "Show me images of golden retrievers" | Google Images |
| ☐ "Show me news about the budget" | Google News |
| ☐ "Find coffee shops near me on Maps" | Google Maps |

## 5. No site named

| Say | Expect |
|---|---|
| ☐ "Search for the tallest building in the world" | Google — the default when no site is named |
| ☐ "Look up how to poach an egg" | Google |

## 6. Unknown site — should refuse, not guess

| Say | Expect |
|---|---|
| ☐ "Open Zomato" | Refuses and says it doesn't know the site |
| ☐ "Open zomato.com" | Opens it — you supplied the domain |
| ☐ "Open my todo list site" | Refuses |

Guessing a domain is worse than refusing. A wrong guess opens someone
else's site with no signal that it was wrong.

## 7. Music — everything routes to YouTube

Apple Music binding was removed on your instruction. Spotify playback is
still on the backlog.

| Say | Expect |
|---|---|
| ☐ "Play Kendrick Lamar" | A video **plays**, not a results list |
| ☐ "Play lo-fi music on YouTube" | Plays |
| ☐ "Play the song Not Like Us" | Plays that song |
| ☐ "Open YouTube" | Home page — "open" must not start playback |

Play costs API quota (~100 a day, resets midnight Pacific). "Open" and
"search" cost nothing. If quota runs out, play degrades to the search
page rather than failing — so a results list here may mean quota, not a
bug. The log line tells you which.

## 8. Your own pages

| Say | Expect |
|---|---|
| ☐ "Show my Amazon orders" | Orders page, not Amazon home |
| ☐ "Open my LinkedIn messages" | Messages |
| ☐ "Open my YouTube subscriptions" | Subscriptions |

## 9. Input device — new, worth one check

| Do | Expect |
|---|---|
| ☐ Connect a Bluetooth speaker, make it the default input, dictate | Indicator names the device: "No audio from ..." |
| ☐ Disconnect it, dictate again | Works normally |

This is what bit you. The old behaviour was a 4 KB empty file sent to
Groq, which replied "Audio file is too short" — a message about speech
for a problem about hardware.

## Known failures — don't debug these, they're already logged

Two cases fail in the eval. If you hit them here, it's expected:

- **"Show my screen time"** → routes to Now Playing instead of the
  Screen Time pane.
- **"Open banana settings"** → opens System Settings instead of refusing
  cleanly.

Current eval standing: **45/47 (96%)**, 0 syntax failures, and now
identical across repeat runs — so a change of even one case from here is
a real signal rather than noise.

## When something fails

Note the exact words you said, not a tidied version. The gap between the
two is where the interesting bugs live. Then check the log:

```bash
grep "Sayline:" /private/tmp/claude-501/-Users-abhishektigga-Documents-claude/5a23ba11-61a3-493f-b07c-2e5632c99937/scratchpad/sayline_stderr.log | tail -40
```

The log shows the transcript, the tool the model picked, and the final
URL. Most "the agent is broken" reports turn out to be one of those three
being fine and the next one wrong — worth knowing which before changing
anything.
