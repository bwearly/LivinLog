import SwiftUI

struct QuoteDetailView: View {
    let quote: LLQuote
    let household: Household

    @State private var showingEdit = false

    var body: some View {
        List {
            Section("Quote") {
                Text("\(quote.textValue)")
                    .font(.title3)

                Text("— \(quote.speakerNameValue)")
                    .foregroundStyle(.secondary)
            }

            Section("Details") {
                LabeledContent("Said at", value: (quote.saidAt ?? .now).formatted(date: .abbreviated, time: .shortened))

                if let child = quote.child {
                    LabeledContent("Child", value: child.nameValue)
                }

                if let age = quote.childAgeLabel {
                    LabeledContent("Age", value: age)
                }

                if !quote.contextTextValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(quote.contextTextValue)
                }
            }

            Section {
                ShareLink(item: quote.shareText) {
                    Label("Share Quote", systemImage: "square.and.arrow.up")
                }
            }
        }
        .navigationTitle("Quote")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Edit") {
                    showingEdit = true
                }
            }
        }
        .sheet(isPresented: $showingEdit) {
            NavigationStack {
                AddEditQuoteView(household: household, editingQuote: quote)
            }
        }
    }
}
