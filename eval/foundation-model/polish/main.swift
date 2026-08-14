import Foundation
// The deterministic policy pass, so the FM arm is scored through the same
// pipeline production runs: model -> validator -> SpeechPatterns.
while let l = readLine(strippingNewline: true) { print(SpeechPatterns.apply(l)) }
