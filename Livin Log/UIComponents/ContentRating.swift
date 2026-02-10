import Foundation

enum ContentRating: String, CaseIterable, Identifiable {
    case unrated = "Unrated"

    // TV ratings
    case tvY = "TV-Y"
    case tvY7 = "TV-Y7"
    case tvG = "TV-G"
    case tvPG = "TV-PG"
    case tv14 = "TV-14"
    case tvMA = "TV-MA"

    // Movie (MPAA) ratings (optional)
    case g = "G"
    case pg = "PG"
    case pg13 = "PG-13"
    case r = "R"
    case nc17 = "NC-17"

    var id: String { rawValue }
}
