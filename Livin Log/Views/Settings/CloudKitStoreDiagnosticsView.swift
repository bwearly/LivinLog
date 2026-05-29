//
//  CloudKitStoreDiagnosticsView.swift
//  Livin Log
//

#if DEBUG
import SwiftUI
import CoreData

struct CloudKitStoreDiagnosticsView: View {
    @Environment(\.managedObjectContext) private var context

    @State private var issues: [CloudKitStoreDiagnosticIssue] = []
    @State private var rawTVShowRecords: [CloudKitStoreDiagnosticTVShowRecord] = []
    @State private var isScanning = false
    @State private var statusMessage: String?
    @State private var deleteError: String?

    private let scanner = CloudKitStoreDiagnosticScanner()

    var body: some View {
        Form {
            Section("DEBUG Local Cleanup") {
                Text("This tool is compiled into DEBUG builds only. It identifies local Core Data object graphs that cross the private and shared CloudKit stores, and lets you delete only the selected local test record. It does not silently delete anything and is not intended for production data cleanup.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button {
                    refreshDiagnostics()
                } label: {
                    Label(isScanning ? "Scanning…" : "Refresh Diagnostics", systemImage: "arrow.clockwise")
                }
                .disabled(isScanning)

                if let statusMessage {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let deleteError {
                    Text(deleteError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            if issues.isEmpty {
                Section("Detected Issues") {
                    ContentUnavailableView("No cross-store graph issues found", systemImage: "checkmark.seal")
                }
            } else {
                Section("Detected Issues") {
                    ForEach(issues) { issue in
                        CloudKitStoreDiagnosticIssueRow(issue: issue) {
                            delete(issue)
                        }
                    }
                }
            }

            Section("Raw TVShow Records") {
                Text("DEBUG-only list of every TVShow fetched from the private and shared stores, including records that do not currently appear as graph mismatches. Use the objectID URI to find a specific row such as TVShow/p16 before deleting only that TVShow.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if rawTVShowRecords.isEmpty {
                    ContentUnavailableView("No TVShow records found", systemImage: "tv")
                } else {
                    ForEach(rawTVShowRecords) { record in
                        CloudKitStoreDiagnosticTVShowRecordRow(record: record) {
                            delete(record)
                        }
                    }
                }
            }
        }
        .navigationTitle("Developer Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refreshDiagnostics)
    }

    private func refreshDiagnostics() {
        isScanning = true
        deleteError = nil
        var statusParts: [String] = []

        do {
            issues = try scanner.scan(in: context)
            statusParts.append(issues.isEmpty ? "No cross-store graph issues found." : "Found \(issues.count) possible corrupted graph issue(s).")
        } catch {
            issues = []
            statusParts.append("Issue scan failed: \(error.localizedDescription)")
        }

        do {
            rawTVShowRecords = try scanner.rawTVShowRecords(in: context)
            statusParts.append("Raw TVShow records: \(rawTVShowRecords.count).")
        } catch {
            rawTVShowRecords = []
            statusParts.append("Raw TVShow scan failed: \(error.localizedDescription)")
        }

        statusMessage = statusParts.joined(separator: " ")
        isScanning = false
    }

    private func delete(_ issue: CloudKitStoreDiagnosticIssue) {
        deleteError = nil
        print("🧪 [CloudKitStoreDiagnostics] About to delete local DEBUG record entity=\(issue.entityName) title=\(issue.displayName) objectID=\(issue.objectIDURI) store=\(issue.primaryStoreLabel)")

        guard issue.canDeletePrimaryObject else {
            deleteError = "Deletion is disabled for \(issue.entityName). Household and HouseholdMember are never deleted by this tool."
            print("🧪 [CloudKitStoreDiagnostics] Refused deletion entity=\(issue.entityName) objectID=\(issue.objectIDURI)")
            return
        }

        guard let uri = URL(string: issue.objectIDURI),
              let objectID = context.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: uri) else {
            deleteError = "Could not resolve objectID for \(issue.objectIDURI). Refresh diagnostics and try again."
            print("🧪 [CloudKitStoreDiagnostics] Could not resolve objectID URI=\(issue.objectIDURI)")
            return
        }

        do {
            let object = try context.existingObject(with: objectID)
            let entityName = object.entity.name ?? "<unknown>"
            guard entityName == issue.entityName else {
                throw NSError(
                    domain: "CloudKitStoreDiagnostics",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Resolved object entity \(entityName) did not match expected \(issue.entityName)."]
                )
            }
            guard CloudKitStoreDiagnosticScanner.isDeletionAllowed(for: entityName) else {
                throw NSError(
                    domain: "CloudKitStoreDiagnostics",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Deletion is disabled for \(entityName)."]
                )
            }

            context.delete(object)
            try context.save()
            print("🧪 [CloudKitStoreDiagnostics] Deleted local DEBUG record entity=\(issue.entityName) title=\(issue.displayName) objectID=\(issue.objectIDURI)")
            refreshDiagnostics()
            statusMessage = "Deleted local \(issue.entityName): \(issue.displayName). Diagnostics refreshed."
        } catch {
            context.rollback()
            deleteError = "Delete failed: \(error.localizedDescription)"
            print("🧪 [CloudKitStoreDiagnostics] Delete failed entity=\(issue.entityName) title=\(issue.displayName) objectID=\(issue.objectIDURI) error=\(error.localizedDescription)")
        }
    }

    private func delete(_ record: CloudKitStoreDiagnosticTVShowRecord) {
        deleteError = nil
        print("🧪 [CloudKitStoreDiagnostics] About to delete raw TVShow title=\(record.title) objectID=\(record.objectIDURI) store=\(record.tvShowStoreLabel)")

        guard let uri = URL(string: record.objectIDURI),
              let objectID = context.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: uri) else {
            deleteError = "Could not resolve TVShow objectID for \(record.objectIDURI). Refresh diagnostics and try again."
            print("🧪 [CloudKitStoreDiagnostics] Could not resolve raw TVShow URI=\(record.objectIDURI)")
            return
        }

        do {
            let object = try context.existingObject(with: objectID)
            let entityName = object.entity.name ?? "<unknown>"
            guard entityName == "TVShow" else {
                throw NSError(
                    domain: "CloudKitStoreDiagnostics",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Resolved object entity \(entityName) did not match expected TVShow."]
                )
            }

            context.delete(object)
            try context.save()
            print("🧪 [CloudKitStoreDiagnostics] Deleted raw TVShow title=\(record.title) objectID=\(record.objectIDURI)")
            refreshDiagnostics()
            statusMessage = "Deleted TVShow: \(record.title). Diagnostics refreshed."
        } catch {
            context.rollback()
            deleteError = "Delete TVShow failed: \(error.localizedDescription)"
            print("🧪 [CloudKitStoreDiagnostics] Delete raw TVShow failed title=\(record.title) objectID=\(record.objectIDURI) error=\(error.localizedDescription)")
        }
    }
}

private struct CloudKitStoreDiagnosticTVShowRecordRow: View {
    let record: CloudKitStoreDiagnosticTVShowRecord
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.title)
                        .font(.headline)
                    Text("Year: \(record.yearText)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(record.sameStoreText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(record.isTVShowInSameStoreAsHousehold ? Color.green : Color.orange)
            }

            LabeledContent("Object ID") {
                Text(record.objectIDURI)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
            }

            LabeledContent("Household") {
                Text(record.householdName)
                    .font(.caption)
            }

            LabeledContent("Household ID") {
                Text(record.householdIDText)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("TVShow store/scope: \(record.tvShowStoreLabel)")
                Text("Household store/scope: \(record.householdStoreLabel)")
                Text("TVShow.store == household.store: \(record.sameStoreText)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Button(role: .destructive, action: onDelete) {
                Label("Delete This TVShow Only", systemImage: "trash")
            }
        }
        .padding(.vertical, 6)
    }
}

private struct CloudKitStoreDiagnosticIssueRow: View {
    let issue: CloudKitStoreDiagnosticIssue
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(issue.displayEntityName)
                        .font(.headline)
                    Text(issue.displayName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(issue.primaryStoreLabel)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.thinMaterial, in: Capsule())
            }

