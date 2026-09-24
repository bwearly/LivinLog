//
//  SyncRecordMapping.swift
//  Livin Log
//
//  Phase 1 (CKSyncEngine migration).
//
//  CKRecord <-> NSManagedObject field mapping for the five entities Movie depends on
//  (Movie, Household, HouseholdMember, MovieFeedback, Viewing). Cross-entity links (e.g.
//  Movie.household) become scalar `<Thing>RecordName` string fields on the CKRecord, per the
//  Phase 1 plan -- CloudKit record references aren't used here since these records don't share
//  a single root/parent the way a CKReference implies.
//
//  Ground truth for every CKSyncEngine/CKRecord API used here is SyncSpike/SyncController.swift
//  and SyncSpike/SpikeItem.swift (Phase 0), themselves grounded against Apple's own
//  apple/sample-cloudkit-sync-engine sample and live CloudKit docs fetched during that phase.

import CloudKit
import CoreData

enum SyncRecordMapping {

    enum RecordType {
        static let household = "Household"
        static let member = "HouseholdMember"
        static let movie = "Movie"
        static let feedback = "MovieFeedback"
        static let viewing = "Viewing"
        static let tvShow = "TVShow"
        static let book = "BookEntry"
        static let quote = "LLQuote"
        static let puzzle = "LLPuzzle"
        static let calendarEvent = "LLCalendarEvent"
        static let recipeCategory = "RecipeCategory"
        static let recipe = "Recipe"
        static let recipeIngredient = "RecipeIngredient"
        static let recipeStep = "RecipeStep"
        static let recipePhoto = "RecipePhoto"
    }

    // MARK: - Synced entity registry (single source of truth)

    /// One synced Core Data entity. Everything that used to be a separate hand-kept list --
    /// OutboundChangeTracker's tracked entities + mapped properties, SyncController's
    /// record-type -> entity-name lookup, InboundChangeApplier's deletion search, and the
    /// entity-agnostic `makeRecord(forRecordName:)` search -- now derives from `entities` below.
    /// The per-entity `makeRecord(for:)` / `apply(_:to:...)` functions stay typed.
    struct EntitySpec: Sendable {
        let entityName: String
        let recordType: CKRecord.RecordType
        /// Core Data properties whose change means the CKRecord must be re-sent: every
        /// attribute `makeRecord(for:)` writes, plus the entity's forward to-one relationships
        /// that feed a `...RecordName` field. Deliberately excludes to-many *inverse*
        /// relationships (e.g. Household.movies) -- see OutboundChangeTracker.processNewChanges.
        let syncedProperties: Set<String>
    }

    /// Ordered parents-before-children. That order is also the search order for
    /// `makeRecord(forRecordName:)` and inbound deletions, matching the lists this replaced.
    static let entities: [EntitySpec] = [
        EntitySpec(
            entityName: "Household",
            recordType: RecordType.household,
            syncedProperties: ["name", "createdByAppUserId", "createdAt"]
        ),
        EntitySpec(
            entityName: "HouseholdMember",
            recordType: RecordType.member,
            syncedProperties: ["displayName", "claimedByAppUserId", "isActive", "createdAt", "household", "avatar", "linkedUserRecordName", "role", "hasOwnIPhone", "invitedAt", "inviteParticipantID", "birthday"]
        ),
        EntitySpec(
            entityName: "Movie",
            recordType: RecordType.movie,
            syncedProperties: ["title", "genre", "imdbID", "mediaType", "mpaaRating", "notes", "posterURL", "year", "createdAt", "household"]
        ),
        EntitySpec(
            entityName: "TVShow",
            recordType: RecordType.tvShow,
            syncedProperties: ["title", "year", "seasons", "mediaType", "imdbID", "posterURL", "ratingText", "rewatch", "notes", "createdAt", "household"]
        ),
        EntitySpec(
            entityName: "BookEntry",
            recordType: RecordType.book,
            syncedProperties: ["title", "author", "rating", "notes", "spiceLevel", "bookLength", "createdAt", "finishedAt", "coverURL", "coverID", "isbn", "firstPublishYear", "household", "ownerMember"]
        ),
        // LLQuote: `ageInMonthsAtSaidAt` is deliberately NOT synced (age is computed at read
        // time from member.birthday), nor is the retired `child` link.
        EntitySpec(
            entityName: "LLQuote",
            recordType: RecordType.quote,
            syncedProperties: ["text", "speakerName", "contextText", "saidAt", "createdAt", "updatedAt", "household", "member"]
        ),
        EntitySpec(
            entityName: "LLPuzzle",
            recordType: RecordType.puzzle,
            syncedProperties: ["name", "brand", "notes", "pieceCount", "completedAt", "photoData", "createdAt", "updatedAt", "household"]
        ),
        // LLCalendarEvent: `notificationsEnabledForEvent` is a per-device preference, kept local.
        EntitySpec(
            entityName: "LLCalendarEvent",
            recordType: RecordType.calendarEvent,
            syncedProperties: ["name", "tag", "day", "month", "year", "createdAt", "updatedAt", "household"]
        ),
        EntitySpec(
            entityName: "RecipeCategory",
            recordType: RecordType.recipeCategory,
            syncedProperties: ["name", "household"]
        ),
        // Recipe: `categories` is a to-many but it's the recipe's own field here -- it feeds the
        // record's `categoryRecordNames` list (the many-to-many mapping), so it must trigger a
        // resend. The inverse RecipeCategory.recipes is deliberately not synced.
        EntitySpec(
            entityName: "Recipe",
            recordType: RecordType.recipe,
            syncedProperties: ["title", "servings", "authorSource", "notes", "createdAt", "updatedAt", "household", "categories"]
        ),
        EntitySpec(
            entityName: "RecipeIngredient",
            recordType: RecordType.recipeIngredient,
            syncedProperties: ["name", "amount", "unit", "position", "recipe"]
        ),
        EntitySpec(
            entityName: "RecipeStep",
            recordType: RecordType.recipeStep,
            syncedProperties: ["text", "sectionTitle", "position", "recipe"]
        ),
        EntitySpec(
            entityName: "RecipePhoto",
            recordType: RecordType.recipePhoto,
            syncedProperties: ["photoData", "position", "recipe"]
        ),
        EntitySpec(
            entityName: "MovieFeedback",
            recordType: RecordType.feedback,
            syncedProperties: ["rating", "slept", "notes", "updatedAt", "household", "member", "movie"]
        ),
        EntitySpec(
            entityName: "Viewing",
            recordType: RecordType.viewing,
            syncedProperties: ["isRewatch", "notes", "watchedOn", "household", "movie"]
        ),
    ]

