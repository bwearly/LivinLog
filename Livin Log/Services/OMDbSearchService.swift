//
//  OMDbSearchService.swift
//  Livin Log
//

import Foundation

enum OMDbMediaType: String, CaseIterable {
    case movie
    case series
    case episode

    var displayName: String { rawValue }
}

struct OMDbSearchResult: Identifiable, Equatable {
    let imdbID: String
    let title: String
    let year: String
    let type: String?
    let posterURL: URL?
    let genres: [String]
    let contentRating: String?

    var id: String { imdbID }

    var normalizedPosterURLString: String {
        posterURL?.absoluteString ?? ""
    }

    var yearInt16: Int16? {
        let firstYear = year
            .split(separator: "–")
            .first?
            .split(separator: "-")
            .first
            .map(String.init) ?? year
        guard let intYear = Int16(firstYear.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return intYear > 0 ? intYear : nil
    }
}

enum OMDbSearchError: LocalizedError {
    case invalidResponse
    case temporarilyUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "OMDb returned an unexpected response."
        case .temporarilyUnavailable:
            return "OMDb search is temporarily unavailable."
        }
    }
}

enum OMDbAPIConfig {
    static let apiKey = "fcedff92"
}

enum OMDbSearchService {
    private static let cache = OMDbSearchCache()
    private static let detailCache = OMDbDetailCache()

    private struct SearchResponse: Decodable {
        let Search: [SearchItem]?
        let Response: String
        let Error: String?
    }

    private struct SearchItem: Decodable {
        let Title: String?
        let Year: String?
        let imdbID: String?
        let `Type`: String?
        let Poster: String?
    }

    private struct DetailResponse: Decodable {
        let Title: String?
        let Year: String?
        let Rated: String?
        let Genre: String?
        let imdbID: String?
        let `Type`: String?
        let Poster: String?
        let Response: String
        let Error: String?
    }