            LabeledContent("Object ID") {
                Text(issue.objectIDURI)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
            }

            if let details = issue.viewingDetails {
                Text(details)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Related objects")
                    .font(.caption.weight(.semibold))
                ForEach(issue.relatedObjects) { relatedObject in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(relatedObject.relationshipPath): \(relatedObject.entityName) — \(relatedObject.displayName)")
                        Text("store: \(relatedObject.storeLabel)")
                            .foregroundStyle(.secondary)
                        Text(relatedObject.objectIDURI)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .font(.caption)
                }
            }

            Text(issue.suggestedAction)
                .font(.footnote)
                .foregroundStyle(.orange)

            Button(role: .destructive, action: onDelete) {
                Label("Delete Local Corrupted Record", systemImage: "trash")
            }
            .disabled(!issue.canDeletePrimaryObject)
        }
        .padding(.vertical, 6)
    }
}

struct CloudKitStoreDiagnosticIssue: Identifiable {
    let id: String
    let entityName: String
    var displayEntityName: String { entityName == "LLQuote" ? "Quote" : entityName }
    let displayName: String
    let objectIDURI: String
    let primaryStoreLabel: String
    let relatedObjects: [CloudKitStoreDiagnosticRelatedObject]
    let suggestedAction: String
    let canDeletePrimaryObject: Bool
    let viewingDetails: String?
}

