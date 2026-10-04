import Foundation

/// The front page, polled once for every bar. The source has no setting, so its input is empty.
typealias HackerNewsModel = PollingModel<[HNStory]>

enum HackerNewsFeed {
    static func load(session: URLSession = .shared) async throws -> [HNStory] {
        let url = URL(string: "https://hn.algolia.com/api/v1/search?tags=front_page")!
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let result = try JSONDecoder().decode(HNResponse.self, from: data)
        return result.hits.filter { $0.title != nil && !$0.title!.isEmpty }
    }
}

/// Which story a widget shows. Selection is kept by id so a refresh that reorders the
/// front page does not jump to another story, and every bar can rotate on its own.
enum HackerNewsRotation {
    static func current(_ id: String?, in stories: [HNStory]) -> HNStory? {
        stories.first { $0.objectID == id } ?? stories.first
    }

    static func next(after id: String?, in stories: [HNStory]) -> HNStory? {
        guard !stories.isEmpty else { return nil }
        let index = stories.firstIndex { $0.objectID == id } ?? 0
        return stories[(index + 1) % stories.count]
    }
}

struct HNResponse: Codable {
    let hits: [HNStory]
}

struct HNStory: Codable, Equatable {
    let objectID: String
    let title: String?
    let urlString: String?
    let points: Int
    let author: String?
    let numComments: Int
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case objectID
        case title
        case urlString = "url"
        case points
        case author
        case numComments = "num_comments"
        case createdAt = "created_at"
    }

    var url: URL? {
        guard let urlString = urlString else { return nil }
        return URL(string: urlString)
    }
}
