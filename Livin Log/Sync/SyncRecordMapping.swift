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
    }

    static func zoneID(householdID: UUID) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: "Household-\(householdID.uuidString)", ownerName: CKCurrentUserDefaultName)
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
        guard let id = household.id, let recordName = household.recordName else { return nil }
        let record = baseRecord(recordType: RecordType.household, recordName: recordName, zoneID: zoneID(householdID: id), existingSystemFields: household.ckSystemFields)
        record["name"] = household.name
        record["createdByAppUserId"] = household.value(forKey: "createdByAppUserId") as? String
        record["createdAt"] = household.createdAt
        return record
    }

    static func apply(_ record: CKRecord, to household: Household) {
        household.recordName = record.recordID.recordName
        household.name = record["name"] as? String
        household.setValue(record["createdByAppUserId"] as? String, forKey: "createdByAppUserId")
        household.createdAt = record["createdAt"] as? Date
        household.ckSystemFields = encodeSystemFields(record)
    }

    // MARK: - HouseholdMember

    static func makeRecord(for member: HouseholdMember) -> CKRecord? {
        guard let household = member.household, let householdID = household.id, let recordName = member.recordName else { return nil }
        let record = baseRecord(recordType: RecordType.member, recordName: recordName, zoneID: zoneID(householdID: householdID), existingSystemFields: member.ckSystemFields)
        record["displayName"] = member.displayName
        record["claimedByAppUserId"] = member.value(forKey: "claimedByAppUserId") as? String
        record["isActive"] = member.isActive
        record["createdAt"] = member.createdAt
        record["householdRecordName"] = household.recordName
        return record
    }

    static func apply(_ record: CKRecord, to member: HouseholdMember, household: Household?) {
        member.recordName = record.recordID.recordName
        member.displayName = record["displayName"] as? String
        member.setValue(record["claimedByAppUserId"] as? String, forKey: "claimedByAppUserId")
        member.isActive = (record["isActive"] as? Bool) ?? true
        member.createdAt = record["createdAt"] as? Date
        member.ckSystemFields = encodeSystemFields(record)
        // Persisted unconditionally (even when `household` is nil) so a later inbound batch can
        // retry the link -- see InboundChangeApplier.retryUnresolvedLinks().
        member.householdRecordName = record["householdRecordName"] as? String
        if let household { member.household = household }
    }

    // MARK: - Movie

    static func makeRecord(for movie: Movie) -> CKRecord? {
        guard let household = movie.household, let householdID = household.id, let recordName = movie.recordName else { return nil }
        let record = baseRecord(recordType: RecordType.movie, recordName: recordName, zoneID: zoneID(householdID: householdID), existingSystemFields: movie.ckSystemFields)
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
        movie.householdRecordName = record["householdRecordName"] as? String
        if let household { movie.household = household }
    }

    // MARK: - MovieFeedback

    static func makeRecord(for feedback: MovieFeedback) -> CKRecord? {
        guard let household = feedback.household, let householdID = household.id, let recordName = feedback.recordName else { return nil }
        let record = baseRecord(recordType: RecordType.feedback, recordName: recordName, zoneID: zoneID(householdID: householdID), existingSystemFields: feedback.ckSystemFields)
        record["rating"] = feedback.rating
        record["slept"] = feedback.slept
        record["notes"] = feedback.notes
        record["updatedAt"] = feedback.updatedAt
        record["householdRecordName"] = household.recordName
        record["memberRecordName"] = feedback.member?.recordName
        record["movieRecordName"] = feedback.movie?.recordName
        return record
    }

    static func apply(_ record: CKRecord, to feedback: MovieFeedback, household: Household?, member: HouseholdMember?, movie: Movie?) {
        feedback.recordName = record.recordID.recordName
        feedback.rating = (record["rating"] as? Double) ?? 0
        feedback.slept = (record["slept"] as? Bool) ?? false
        feedback.notes = record["notes"] as? String
        feedback.updatedAt = record["updatedAt"] as? Date
        feedback.ckSystemFields = encodeSystemFields(record)
        feedback.householdRecordName = record["householdRecordName"] as? String
        feedback.memberRecordName = record["memberRecordName"] as? String
        feedback.movieRecordName = record["movieRecordName"] as? String
        if let household { feedback.household = household }
        if let member { feedback.member = member }
        if let movie { feedback.movie = movie }
    }

    // MARK: - Viewing

    static func makeRecord(for viewing: Viewing) -> CKRecord? {
        guard let household = viewing.household, let householdID = household.id, let recordName = viewing.recordName else { return nil }
        let record = baseRecord(recordType: RecordType.viewing, recordName: recordName, zoneID: zoneID(householdID: householdID), existingSystemFields: viewing.ckSystemFields)
        record["isRewatch"] = viewing.isRewatch
        record["notes"] = viewing.notes
        record["watchedOn"] = viewing.watchedOn
        record["householdRecordName"] = household.recordName
        record["movieRecordName"] = viewing.movie?.recordName
        return record
    }

    static func apply(_ record: CKRecord, to viewing: Viewing, household: Household?, movie: Movie?) {
        viewing.recordName = record.recordID.recordName
        viewing.isRewatch = (record["isRewatch"] as? Bool) ?? false
        viewing.notes = record["notes"] as? String
        viewing.watchedOn = record["watchedOn"] as? Date
        viewing.ckSystemFields = encodeSystemFields(record)
        viewing.householdRecordName = record["householdRecordName"] as? String
        viewing.movieRecordName = record["movieRecordName"] as? String
        if let household { viewing.household = household }
        if let movie { viewing.movie = movie }
    }

    // MARK: - Entity-agnostic lookups (nextRecordZoneChangeBatch doesn't know an ID's entity type)

    static func makeRecord(forRecordName recordName: String, context: NSManagedObjectContext) -> CKRecord? {
        if let household = fetchOne(entityName: "Household", recordName: recordName, context: context) as Household? {
            return makeRecord(for: household)
        }
        if let member = fetchOne(entityName: "HouseholdMember", recordName: recordName, context: context) as HouseholdMember? {
            return makeRecord(for: member)
        }
        if let movie = fetchOne(entityName: "Movie", recordName: recordName, context: context) as Movie? {
            return makeRecord(for: movie)
        }
        if let feedback = fetchOne(entityName: "MovieFeedback", recordName: recordName, context: context) as MovieFeedback? {
            return makeRecord(for: feedback)
        }
        if let viewing = fetchOne(entityName: "Viewing", recordName: recordName, context: context) as Viewing? {
            return makeRecord(for: viewing)
        }
        return nil
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
