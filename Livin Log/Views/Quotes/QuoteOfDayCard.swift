import SwiftUI
import CoreData

struct QuoteOfDayCard: View {
    let household: Household

    @FetchRequest private var quotes: FetchedResults<LLQuote>
    @State private var showingAddQuote = false

    init(household: Household) {
        self.household = household
        _quotes = FetchRequest<LLQuote>(
            sortDescriptors: [NSSortDescriptor(keyPath: \LLQuote.createdAt, ascending: true)],
            predicate: NSPredicate(format: "household == %@", household),
            animation: .default
        )
    }

    private var quoteOfTheDay: LLQuote? {
        let all = Array(quotes)
        guard !all.isEmpty else { return nil }

        let daySeed = DateFormatter.quoteSeedFormatter.string(from: Date())
        let sorted = all.sorted { lhs, rhs in
            let lh = "\(lhs.id?.uuidString ?? lhs.objectID.uriRepresentation().absoluteString)-\(daySeed)".hashValue
            let rh = "\(rhs.id?.uuidString ?? rhs.objectID.uriRepresentation().absoluteString)-\(daySeed)".hashValue
            return lh < rh
        }
        return sorted.first
    }

    var body: some View {
        Group {
            if let quote = quoteOfTheDay {
                NavigationLink {
                    QuotesListView(household: household)
                } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Quote of the Day", systemImage: "quote.bubble.fill")
                                    .font(.headline)

                                Text("\(quote.textValue)")
                                    .font(.body)
                                    .lineLimit(3)

                                Text("— \(quote.speakerNameValue)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)

                                if let childAgeLabel = quote.childAgeLabel {
                                    Text(childAgeLabel)
                                        .font(.caption)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Capsule().fill(.thinMaterial))
                                }
                            }

                            Spacer(minLength: 8)

                            ShareLink(item: quote.shareText) {
                                Image(systemName: "square.and.arrow.up")
                                    .padding(8)
                                    .background(Circle().fill(.thinMaterial))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.thinMaterial)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(.quaternary)
                    )
                }
                .buttonStyle(.plain)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Quote of the Day", systemImage: "quote.bubble.fill")
                        .font(.headline)

                    Text("No quotes yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button("Add Quote") {
                        showingAddQuote = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.thinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.quaternary)
                )
            }
        }
        .sheet(isPresented: $showingAddQuote) {
            NavigationStack {
                AddEditQuoteView(household: household)
            }
        }
    }
}

private extension DateFormatter {
    static let quoteSeedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