struct CloudKitStoreDiagnosticRelatedObject: Identifiable {
    let id: String
    let relationshipPath: String
    let entityName: String
    let displayName: String
    let objectIDURI: String
    let storeLabel: String
}

struct CloudKitStoreDiagnosticTVShowRecord: Identifiable {
    let id: String
    let title: String
    let yearText: String
    let objectIDURI: String
    let householdName: String
    let householdIDText: String
    let tvShowStoreLabel: String
    let householdStoreLabel: String
    let isTVShowInSameStoreAsHousehold: Bool

    var sameStoreText: String {
        isTVShowInSameStoreAsHousehold ? "true" : "false"
    }
}

struct CloudKitStoreDiagnosticScanner {
    private struct EntityPlan {
        let entityName: String
        let relationshipNames: [String]
    }

    private static let entityPlans: [EntityPlan] = [
        EntityPlan(entityName: "Viewing", relationshipNames: ["movie", "household"]),
        EntityPlan(entityName: "Movie", relationshipNames: ["household", "viewing", "viewings", "feedbacks", "feedback"]),
        EntityPlan(entityName: "MovieFeedback", relationshipNames: ["movie", "household", "member"]),
        EntityPlan(entityName: "TVShow", relationshipNames: ["household"]),
        EntityPlan(entityName: "BookEntry", relationshipNames: ["household", "ownerMember", "member", "ownerAppUser", "appUser"]),
        EntityPlan(entityName: "LLQuote", relationshipNames: ["household", "child", "member"]),
        EntityPlan(entityName: "Household", relationshipNames: ["members", "memberships", "movies", "viewings", "feedbacks", "tvshows", "bookEntries", "quotes"]),
        EntityPlan(entityName: "HouseholdMember", relationshipNames: ["household", "memberships", "feedbacks", "bookEntries"]),
        EntityPlan(entityName: "HouseholdMembership", relationshipNames: ["household", "memberProfile", "householdMember", "appUser"])
    ]

    func scan(in context: NSManagedObjectContext) throws -> [CloudKitStoreDiagnosticIssue] {
        var issues: [CloudKitStoreDiagnosticIssue] = []

        for plan in Self.entityPlans where context.persistentStoreCoordinator?.managedObjectModel.entitiesByName[plan.entityName] != nil {
            let request = NSFetchRequest<NSManagedObject>(entityName: plan.entityName)
            request.includesPendingChanges = false
            request.returnsObjectsAsFaults = false
            let objects = try context.fetch(request)

            for object in objects {
                if let issue = issue(for: object, plan: plan) {
                    issues.append(issue)
                    print("🧪 [CloudKitStoreDiagnostics] Detected cross-store graph entity=\(issue.entityName) title=\(issue.displayName) objectID=\(issue.objectIDURI) primaryStore=\(issue.primaryStoreLabel)")
                    for related in issue.relatedObjects {
                        print("🧪 [CloudKitStoreDiagnostics]   related \(related.relationshipPath)=\(related.entityName) title=\(related.displayName) objectID=\(related.objectIDURI) store=\(related.storeLabel)")
                    }
                }
            }
        }

        return issues.sorted { lhs, rhs in
            if lhs.entityName == rhs.entityName { return lhs.displayName < rhs.displayName }
            return lhs.entityName < rhs.entityName
        }
    }

