import Foundation

/// Turns "play a Kendrick Lamar song" into a video that actually plays.
///
/// The search page can't autoplay — a results list is as far as a plain
/// link goes. A `/watch?v=<id>` page does autoplay, so the only missing
/// piece is the id, which the YouTube Data API returns for a free key
/// (no OAuth, no billing).
///
/// Deliberately best-effort. Every failure path returns nil and the
/// caller falls back to opening the search results, which is exactly what
/// the feature did before this existed. A dead key, an exhausted quota or
/// a flaky network should degrade to the old behaviour, never to nothing.
///
/// Quota worth knowing about: a free project gets 10,000 units a day and
/// a search costs 100, so roughly 100 plays per day. Resets midnight
/// Pacific. Only "play" spends quota — plain "open" and "search" still
/// build URLs locally and cost nothing.
enum YouTubeSearch {
    private static let endpoint = "https://www.googleapis.com/youtube/v3/search"

    /// The top video for a query, or nil if anything at all goes wrong.
    static func topVideoURL(for query: String) async -> URL? {
        guard let key = APIKeyProvider.youTubeAPIKey else {
            NSLog("Sayline: no YouTube API key — falling back to the search page")
            return nil
        }
        guard var components = URLComponents(string: endpoint) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "type", value: "video"),
            URLQueryItem(name: "maxResults", value: "1"),
            // Excludes results that can't be played outside YouTube's own
            // player; a watch page still works, but this biases toward
            // videos that reliably start.
            URLQueryItem(name: "videoEmbeddable", value: "true"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "key", value: key),
        ]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 6 // this sits in a hold-to-talk loop

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                NSLog("Sayline: YouTube search failed -> \(body.prefix(220))")
                return nil
            }
            struct SearchResponse: Decodable {
                struct Item: Decodable {
                    struct ID: Decodable { let videoId: String? }
                    struct Snippet: Decodable { let title: String }
                    let id: ID
                    let snippet: Snippet
                }
                let items: [Item]
            }
            let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
            guard let first = decoded.items.first, let videoID = first.id.videoId else {
                NSLog("Sayline: YouTube search returned no video for \"\(query)\"")
                return nil
            }
            NSLog("%@", "Sayline: YouTube top result for \"\(query)\" -> \(first.snippet.title) [\(videoID)]")
            return URL(string: "https://www.youtube.com/watch?v=\(videoID)")
        } catch {
            NSLog("Sayline: YouTube search error -> \(error.localizedDescription)")
            return nil
        }
    }
}
