import Foundation
import Combine

@MainActor
final class HackerNewsModel: ObservableObject {
    @Published private(set) var stories: [HNStory]?
    @Published private(set) var currentIndex = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastSuccess: Date?
    @Published private(set) var isRefreshing = false
    var isLoading: Bool { stories == nil && isRefreshing }
    var currentStory: HNStory? {
        guard let stories, stories.indices.contains(currentIndex) else { return nil }
        return stories[currentIndex]
    }

    private let load: () async throws -> [HNStory]
    private var task: Task<Void, Never>?
    private var generation = 0
    private var isActive = false
    private var hasQueuedRefresh = false

    init(load: @escaping () async throws -> [HNStory] = { try await HackerNewsModel.load() }) {
        self.load = load
    }

    func refresh() {
        isActive = true
        if let task {
            if task.isCancelled { hasQueuedRefresh = true }
            return
        }
        let version = generation
        let load = load
        isRefreshing = true
        task = Task { [weak self] in
            let result: Result<[HNStory], Error>
            do {
                try Task.checkCancellation()
                result = .success(try await load())
            }
            catch { result = .failure(error) }
            self?.finish(result, generation: version)
        }
    }

    func stop() {
        isActive = false
        hasQueuedRefresh = false
        generation += 1
        task?.cancel()
        isRefreshing = false
    }

    func rotate() {
        guard let stories, !stories.isEmpty else { return }
        currentIndex = (currentIndex + 1) % stories.count
    }

    private func finish(_ result: Result<[HNStory], Error>, generation version: Int) {
        task = nil
        isRefreshing = false
        if isActive && version == generation {
            switch result {
            case .success(let value):
                let selectedID = currentStory?.objectID
                currentIndex = value.firstIndex { $0.objectID == selectedID } ?? 0
                stories = value
                errorMessage = nil
                lastSuccess = Date()
            case .failure(let error):
                if !(error is CancellationError) && (error as? URLError)?.code != .cancelled {
                    errorMessage = error.localizedDescription
                }
            }
        }
        if isActive && hasQueuedRefresh {
            hasQueuedRefresh = false
            refresh()
        }
    }

    nonisolated static func load(session: URLSession = .shared) async throws -> [HNStory] {
        let url = URL(string: "https://hn.algolia.com/api/v1/search?tags=front_page")!
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let result = try JSONDecoder().decode(HNResponse.self, from: data)
        return result.hits.filter { $0.title != nil && !$0.title!.isEmpty }
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
