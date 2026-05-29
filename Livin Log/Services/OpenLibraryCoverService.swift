import Foundation

struct OpenLibraryBookResult: Identifiable, Equatable {
    let key: String
    let title: String
    let author: String
    let firstPublishYear: Int?
    let coverID: Int?
    let isbn: String?
    let coverURL: URL?

    var id: String { key }
}

enum OpenLibrarySearchError: LocalizedError, Equatable {
    case temporarilyUnavailable
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .temporarilyUnavailable: return "Book search is temporarily unavailable."
        case .invalidResponse: return "Book search returned an unexpected response."
        }
    }
}

enum OpenLibraryCoverService {
    private struct SearchResponse: Decodable {
        let docs: [Doc]
    }

    private struct Doc: Decodable {
        let key: String?
        let title: String?
        let authorName: [String]?
        let coverID: Int?
        let isbn: [String]?
        let firstPublishYear: Int?

        enum CodingKeys: String, CodingKey {
            case key, title, isbn
            case authorName = "author_name"
            case coverID = "cover_i"
            case firstPublishYear = "first_publish_year"
        }
    }

    private static let cache = OpenLibraryCache()

    static func search(title: String, author: String) async throws -> [OpenLibraryBookResult] {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAuthor = author.trimmingCharacters(in: .whitespacesAndNewlines)
        let meaningfulTitleCount = trimmedTitle.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0) }.count
        guard meaningfulTitleCount >= 3 else { return [] }

        let cacheKey = "\(trimmedTitle.lowercased())|\(trimmedAuthor.lowercased())"
        if let cached = await cache.results(for: cacheKey) {
            return cached
        }

        guard var components = URLComponents(string: "https://openlibrary.org/search.json") else { return [] }
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "title", value: trimmedTitle),
            URLQueryItem(name: "limit", value: "8"),
            URLQueryItem(name: "fields", value: "key,title,author_name,cover_i,isbn,first_publish_year")
        ]
        if !trimmedAuthor.isEmpty {
            queryItems.append(URLQueryItem(name: "author", value: trimmedAuthor))
        }
        components.queryItems = queryItems

        guard let url = components.url else { return [] }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse else {
                throw OpenLibrarySearchError.invalidResponse
            }
            guard http.statusCode == 200 else {
#if DEBUG
                print("📚 [OpenLibrary] non-200 status=\(http.statusCode)")
#endif
                throw OpenLibrarySearchError.temporarilyUnavailable
            }

            let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            guard contentType.contains("json") || contentType.isEmpty else {
#if DEBUG
                print("📚 [OpenLibrary] non-json content-type=\(contentType)")
#endif
                throw OpenLibrarySearchError.invalidResponse
            }

            let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
            let mapped = decoded.docs.compactMap(mapDoc)
            await cache.store(mapped, for: cacheKey)
            return mapped
        } catch let error as URLError where error.code == .cancelled {
#if DEBUG
            print("📚 [OpenLibrary] request cancelled")
#endif
            return []
        } catch let error as DecodingError {
#if DEBUG
            print("📚 [OpenLibrary] invalid JSON: \(error)")
#endif
            throw OpenLibrarySearchError.invalidResponse
        }
    }

    static func coverURL(for result: OpenLibraryBookResult) -> URL? {
        if let coverID = result.coverID {
            return URL(string: "https://covers.openlibrary.org/b/id/\(coverID)-M.jpg")
        }
        if let isbn = result.isbn, !isbn.isEmpty {
            return URL(string: "https://covers.openlibrary.org/b/isbn/\(isbn)-M.jpg")
        }
        return nil
    }

    static func coverURL(title: String, author: String) async -> URL? {
        do {
            let results = try await search(title: title, author: author)
            return results.compactMap { coverURL(for: $0) }.first
        } catch let error as URLError where error.code == .cancelled {
            return nil
        } catch {
#if DEBUG
            print("📚 [OpenLibrary] cover lookup failed: \(error)")
#endif
            return nil
        }
    }

    private static func mapDoc(_ doc: Doc) -> OpenLibraryBookResult? {
        guard let key = doc.key,
              let title = doc.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }

        let primaryAuthor = doc.authorName?.first?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isbn = doc.isbn?.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        let result = OpenLibraryBookResult(
            key: key,
            title: title,
            author: primaryAuthor.flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown author",
            firstPublishYear: doc.firstPublishYear,
            coverID: doc.coverID,
            isbn: isbn,
            coverURL: nil
        )
        return OpenLibraryBookResult(
            key: result.key,
            title: result.title,
            author: result.author,
            firstPublishYear: result.firstPublishYear,
            coverID: result.coverID,
            isbn: result.isbn,
            coverURL: coverURL(for: result)
        )
    }
}

private actor OpenLibraryCache {
    private var resultCache: [String: [OpenLibraryBookResult]] = [:]
    private var order: [String] = []
    private let maxEntries = 30

    func results(for key: String) -> [OpenLibraryBookResult]? {
        resultCache[key]
    }

    func store(_ results: [OpenLibraryBookResult], for key: String) {
        if resultCache[key] == nil {
            order.append(key)
        }
        resultCache[key] = results
        while order.count > maxEntries, let oldest = order.first {
            order.removeFirst()
            resultCache.removeValue(forKey: oldest)
        }
    }
}
