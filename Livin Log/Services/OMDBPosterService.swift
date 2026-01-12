//
//  OMDbPosterService.swift
//  Keeply
//

import Foundation

actor PosterCache {
    static let shared = PosterCache()
    private var cache: [String: URL] = [:]

    func get(_ key: String) -> URL? { cache[key] }
    func set(_ key: String, url: URL) { cache[key] = url }
}

enum OMDbPosterService {
    private static let apiKey = "fcedff92"

    private struct OMDbResponse: Decodable {
        let Response: String
        let Poster: String?
        let Error: String?
    }

    static func posterURL(title: String?, year: Int16) async -> URL? {
        let trimmed = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let key = cacheKey(title: trimmed, year: year)
        if let cached = await PosterCache.shared.get(key) { return cached }

        var components = URLComponents(string: "https://www.omdbapi.com/")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "apikey", value: apiKey),
            URLQueryItem(name: "t", value: trimmed)
        ]
        if year != 0 {
            items.append(URLQueryItem(name: "y", value: String(year)))
        }
        components.queryItems = items

        guard let url = components.url else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            // Helpful debug if needed
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                print("🎬 OMDb HTTP:", http.statusCode)
            }

            let decoded = try JSONDecoder().decode(OMDbResponse.self, from: data)

            guard decoded.Response == "True",
                  let posterStr = decoded.Poster,
                  posterStr != "N/A"
            else {
                if let err = decoded.Error { print("🎬 OMDb error:", err) }
                return nil
            }

            // Normalize to https
            let normalized = posterStr.replacingOccurrences(of: "http://", with: "https://")
            guard let posterURL = URL(string: normalized) else { return nil }

            await PosterCache.shared.set(key, url: posterURL)
            return posterURL
        } catch {
            print("🎬 OMDb exception:", error)
            return nil
        }
    }

    private static func cacheKey(title: String, year: Int16) -> String {
        let y = year == 0 ? "na" : String(year)
        return "\(title.lowercased())|\(y)"
    }
}
