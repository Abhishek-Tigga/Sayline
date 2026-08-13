import Foundation

/// Opens the connections a dictation is about to need, while the user is
/// still talking.
///
/// The first model call of a session paid **5913 ms** against 191–607 ms
/// warm — TLS and DNS, not the model. A hold lasts seconds, so the
/// handshake fits inside it for free, and if the user turns out not to
/// want a rewrite nothing was lost but one HEAD request.
///
/// Deliberately not a keep-alive pool: `URLSession` already reuses
/// connections it has open, so all this does is make sure there is one to
/// reuse. Nothing to maintain, nothing to leak.
enum ConnectionWarmer {
    private static var lastWarmed: Date?
    /// URLSession keeps idle connections for a while; re-warming inside
    /// that window is wasted work.
    private static let staleAfter: TimeInterval = 60

    private static let hosts = [
        "https://api.groq.com/openai/v1/models",
        "https://api.openai.com/v1/models",
    ]

    static func warm() {
        if let lastWarmed, Date().timeIntervalSince(lastWarmed) < staleAfter { return }
        lastWarmed = Date()
        for host in hosts {
            guard let url = URL(string: host) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 4
            // No key, so this 401s — which is fine and is the point. The
            // handshake is the product; the response is discarded.
            URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
        }
    }
}