    func rawTVShowRecords(in context: NSManagedObjectContext) throws -> [CloudKitStoreDiagnosticTVShowRecord] {
        guard context.persistentStoreCoordinator?.managedObjectModel.entitiesByName["TVShow"] != nil else { return [] }

        let request = NSFetchRequest<NSManagedObject>(entityName: "TVShow")
        request.includesPendingChanges = false
        request.returnsObjectsAsFaults = false
        let tvShows = try context.fetch(request)

        return tvShows.map { tvShow in
            let household = tvShow.value(forUsableRelationship: "household") as? NSManagedObject
            let tvShowStore = tvShow.objectID.persistentStore
            let householdStore = household?.objectID.persistentStore
            let storesMatch = tvShowStore != nil && tvShowStore === householdStore
            let title = Self.displayName(for: tvShow)
            let yearNumber = tvShow.value(forKeyIfPresent: "year") as? NSNumber
            let year = yearNumber?.intValue ?? 0
            let householdID = tvShow.value(forKeyIfPresent: "householdID") as? UUID

            let record = CloudKitStoreDiagnosticTVShowRecord(
                id: tvShow.objectID.uriRepresentation().absoluteString,
                title: title,
                yearText: year > 0 ? String(year) : "<none>",
                objectIDURI: tvShow.objectID.uriRepresentation().absoluteString,
                householdName: household.map(Self.displayName(for:)) ?? "<nil>",
                householdIDText: householdID?.uuidString ?? "<nil>",
                tvShowStoreLabel: storeLabel(for: tvShowStore),
                householdStoreLabel: storeLabel(for: householdStore),
                isTVShowInSameStoreAsHousehold: storesMatch
            )

            print("🧪 [CloudKitStoreDiagnostics] Raw TVShow title=\(record.title) year=\(record.yearText) objectID=\(record.objectIDURI) household=\(record.householdName) householdID=\(record.householdIDText) tvShowStore=\(record.tvShowStoreLabel) householdStore=\(record.householdStoreLabel) sameStore=\(record.sameStoreText)")
            return record
        }
        .sorted { lhs, rhs in
            if lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedSame {
                return lhs.objectIDURI < rhs.objectIDURI
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private func issue(for object: NSManagedObject, plan: EntityPlan) -> CloudKitStoreDiagnosticIssue? {
        let primaryStore = object.objectID.persistentStore
        let primaryStoreLabel = storeLabel(for: primaryStore)
        var relatedObjects = relatedObjects(for: object, plan: plan)

        if plan.entityName == "Viewing", let movie = object.value(forUsableRelationship: "movie") as? NSManagedObject {
            relatedObjects.append(contentsOf: relatedObjects(for: movie, relationshipNames: ["household"], prefix: "movie"))
        }

        let mismatches = relatedObjects.filter { $0.store !== primaryStore }
        guard !mismatches.isEmpty else { return nil }

        let entityName = object.entity.name ?? plan.entityName
        let displayName = Self.displayName(for: object)
        let issueRelatedObjects = [diagnosticObject(for: object, relationshipPath: entityName.lowercased())] + relatedObjects.map(diagnosticObject)
        let viewingDetails = viewingDetails(for: object, entityName: entityName)
        let canDelete = Self.isDeletionAllowed(for: entityName)

        return CloudKitStoreDiagnosticIssue(
            id: object.objectID.uriRepresentation().absoluteString,
            entityName: entityName,
            displayName: displayName,
            objectIDURI: object.objectID.uriRepresentation().absoluteString,
            primaryStoreLabel: primaryStoreLabel,
            relatedObjects: issueRelatedObjects,
            suggestedAction: suggestedAction(for: entityName, canDelete: canDelete),
            canDeletePrimaryObject: canDelete,
            viewingDetails: viewingDetails
        )
    }

    private func relatedObjects(for object: NSManagedObject, plan: EntityPlan) -> [RelatedObject] {
        relatedObjects(for: object, relationshipNames: plan.relationshipNames, prefix: nil)
    }

    private func relatedObjects(for object: NSManagedObject, relationshipNames: [String], prefix: String?) -> [RelatedObject] {
        var results: [RelatedObject] = []
        for relationshipName in relationshipNames where object.entity.relationshipsByName[relationshipName] != nil {
            let path = [prefix, relationshipName].compactMap { $0 }.joined(separator: ".")
            if let relatedObject = object.value(forUsableRelationship: relationshipName) as? NSManagedObject {
                results.append(RelatedObject(path: path, object: relatedObject))
            } else if let relatedSet = object.value(forUsableRelationship: relationshipName) as? Set<NSManagedObject> {
                results.append(contentsOf: relatedSet.map { RelatedObject(path: path, object: $0) })
            } else if let relatedSet = object.value(forUsableRelationship: relationshipName) as? NSSet {
                for case let relatedObject as NSManagedObject in relatedSet {
                    results.append(RelatedObject(path: path, object: relatedObject))
                }
            }
        }
        return results
    }

    private func diagnosticObject(for relatedObject: RelatedObject) -> CloudKitStoreDiagnosticRelatedObject {
        diagnosticObject(for: relatedObject.object, relationshipPath: relatedObject.path)
    }

    private func diagnosticObject(for object: NSManagedObject, relationshipPath: String) -> CloudKitStoreDiagnosticRelatedObject {
        CloudKitStoreDiagnosticRelatedObject(
            id: "\(relationshipPath)-\(object.objectID.uriRepresentation().absoluteString)",
            relationshipPath: relationshipPath,
            entityName: object.entity.name ?? "<unknown>",
            displayName: Self.displayName(for: object),
            objectIDURI: object.objectID.uriRepresentation().absoluteString,
            storeLabel: storeLabel(for: object.objectID.persistentStore)
        )
    }

    private func storeLabel(for store: NSPersistentStore?) -> String {
        guard let store else { return "unknown store" }
        let filename = store.url?.lastPathComponent ?? "<no url>"
        let scope = filename.localizedCaseInsensitiveContains("shared") ? "shared" : "private"
        return "\(scope) (\(filename))"
    }

    private func viewingDetails(for object: NSManagedObject, entityName: String) -> String? {
        guard entityName == "Viewing" else { return nil }
        let movie = object.value(forUsableRelationship: "movie") as? NSManagedObject
        let household = object.value(forUsableRelationship: "household") as? NSManagedObject
        let movieTitle = movie.map(Self.displayName(for:)) ?? "No movie"
        let householdName = household.map(Self.displayName(for:)) ?? "No household"
        let movieHousehold = (movie?.value(forUsableRelationship: "household") as? NSManagedObject).map(Self.displayName(for:)) ?? "No movie household"
        return "Viewing movie: \(movieTitle). Viewing household: \(householdName). Movie household: \(movieHousehold)."
    }

    private func suggestedAction(for entityName: String, canDelete: Bool) -> String {
        if !canDelete {
            return "Inspect this record and delete a safer child record instead. This tool will not delete Household or HouseholdMember automatically."
        }
        switch entityName {
        case "Viewing", "MovieFeedback":
            return "Preferred DEBUG cleanup: delete this child record only, then relaunch and verify Code=134060 stays gone."
        case "Movie":
            return "Delete this Movie only if the Movie itself is the corrupted local test record. If a Viewing or MovieFeedback is listed separately, delete that child first."
        default:
            return "DEBUG cleanup: delete only this selected local test record if you confirm it is the corrupted record."
        }
    }

    static func isDeletionAllowed(for entityName: String) -> Bool {
        entityName != "Household" && entityName != "HouseholdMember"
    }

    static func displayName(for object: NSManagedObject) -> String {
        for key in ["title", "name", "displayName", "speakerName", "text", "providerSubject", "inviteCode"] where object.entity.attributesByName[key] != nil {
            if let value = object.value(forKey: key) as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }

        if object.entity.name == "Viewing" {
            let movie = object.value(forUsableRelationship: "movie") as? NSManagedObject
            let household = object.value(forUsableRelationship: "household") as? NSManagedObject
            let movieTitle = movie.map(displayName(for:)) ?? "Unknown movie"
            let householdName = household.map(displayName(for:)) ?? "Unknown household"
            return "\(movieTitle) / \(householdName)"
        }

        if let id = object.value(forKeyIfPresent: "id") as? UUID {
            return id.uuidString
        }

        return object.objectID.uriRepresentation().lastPathComponent
    }

    private struct RelatedObject {
        let path: String
        let object: NSManagedObject

        var store: NSPersistentStore? { object.objectID.persistentStore }
    }
}

private extension NSManagedObject {
    func value(forUsableRelationship relationshipName: String) -> Any? {
        guard entity.relationshipsByName[relationshipName] != nil else { return nil }
        return value(forKey: relationshipName)
    }

    func value(forKeyIfPresent key: String) -> Any? {
        guard entity.attributesByName[key] != nil || entity.relationshipsByName[key] != nil else { return nil }
        return value(forKey: key)
    }
}
#endif
