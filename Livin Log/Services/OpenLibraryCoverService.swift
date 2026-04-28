import Foundation

struct OpenLibraryBookResult: Identifiable, Equatable {
    let key: String
    let title: String
    let author: String
    let coverURL: URL?

    var id: String { key }
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

        enum CodingKeys: String, CodingKey {
            case key, title
            case authorName = "author_name"
            case coverID = "cover_i"
        }
    }

    static func search(title: String, author: String) async throws -> [OpenLibraryBookResult] {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAuthor = author.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty || !trimmedAuthor.isEmpty else { return [] }

        var components = URLComponents(string: "https://openlibrary.org/search.json")!
        components.queryItems = [
            URLQueryItem(name: "title", value: trimmedTitle.isEmpty ? nil : trimmedTitle),
            URLQueryItem(name: "author", value: trimmedAuthor.isEmpty ? nil : trimmedAuthor),
            URLQueryItem(name: "limit", value: "8"),
            URLQueryItem(name: "fields", value: "key,title,author_name,cover_i,isbn,first_publish_year")
        ]

        guard let url = components.url else { return [] }

        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            print("📚 OpenLibrary HTTP:", http.statusCode)
        }

        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        return decoded.docs.compactMap { doc in
            guard let key = doc.key, let title = doc.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
                return nil
            }
            let primaryAuthor = doc.authorName?.first?.trimmingCharacters(in: .whitespacesAndNewlines)
            let coverURL: URL?
            if let coverID = doc.coverID {
                coverURL = URL(string: "https://covers.openlibrary.org/b/id/\(coverID)-L.jpg")
            } else {
                coverURL = nil
            }
            return OpenLibraryBookResult(
                key: key,
                title: title,
                author: (primaryAuthor?.isEmpty == false ? primaryAuthor! : "Unknown author"),
                coverURL: coverURL
            )
        }
    }

    static func coverURL(title: String, author: String) async -> URL? {
        do {
            let results = try await search(title: title, author: author)
            return results.first(where: { $0.coverURL != nil })?.coverURL
        } catch {
            print("📚 OpenLibrary exception:", error)
            return nil
        }
    }
}
