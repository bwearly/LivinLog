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
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(
                                        LinearGradient(
                                            colors: [Color.pink.opacity(0.35), Color.orange.opacity(0.25)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .frame(width: 44, height: 44)

                                Image(systemName: "quote.bubble.fill")
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.white)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Quote of the Day")
                                    .font(.headline)

                                Text("\(quote.textValue)")
                                    .font(.body.weight(.semibold))
                                    .lineLimit(3)

                                Text("— \(quote.speakerNameValue)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)

                                if let childAgeLabel = quote.childAgeLabel {
                                    Text(childAgeLabel)
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(
                                            Capsule()
                                                .fill(Color.pink.opacity(0.16))
                                        )
                                        .foregroundStyle(Color.pink.opacity(0.9))
                                }
                            }

                            Spacer(minLength: 8)

                            ShareLink(item: quote.shareText) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(Color.primary)
                                    .padding(10)
                                    .background(
                                        Circle()
                                            .fill(Color.primary.opacity(0.10))
                                    )
                                    .overlay(
                                        Circle()
                                            .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.pink.opacity(0.22), Color.orange.opacity(0.14), Color.purple.opacity(0.12)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12))
                    )
                }
                .buttonStyle(.plain)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [Color.pink.opacity(0.35), Color.orange.opacity(0.25)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 44, height: 44)

                            Image(systemName: "quote.bubble.fill")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.white)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Quote of the Day")
                                .font(.headline)

                            Text("Save the funny little things your family says.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        showingAddQuote = true
                    } label: {
                        Label("Add Quote", systemImage: "plus")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.pink.opacity(0.18), Color.orange.opacity(0.12), Color.purple.opacity(0.10)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12))
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