    static func search(title: String, year: String, preferredType: OMDbMediaType? = nil) async throws -> [OMDbSearchResult] {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard meaningfulCharacterCount(in: trimmedTitle) >= 3 else { return [] }

        let trimmedYear = year.trimmingCharacters(in: .whitespacesAndNewlines)
        let cacheKey = [trimmedTitle.lowercased(), trimmedYear, preferredType?.rawValue ?? "any"].joined(separator: "|")
        if let cached = await cache.results(for: cacheKey) {
            return cached
        }

        guard var components = URLComponents(string: "https://www.omdbapi.com/") else { return [] }
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "apikey", value: OMDbAPIConfig.apiKey),
            URLQueryItem(name: "s", value: trimmedTitle)
        ]
        if !trimmedYear.isEmpty {
            queryItems.append(URLQueryItem(name: "y", value: trimmedYear))
        }
        if let preferredType {
            queryItems.append(URLQueryItem(name: "type", value: preferredType.rawValue))
        }
        components.queryItems = queryItems

        guard let url = components.url else { return [] }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse else {
                throw OMDbSearchError.invalidResponse
            }
            guard http.statusCode == 200 else {
#if DEBUG
                print("🎬 [OMDbSearch] non-200 status=\(http.statusCode)")
#endif
                throw OMDbSearchError.temporarilyUnavailable
            }

            let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            guard contentType.contains("json") || contentType.isEmpty else {
#if DEBUG
                print("🎬 [OMDbSearch] non-json content-type=\(contentType)")
#endif
                throw OMDbSearchError.invalidResponse
            }

            let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
            guard decoded.Response == "True" else {
#if DEBUG
                if let error = decoded.Error, error != "Movie not found!" {
                    print("🎬 [OMDbSearch] response error=\(error)")
                }
#endif
                await cache.store([], for: cacheKey)
                return []
            }

            let mapped = (decoded.Search ?? []).compactMap(mapItem)
            await cache.store(mapped, for: cacheKey)
            return mapped
        } catch let error as URLError where error.code == .cancelled {
#if DEBUG
            print("🎬 [OMDbSearch] request cancelled")
#endif
            return []
        } catch let error as DecodingError {
#if DEBUG
            print("🎬 [OMDbSearch] invalid JSON: \(error)")
#endif
            throw OMDbSearchError.invalidResponse
        }
    }

    static func details(for result: OMDbSearchResult) async throws -> OMDbSearchResult {
        guard let detail = try await details(imdbID: result.imdbID) else { return result }
        return detail
    }

    static func details(imdbID: String) async throws -> OMDbSearchResult? {
        let trimmedID = imdbID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { return nil }
        if let cached = await detailCache.result(for: trimmedID) {
            return cached
        }

        guard var components = URLComponents(string: "https://www.omdbapi.com/") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "apikey", value: OMDbAPIConfig.apiKey),
            URLQueryItem(name: "i", value: trimmedID),
            URLQueryItem(name: "plot", value: "short")
        ]
        guard let url = components.url else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse else {
                throw OMDbSearchError.invalidResponse
            }
            guard http.statusCode == 200 else {
#if DEBUG
                print("🎬 [OMDbDetail] non-200 status=\(http.statusCode)")
#endif
                throw OMDbSearchError.temporarilyUnavailable
            }

            let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            guard contentType.contains("json") || contentType.isEmpty else {
#if DEBUG
                print("🎬 [OMDbDetail] non-json content-type=\(contentType)")
#endif
                throw OMDbSearchError.invalidResponse
            }

            let decoded = try JSONDecoder().decode(DetailResponse.self, from: data)
            guard decoded.Response == "True" else {
#if DEBUG
                if let error = decoded.Error, error != "Movie not found!" {
                    print("🎬 [OMDbDetail] response error=\(error)")
                }
#endif
                return nil
            }

            guard let mapped = mapDetail(decoded) else { return nil }
            await detailCache.store(mapped, for: trimmedID)
            return mapped
        } catch let error as URLError where error.code == .cancelled {
#if DEBUG
            print("🎬 [OMDbDetail] request cancelled")
#endif
            return nil
        } catch let error as DecodingError {
#if DEBUG
            print("🎬 [OMDbDetail] invalid JSON: \(error)")
#endif
            throw OMDbSearchError.invalidResponse
        }
    }

    static func meaningfulCharacterCount(in value: String) -> Int {
        value.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) &&
            !CharacterSet.punctuationCharacters.contains($0)
        }.count
    }

    private static func mapItem(_ item: SearchItem) -> OMDbSearchResult? {
        guard let imdbID = item.imdbID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !imdbID.isEmpty,
              let title = item.Title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }

        return OMDbSearchResult(
            imdbID: imdbID,
            title: title,
            year: item.Year?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            type: normalizedOptional(item.Type),
            posterURL: normalizedPosterURL(item.Poster),
            genres: [],
            contentRating: nil
        )
    }

    private static func mapDetail(_ item: DetailResponse) -> OMDbSearchResult? {
        guard let imdbID = item.imdbID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !imdbID.isEmpty,
              let title = item.Title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }

        return OMDbSearchResult(
            imdbID: imdbID,
            title: title,
            year: item.Year?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            type: normalizedOptional(item.Type),
            posterURL: normalizedPosterURL(item.Poster),
            genres: normalizedGenres(item.Genre),
            contentRating: normalizedContentRating(item.Rated)
        )
    }

    private static func normalizedPosterURL(_ rawPoster: String?) -> URL? {
        let poster = rawPoster?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !poster.isEmpty, poster != "N/A" else { return nil }
        let normalizedPoster = poster.replacingOccurrences(of: "http://", with: "https://")
        return URL(string: normalizedPoster)
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty || trimmed == "N/A" ? nil : trimmed
    }

    private static func normalizedGenres(_ value: String?) -> [String] {
        (value ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "N/A" }
    }

    private static func normalizedContentRating(_ value: String?) -> String? {
        normalizedOptional(value)
    }
}

private actor OMDbSearchCache {
    private var resultCache: [String: [OMDbSearchResult]] = [:]
    private var order: [String] = []
    private let maxEntries = 40

    func results(for key: String) -> [OMDbSearchResult]? {
        resultCache[key]
    }

    func store(_ results: [OMDbSearchResult], for key: String) {
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

private actor OMDbDetailCache {
    private var resultCache: [String: OMDbSearchResult] = [:]
    private var order: [String] = []
    private let maxEntries = 80

    func result(for key: String) -> OMDbSearchResult? {
        resultCache[key]
    }

    func store(_ result: OMDbSearchResult, for key: String) {
        if resultCache[key] == nil {
            order.append(key)
        }
        resultCache[key] = result
        while order.count > maxEntries, let oldest = order.first {
            order.removeFirst()
            resultCache.removeValue(forKey: oldest)
        }
    }
}