    static let syncedEntityNames: Set<String> = Set(entities.map(\.entityName))

    static func spec(forEntityName entityName: String) -> EntitySpec? {
        entities.first { $0.entityName == entityName }
    }

    static func spec(forRecordType recordType: CKRecord.RecordType) -> EntitySpec? {
        entities.first { $0.recordType == recordType }
    }

#if DEBUG
    /// DEBUG-only guard against the registry drifting from the Core Data model (a typo'd
    /// property name would otherwise silently stop that field's edits from syncing). Logs,
    /// never crashes. Called once from SyncController.init.
    static func validateRegistry(against model: NSManagedObjectModel) {
        for spec in entities {
            guard let entity = model.entitiesByName[spec.entityName] else {
                SyncLogger.error(SyncLogger.engine, "registry: entity \(spec.entityName) not in model")
                continue
            }
            let missing = spec.syncedProperties.subtracting(entity.propertiesByName.keys)
            if !missing.isEmpty {
                SyncLogger.error(SyncLogger.engine, "registry: \(spec.entityName) syncedProperties not in model: \(missing.sorted())")
            }
            if entity.propertiesByName["recordName"] == nil || entity.propertiesByName["ckSystemFields"] == nil {
                SyncLogger.error(SyncLogger.engine, "registry: \(spec.entityName) is missing recordName/ckSystemFields")
            }
        }
    }
#endif

    static func zoneID(householdID: UUID) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: "Household-\(householdID.uuidString)", ownerName: CKCurrentUserDefaultName)
    }

    /// The authoritative zone for a household: prefers the zoneID embedded in its own
    /// ckSystemFields (the real CloudKit identity) over recomputing from `household.id`, so the
    /// two can never diverge even if `id` is ever wrong locally (e.g. regenerated by
    /// awakeFromInsert on an inbound-created row before an `id` field existed on the server
    /// record). Falls back to computing from `id` only for a brand-new household that hasn't
    /// synced at all yet (ckSystemFields nil).
    static func zoneID(for household: Household) -> CKRecordZone.ID? {
        if let data = household.ckSystemFields, let record = recordFromSystemFields(data) {
            return record.recordID.zoneID
        }
        guard let id = household.id else { return nil }
        return zoneID(householdID: id)
    }

    /// Looks up the locally-synced Household whose CloudKit zone matches `zoneID`. Used both by
    /// SyncController's shared-zone-loss handling (background context) and by AppState's
    /// joining-household poll (view context) -- takes the context explicitly rather than
    /// picking one itself so both call sites can share this one lookup.
    static func household(matchingZoneID zoneID: CKRecordZone.ID, context: NSManagedObjectContext) -> Household? {
        let request = NSFetchRequest<Household>(entityName: "Household")
        let households = (try? context.fetch(request)) ?? []
        return households.first { Self.zoneID(for: $0) == zoneID }
    }

    /// Parses a CKRecord's "id" string field back into a UUID. Returns nil (never a sentinel
    /// value) when the field is missing or unparseable -- callers must leave the local value
    /// untouched in that case, not clear it. Records written before this field existed have no
    /// "id" at all.
    private static func parsedID(from record: CKRecord) -> UUID? {
        (record["id"] as? String).flatMap(UUID.init(uuidString:))
    }

    // MARK: - System fields (change tag) round-trip

    static func encodeSystemFields(_ record: CKRecord) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        return archiver.encodedData
    }

    static func recordFromSystemFields(_ data: Data) -> CKRecord? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = true
        return CKRecord(coder: unarchiver)
    }

    private static func baseRecord(recordType: String, recordName: String, zoneID: CKRecordZone.ID, existingSystemFields: Data?) -> CKRecord {
        if let data = existingSystemFields, let record = recordFromSystemFields(data) {
            return record
        }
        return CKRecord(recordType: recordType, recordID: CKRecord.ID(recordName: recordName, zoneID: zoneID))
    }

    // MARK: - Household

    static func makeRecord(for household: Household) -> CKRecord? {
        guard let recordName = household.recordName, let zoneID = zoneID(for: household) else { return nil }
        let record = baseRecord(recordType: RecordType.household, recordName: recordName, zoneID: zoneID, existingSystemFields: household.ckSystemFields)
        record["name"] = household.name
        record["createdByAppUserId"] = household.value(forKey: "createdByAppUserId") as? String
        record["createdAt"] = household.createdAt
        record["id"] = household.id?.uuidString
        return record
    }

    static func apply(_ record: CKRecord, to household: Household) {
        household.recordName = record.recordID.recordName
        household.name = record["name"] as? String
        household.setValue(record["createdByAppUserId"] as? String, forKey: "createdByAppUserId")
        household.createdAt = record["createdAt"] as? Date
        household.ckSystemFields = encodeSystemFields(record)
        if let parsedID = parsedID(from: record) { household.id = parsedID }
    }

    // MARK: - HouseholdMember

    static func makeRecord(for member: HouseholdMember) -> CKRecord? {
        guard let household = member.household, let zoneID = zoneID(for: household), let recordName = member.recordName else { return nil }
        let record = baseRecord(recordType: RecordType.member, recordName: recordName, zoneID: zoneID, existingSystemFields: member.ckSystemFields)
        record["displayName"] = member.displayName
        record["claimedByAppUserId"] = member.value(forKey: "claimedByAppUserId") as? String
        record["isActive"] = member.isActive
        record["createdAt"] = member.createdAt
        record["householdRecordName"] = household.recordName
        record["avatar"] = member.value(forKey: "avatar") as? String
        record["linkedUserRecordName"] = member.value(forKey: "linkedUserRecordName") as? String
        record["role"] = member.value(forKey: "role") as? String
        record["hasOwnIPhone"] = member.value(forKey: "hasOwnIPhone") as? Bool
        record["invitedAt"] = member.value(forKey: "invitedAt") as? Date
        record["inviteParticipantID"] = member.value(forKey: "inviteParticipantID") as? String
        record["birthday"] = member.value(forKey: "birthday") as? Date
        record["id"] = member.id?.uuidString
        return record
    }

    static func apply(_ record: CKRecord, to member: HouseholdMember, household: Household?) {
        member.recordName = record.recordID.recordName
        member.displayName = record["displayName"] as? String
        member.setValue(record["claimedByAppUserId"] as? String, forKey: "claimedByAppUserId")
        member.isActive = (record["isActive"] as? Bool) ?? true
        member.createdAt = record["createdAt"] as? Date
        member.setValue(record["avatar"] as? String, forKey: "avatar")
        member.setValue(record["linkedUserRecordName"] as? String, forKey: "linkedUserRecordName")
        member.setValue(record["role"] as? String, forKey: "role")
        member.setValue((record["hasOwnIPhone"] as? Bool) ?? false, forKey: "hasOwnIPhone")
        member.setValue(record["invitedAt"] as? Date, forKey: "invitedAt")
        member.setValue(record["inviteParticipantID"] as? String, forKey: "inviteParticipantID")
        member.setValue(record["birthday"] as? Date, forKey: "birthday")
        member.ckSystemFields = encodeSystemFields(record)
        if let parsedID = parsedID(from: record) { member.id = parsedID }
        // Persisted unconditionally (even when `household` is nil) so a later inbound batch can
        // retry the link -- see InboundChangeApplier.retryUnresolvedLinks().
        member.householdRecordName = record["householdRecordName"] as? String
        if let household {
            member.household = household
            member.setValue(household.id, forKey: "householdId")
        }
    }

    // MARK: - Movie

    static func makeRecord(for movie: Movie) -> CKRecord? {
        guard let household = movie.household, let zoneID = zoneID(for: household), let recordName = movie.recordName else { return nil }
        let record = baseRecord(recordType: RecordType.movie, recordName: recordName, zoneID: zoneID, existingSystemFields: movie.ckSystemFields)
        record["title"] = movie.title
        record["genre"] = movie.genre
        record["imdbID"] = movie.imdbID
        record["mediaType"] = movie.mediaType
        record["mpaaRating"] = movie.mpaaRating
        record["notes"] = movie.notes
        record["posterURL"] = movie.posterURL
        record["year"] = Int(movie.year)
        record["createdAt"] = movie.createdAt
        record["householdRecordName"] = household.recordName
        record["id"] = movie.id?.uuidString
        return record
    }

    static func apply(_ record: CKRecord, to movie: Movie, household: Household?) {
        movie.recordName = record.recordID.recordName
        movie.title = record["title"] as? String
        movie.genre = record["genre"] as? String
        movie.imdbID = record["imdbID"] as? String
        movie.mediaType = record["mediaType"] as? String
        movie.mpaaRating = record["mpaaRating"] as? String
        movie.notes = record["notes"] as? String
        movie.posterURL = record["posterURL"] as? String
        movie.year = Int16((record["year"] as? Int) ?? 0)
        movie.createdAt = record["createdAt"] as? Date
        movie.ckSystemFields = encodeSystemFields(record)
        if let parsedID = parsedID(from: record) { movie.id = parsedID }
        movie.householdRecordName = record["householdRecordName"] as? String
        if let household {
            movie.household = household
            movie.householdID = household.id
        }
    }

    // MARK: - MovieFeedback

    static func makeRecord(for feedback: MovieFeedback) -> CKRecord? {
        guard let household = feedback.household, let zoneID = zoneID(for: household), let recordName = feedback.recordName else { return nil }
        let record = baseRecord(recordType: RecordType.feedback, recordName: recordName, zoneID: zoneID, existingSystemFields: feedback.ckSystemFields)
        record["rating"] = feedback.rating
        record["slept"] = feedback.slept
        record["notes"] = feedback.notes
        record["updatedAt"] = feedback.updatedAt
        record["householdRecordName"] = household.recordName
        record["memberRecordName"] = feedback.member?.recordName
        record["movieRecordName"] = feedback.movie?.recordName
        record["id"] = feedback.id?.uuidString
        return record
    }

    static func apply(_ record: CKRecord, to feedback: MovieFeedback, household: Household?, member: HouseholdMember?, movie: Movie?) {
        feedback.recordName = record.recordID.recordName
        feedback.rating = (record["rating"] as? Double) ?? 0
        feedback.slept = (record["slept"] as? Bool) ?? false
        feedback.notes = record["notes"] as? String
        feedback.updatedAt = record["updatedAt"] as? Date
        feedback.ckSystemFields = encodeSystemFields(record)
        if let parsedID = parsedID(from: record) { feedback.id = parsedID }
        feedback.householdRecordName = record["householdRecordName"] as? String
        feedback.memberRecordName = record["memberRecordName"] as? String
        feedback.movieRecordName = record["movieRecordName"] as? String
        if let household { feedback.household = household }
        if let member { feedback.member = member }
        if let movie { feedback.movie = movie }
    }

    // MARK: - Viewing

    static func makeRecord(for viewing: Viewing) -> CKRecord? {
        guard let household = viewing.household, let zoneID = zoneID(for: household), let recordName = viewing.recordName else { return nil }
        let record = baseRecord(recordType: RecordType.viewing, recordName: recordName, zoneID: zoneID, existingSystemFields: viewing.ckSystemFields)
        record["isRewatch"] = viewing.isRewatch
        record["notes"] = viewing.notes
        record["watchedOn"] = viewing.watchedOn
        record["householdRecordName"] = household.recordName
        record["movieRecordName"] = viewing.movie?.recordName
        record["id"] = viewing.id?.uuidString
        return record
    }

    static func apply(_ record: CKRecord, to viewing: Viewing, household: Household?, movie: Movie?) {
        viewing.recordName = record.recordID.recordName
        viewing.isRewatch = (record["isRewatch"] as? Bool) ?? false
        viewing.notes = record["notes"] as? String
        viewing.watchedOn = record["watchedOn"] as? Date
        viewing.ckSystemFields = encodeSystemFields(record)
        if let parsedID = parsedID(from: record) { viewing.id = parsedID }
        viewing.householdRecordName = record["householdRecordName"] as? String
        viewing.movieRecordName = record["movieRecordName"] as? String
        if let household { viewing.household = household }
        if let movie { viewing.movie = movie }
    }

    // MARK: - TVShow

    static func makeRecord(for show: TVShow) -> CKRecord? {
        guard let household = show.household, let zoneID = zoneID(for: household), let recordName = show.recordName else { return nil }
        let record = baseRecord(recordType: RecordType.tvShow, recordName: recordName, zoneID: zoneID, existingSystemFields: show.ckSystemFields)
        record["title"] = show.title
        record["year"] = Int(show.year)
        record["seasons"] = Int(show.seasons)
        record["mediaType"] = show.mediaType
        record["imdbID"] = show.imdbID
        record["posterURL"] = show.posterURL
        record["ratingText"] = show.ratingText
        // Scalar-typed in the app (`show.rewatch: Bool`), so nil and false already read the
        // same everywhere -- mapped as a plain Bool, like Viewing.isRewatch.
        record["rewatch"] = show.rewatch
        record["notes"] = show.notes
        record["createdAt"] = show.createdAt
        record["householdRecordName"] = household.recordName
        record["id"] = show.id?.uuidString
        return record
    }

    static func apply(_ record: CKRecord, to show: TVShow, household: Household?) {
        show.recordName = record.recordID.recordName
        show.title = record["title"] as? String
        show.year = Int16((record["year"] as? Int) ?? 0)
        show.seasons = Int16((record["seasons"] as? Int) ?? 0)
        show.mediaType = record["mediaType"] as? String
        show.imdbID = record["imdbID"] as? String
        show.posterURL = record["posterURL"] as? String
        show.ratingText = record["ratingText"] as? String
        show.rewatch = (record["rewatch"] as? Bool) ?? false
        show.notes = record["notes"] as? String
        show.createdAt = record["createdAt"] as? Date
        show.ckSystemFields = encodeSystemFields(record)
        if let parsedID = parsedID(from: record) { show.id = parsedID }
        show.householdRecordName = record["householdRecordName"] as? String
        if let household {
            show.household = household
            show.householdID = household.id
        }
    }

    // MARK: - BookEntry

    static func makeRecord(for book: BookEntry) -> CKRecord? {
        guard let household = book.household, let zoneID = zoneID(for: household), let recordName = book.recordName else { return nil }
        let record = baseRecord(recordType: RecordType.book, recordName: recordName, zoneID: zoneID, existingSystemFields: book.ckSystemFields)
        record["title"] = book.title
        record["author"] = book.author
        record["rating"] = book.rating
        record["notes"] = book.notes
        record["spiceLevel"] = Int(book.spiceLevel)
        record["bookLength"] = book.bookLength
        record["createdAt"] = book.createdAt
        record["finishedAt"] = book.finishedAt
        record["coverURL"] = book.value(forKey: "coverURL") as? String
        // Optional non-scalar numbers: nil stays nil (not 0) in both directions.
        record["coverID"] = book.value(forKey: "coverID") as? NSNumber
        record["isbn"] = book.value(forKey: "isbn") as? String
        record["firstPublishYear"] = book.value(forKey: "firstPublishYear") as? NSNumber
        record["householdRecordName"] = household.recordName
        record["memberRecordName"] = book.ownerMember?.recordName
        record["id"] = book.id?.uuidString
        return record
    }

    static func apply(_ record: CKRecord, to book: BookEntry, household: Household?, member: HouseholdMember?) {
        book.recordName = record.recordID.recordName
        book.title = record["title"] as? String
        book.author = record["author"] as? String
        book.rating = (record["rating"] as? Double) ?? 0
        book.notes = record["notes"] as? String
        book.spiceLevel = Int16((record["spiceLevel"] as? Int) ?? 0)
        book.bookLength = record["bookLength"] as? String
        book.createdAt = record["createdAt"] as? Date
        book.finishedAt = record["finishedAt"] as? Date
        book.setValue(record["coverURL"] as? String, forKey: "coverURL")
        book.setValue(record["coverID"] as? NSNumber, forKey: "coverID")
        book.setValue(record["isbn"] as? String, forKey: "isbn")
        book.setValue(record["firstPublishYear"] as? NSNumber, forKey: "firstPublishYear")
        book.ckSystemFields = encodeSystemFields(record)
        if let parsedID = parsedID(from: record) { book.id = parsedID }
        book.householdRecordName = record["householdRecordName"] as? String
        book.memberRecordName = record["memberRecordName"] as? String
        if let household {
            book.household = household
            book.setValue(household.id, forKey: "householdId")
        }
        if let member {
            book.ownerMember = member
            book.setValue(member.id, forKey: "ownerMemberId")
        }
    }

    // MARK: - LLQuote

    static func makeRecord(for quote: LLQuote) -> CKRecord? {
        guard let household = quote.household, let zoneID = zoneID(for: household), let recordName = quote.recordName else { return nil }
        let record = baseRecord(recordType: RecordType.quote, recordName: recordName, zoneID: zoneID, existingSystemFields: quote.ckSystemFields)
        record["text"] = quote.text
        record["speakerName"] = quote.speakerName
        record["contextText"] = quote.contextText
        record["saidAt"] = quote.saidAt
        record["createdAt"] = quote.createdAt
        record["updatedAt"] = quote.updatedAt
        record["householdRecordName"] = household.recordName
        record["memberRecordName"] = quote.member?.recordName
        record["id"] = quote.id?.uuidString
        return record
    }

    static func apply(_ record: CKRecord, to quote: LLQuote, household: Household?, member: HouseholdMember?) {
        quote.recordName = record.recordID.recordName
        quote.text = record["text"] as? String
        quote.speakerName = record["speakerName"] as? String
        quote.contextText = record["contextText"] as? String
        quote.saidAt = record["saidAt"] as? Date
        quote.createdAt = record["createdAt"] as? Date
        quote.updatedAt = record["updatedAt"] as? Date
        quote.ckSystemFields = encodeSystemFields(record)
        if let parsedID = parsedID(from: record) { quote.id = parsedID }
        quote.householdRecordName = record["householdRecordName"] as? String
        if let household {
            quote.household = household
            quote.setValue(household.id, forKey: "householdId")
        }
        // Unlike MovieFeedback's member, a quote's speaker can change from a member to
        // "Someone else" (no memberRecordName) or to a different member, so the link is always
        // replaced: nil when there's no member, or when the target hasn't arrived yet (link
        // retry fills it in from memberRecordName later).
        let memberRecordName = record["memberRecordName"] as? String
        quote.memberRecordName = memberRecordName
        quote.member = memberRecordName == nil ? nil : member
    }

    // MARK: - LLPuzzle

    static func makeRecord(for puzzle: LLPuzzle) -> CKRecord? {
        guard let household = puzzle.household, let zoneID = zoneID(for: household), let recordName = puzzle.recordName else { return nil }
        let record = baseRecord(recordType: RecordType.puzzle, recordName: recordName, zoneID: zoneID, existingSystemFields: puzzle.ckSystemFields)
        record["name"] = puzzle.name
        record["brand"] = puzzle.brand
        record["notes"] = puzzle.notes
        record["pieceCount"] = Int(puzzle.pieceCount)
        record["completedAt"] = puzzle.completedAt
        record["createdAt"] = puzzle.createdAt
        record["updatedAt"] = puzzle.updatedAt
        record["householdRecordName"] = household.recordName
        record["id"] = puzzle.id?.uuidString
        // Sent only when changed since the last confirmed upload; see SyncImageAsset.setPhotoField.
        SyncImageAsset.setPhotoField("photo", on: record, photoData: puzzle.photoData, uploadedHash: puzzle.photoUploadedHash, recordName: recordName)
        return record
    }

    static func apply(_ record: CKRecord, to puzzle: LLPuzzle, household: Household?) {
        puzzle.recordName = record.recordID.recordName
        puzzle.name = record["name"] as? String
        puzzle.brand = record["brand"] as? String
        puzzle.notes = record["notes"] as? String
        puzzle.pieceCount = Int32((record["pieceCount"] as? Int) ?? 0)
        puzzle.completedAt = record["completedAt"] as? Date
        puzzle.createdAt = record["createdAt"] as? Date
        puzzle.updatedAt = record["updatedAt"] as? Date
        // photoUploadedHash tracks what the server holds, so the next local edit only re-sends
        // the photo if it has changed since.
        switch SyncImageAsset.inboundPhoto("photo", from: record) {
        case .photo(let data, let hash):
            puzzle.photoData = data
            puzzle.photoUploadedHash = hash
        case .none:
            puzzle.photoData = nil
            puzzle.photoUploadedHash = nil
        case .unreadable:
            break
        }
        puzzle.ckSystemFields = encodeSystemFields(record)
        if let parsedID = parsedID(from: record) { puzzle.id = parsedID }
        puzzle.householdRecordName = record["householdRecordName"] as? String
        if let household { puzzle.household = household }
    }

    // MARK: - LLCalendarEvent

    static func makeRecord(for event: LLCalendarEvent) -> CKRecord? {
        guard let household = event.household, let zoneID = zoneID(for: household), let recordName = event.recordName else { return nil }
        let record = baseRecord(recordType: RecordType.calendarEvent, recordName: recordName, zoneID: zoneID, existingSystemFields: event.ckSystemFields)
        record["name"] = event.name
        record["tag"] = event.tag
        record["day"] = Int(event.day)
        record["month"] = Int(event.month)
        // Optional: nil means "no year" (AddEditEventView reads/writes it via value(forKey:)).
        record["year"] = event.value(forKey: "year") as? NSNumber
        record["createdAt"] = event.createdAt
        record["updatedAt"] = event.updatedAt
        record["householdRecordName"] = household.recordName
        record["id"] = event.id?.uuidString
        return record
    }

    static func apply(_ record: CKRecord, to event: LLCalendarEvent, household: Household?) {
        event.recordName = record.recordID.recordName
        event.name = record["name"] as? String
        event.tag = (record["tag"] as? String) ?? "Other"
        event.day = Int16((record["day"] as? Int) ?? 0)
        event.month = Int16((record["month"] as? Int) ?? 0)
        event.setValue(record["year"] as? NSNumber, forKey: "year")
        event.createdAt = record["createdAt"] as? Date
        event.updatedAt = record["updatedAt"] as? Date
        // notificationsEnabledForEvent is never touched here: it stays this device's choice
        // (a newly-arrived event gets the model default, on).
        event.ckSystemFields = encodeSystemFields(record)
        if let parsedID = parsedID(from: record) { event.id = parsedID }
        event.householdRecordName = record["householdRecordName"] as? String
        if let household { event.household = household }
    }

    // MARK: - RecipeCategory

    static func makeRecord(for category: RecipeCategory) -> CKRecord? {
        guard let household = category.household, let zoneID = zoneID(for: household), let recordName = category.recordName else { return nil }
        let record = baseRecord(recordType: RecordType.recipeCategory, recordName: recordName, zoneID: zoneID, existingSystemFields: category.ckSystemFields)
        record["name"] = category.name
        record["householdRecordName"] = household.recordName
        record["id"] = category.id?.uuidString
        return record
    }

    static func apply(_ record: CKRecord, to category: RecipeCategory, household: Household?) {
        category.recordName = record.recordID.recordName
        category.name = record["name"] as? String
        category.ckSystemFields = encodeSystemFields(record)
        if let parsedID = parsedID(from: record) { category.id = parsedID }
        category.householdRecordName = record["householdRecordName"] as? String
        if let household {
            category.household = household
            category.householdId = household.id
        }
    }

    // MARK: - Recipe

    /// Local storage format for Recipe.categoryRecordNamesRaw (recordNames are UUID strings, so
    /// a newline never appears inside one).
    static func decodeCategoryRecordNames(_ raw: String?) -> [String] {
        (raw ?? "").split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    static func encodeCategoryRecordNames(_ names: [String]) -> String? {
        names.isEmpty ? nil : names.sorted().joined(separator: "\n")
    }

    /// The recipe's category list for CloudKit: its linked categories plus any names from
    /// `categoryRecordNamesRaw` that don't match a local category yet (still in flight), so a
    /// local edit made before a category arrives doesn't drop it from the server's list. A
    /// category the user removed locally *does* match a local row, so it's dropped. Sorted.
    static func effectiveCategoryRecordNames(for recipe: Recipe, context: NSManagedObjectContext) -> [String] {
        let linked = ((recipe.categories as? Set<RecipeCategory>) ?? []).compactMap(\.recordName)
        let pending = decodeCategoryRecordNames(recipe.categoryRecordNamesRaw).filter { name in
            !linked.contains(name) && fetchOne(entityName: "RecipeCategory", recordName: name, context: context) as RecipeCategory? == nil
        }
        return Array(Set(linked + pending)).sorted()
    }

    static func makeRecord(for recipe: Recipe) -> CKRecord? {
        guard let household = recipe.household, let zoneID = zoneID(for: household), let recordName = recipe.recordName,
              let context = recipe.managedObjectContext else { return nil }
        let record = baseRecord(recordType: RecordType.recipe, recordName: recordName, zoneID: zoneID, existingSystemFields: recipe.ckSystemFields)
        record["title"] = recipe.title
        record["servings"] = Int(recipe.servings)
        record["authorSource"] = recipe.authorSource
        record["notes"] = recipe.notes
        record["createdAt"] = recipe.createdAt
        record["updatedAt"] = recipe.updatedAt
        record["householdRecordName"] = household.recordName

        // Many-to-many as a string list on the recipe (see effectiveCategoryRecordNames). An
        // empty list is sent as nil, the unambiguous "no categories".
        let names = effectiveCategoryRecordNames(for: recipe, context: context)
        record["categoryRecordNames"] = names.isEmpty ? nil : names

        record["id"] = recipe.id?.uuidString
        return record
    }

    /// Links whichever categories already exist locally; the rest are resolved later by
    /// InboundChangeApplier's category retry from `categoryRecordNamesRaw`.
    static func apply(_ record: CKRecord, to recipe: Recipe, household: Household?, context: NSManagedObjectContext) {
        recipe.recordName = record.recordID.recordName
        recipe.title = record["title"] as? String
        recipe.servings = Int16((record["servings"] as? Int) ?? 4)
        recipe.authorSource = record["authorSource"] as? String
        recipe.notes = record["notes"] as? String
        recipe.createdAt = record["createdAt"] as? Date
        recipe.updatedAt = record["updatedAt"] as? Date
        recipe.ckSystemFields = encodeSystemFields(record)
        if let parsedID = parsedID(from: record) { recipe.id = parsedID }
        recipe.householdRecordName = record["householdRecordName"] as? String
        if let household {
            recipe.household = household
            recipe.householdId = household.id
        }

        let names = (record["categoryRecordNames"] as? [String]) ?? []
        recipe.categoryRecordNamesRaw = encodeCategoryRecordNames(names)
        let resolved = names.compactMap { fetchOne(entityName: "RecipeCategory", recordName: $0, context: context) as RecipeCategory? }
        recipe.categories = NSSet(array: resolved)
    }

    // MARK: - Recipe children (ingredients, steps, photos)
    //
    // Each child is its own record carrying `recipeRecordName` (+ `householdRecordName`), never a
    // CKRecord.Reference. Its zone comes from its recipe's household.

    static func makeRecord(for ingredient: RecipeIngredient) -> CKRecord? {
        guard let recipe = ingredient.recipe, let household = recipe.household, let zoneID = zoneID(for: household), let recordName = ingredient.recordName else { return nil }
        let record = baseRecord(recordType: RecordType.recipeIngredient, recordName: recordName, zoneID: zoneID, existingSystemFields: ingredient.ckSystemFields)
        record["name"] = ingredient.name
        record["amount"] = ingredient.amount
        record["unit"] = ingredient.unit
        record["position"] = Int(ingredient.position)
        record["recipeRecordName"] = recipe.recordName
        record["householdRecordName"] = household.recordName
        record["id"] = ingredient.id?.uuidString
        return record
    }

    static func apply(_ record: CKRecord, to ingredient: RecipeIngredient, recipe: Recipe?) {
        ingredient.recordName = record.recordID.recordName
        ingredient.name = record["name"] as? String
        ingredient.amount = (record["amount"] as? Double) ?? 0
        ingredient.unit = record["unit"] as? String
        ingredient.position = Int32((record["position"] as? Int) ?? 0)
        ingredient.ckSystemFields = encodeSystemFields(record)
        if let parsedID = parsedID(from: record) { ingredient.id = parsedID }
        ingredient.householdRecordName = record["householdRecordName"] as? String
        ingredient.recipeRecordName = record["recipeRecordName"] as? String
        if let recipe { ingredient.recipe = recipe }
    }

    static func makeRecord(for step: RecipeStep) -> CKRecord? {
        guard let recipe = step.recipe, let household = recipe.household, let zoneID = zoneID(for: household), let recordName = step.recordName else { return nil }
        let record = baseRecord(recordType: RecordType.recipeStep, recordName: recordName, zoneID: zoneID, existingSystemFields: step.ckSystemFields)
        record["text"] = step.text
        record["sectionTitle"] = step.sectionTitle
        record["position"] = Int(step.position)
        record["recipeRecordName"] = recipe.recordName
        record["householdRecordName"] = household.recordName
        record["id"] = step.id?.uuidString
        return record
    }

    static func apply(_ record: CKRecord, to step: RecipeStep, recipe: Recipe?) {
        step.recordName = record.recordID.recordName
        step.text = record["text"] as? String
        step.sectionTitle = record["sectionTitle"] as? String
        step.position = Int32((record["position"] as? Int) ?? 0)
        step.ckSystemFields = encodeSystemFields(record)
        if let parsedID = parsedID(from: record) { step.id = parsedID }
        step.householdRecordName = record["householdRecordName"] as? String
        step.recipeRecordName = record["recipeRecordName"] as? String
        if let recipe { step.recipe = recipe }
    }

    static func makeRecord(for photo: RecipePhoto) -> CKRecord? {
        guard let recipe = photo.recipe, let household = recipe.household, let zoneID = zoneID(for: household), let recordName = photo.recordName else { return nil }
        let record = baseRecord(recordType: RecordType.recipePhoto, recordName: recordName, zoneID: zoneID, existingSystemFields: photo.ckSystemFields)
        record["position"] = Int(photo.position)
        record["recipeRecordName"] = recipe.recordName
        record["householdRecordName"] = household.recordName
        record["id"] = photo.id?.uuidString
        // Same upload-once rule as LLPuzzle: a position-only change doesn't re-upload the photo.
        SyncImageAsset.setPhotoField("photo", on: record, photoData: photo.photoData, uploadedHash: photo.photoUploadedHash, recordName: recordName)
        return record
    }

    static func apply(_ record: CKRecord, to photo: RecipePhoto, recipe: Recipe?) {
        photo.recordName = record.recordID.recordName
        photo.position = Int32((record["position"] as? Int) ?? 0)
        switch SyncImageAsset.inboundPhoto("photo", from: record) {
        case .photo(let data, let hash):
            photo.photoData = data
            photo.photoUploadedHash = hash
        case .none:
            photo.photoData = nil
            photo.photoUploadedHash = nil
        case .unreadable:
            break
        }
        photo.ckSystemFields = encodeSystemFields(record)
        if let parsedID = parsedID(from: record) { photo.id = parsedID }
        photo.householdRecordName = record["householdRecordName"] as? String
        photo.recipeRecordName = record["recipeRecordName"] as? String
        if let recipe { photo.recipe = recipe }
    }

    // MARK: - Entity-agnostic lookups (nextRecordZoneChangeBatch doesn't know an ID's entity type)

    /// Searches each registered entity in `entities` order (the same order as the hand-written
    /// chain this replaced) and builds the record for the first match.
    static func makeRecord(forRecordName recordName: String, context: NSManagedObjectContext) -> CKRecord? {
        for spec in entities {
            if let object: NSManagedObject = fetchOne(entityName: spec.entityName, recordName: recordName, context: context) {
                return makeRecord(forObject: object)
            }
        }
        return nil
    }

    /// Typed dispatch to the per-entity builders. A registered entity with no case here logs
    /// an error (and sends nothing) rather than silently dropping -- add its case alongside its
    /// `makeRecord(for:)`.
    private static func makeRecord(forObject object: NSManagedObject) -> CKRecord? {
        switch object {
        case let household as Household: return makeRecord(for: household)
        case let member as HouseholdMember: return makeRecord(for: member)
        case let movie as Movie: return makeRecord(for: movie)
        case let feedback as MovieFeedback: return makeRecord(for: feedback)
        case let viewing as Viewing: return makeRecord(for: viewing)
        case let show as TVShow: return makeRecord(for: show)
        case let book as BookEntry: return makeRecord(for: book)
        case let quote as LLQuote: return makeRecord(for: quote)
        case let puzzle as LLPuzzle: return makeRecord(for: puzzle)
        case let event as LLCalendarEvent: return makeRecord(for: event)
        case let category as RecipeCategory: return makeRecord(for: category)
        case let recipe as Recipe: return makeRecord(for: recipe)
        case let ingredient as RecipeIngredient: return makeRecord(for: ingredient)
        case let step as RecipeStep: return makeRecord(for: step)
        case let photo as RecipePhoto: return makeRecord(for: photo)
        default:
            SyncLogger.error(SyncLogger.engine, "makeRecord: no builder for \(object.entity.name ?? "<unknown entity>")")
            return nil
        }
    }

    static func fetchByRecordName<T: NSManagedObject>(entityName: String, recordName: String, context: NSManagedObjectContext) -> T? {
        fetchOne(entityName: entityName, recordName: recordName, context: context)
    }

    private static func fetchOne<T: NSManagedObject>(entityName: String, recordName: String, context: NSManagedObjectContext) -> T? {
        let request = NSFetchRequest<T>(entityName: entityName)
        request.predicate = NSPredicate(format: "recordName == %@", recordName)
        request.fetchLimit = 1
        return try? context.fetch(request).first
    }
}
