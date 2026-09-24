//
//  SyncImageAsset.swift
//  Livin Log
//
//  Phase 4a (Batch 2): photos sync as CKAssets, never as inline record data -- confirmed in
//  CKRecord.h: "the data that a record stores must not exceed 1 MB. Assets don't count toward
//  this limit." Shared by LLPuzzle now and RecipePhoto in Batch 3.
//
//  - Size: max 1600 px on the long edge, JPEG quality 0.7 (approved). Applied when a photo is
//    picked (see AddEditPuzzleView) and again at upload for older full-size photos. A JPEG
//    already within bounds uploads as-is, so a new photo isn't compressed twice.
//  - Outbound: CKAsset needs a file URL, and CloudKit doesn't delete it after upload (confirmed
//    in CKAsset.h: "CloudKit doesn't delete the file at the specified URL"). Files are staged at
//    Caches/CKAssetStaging/<recordName>.jpg, removed once the send result for that record
//    arrives (SyncController.handleSentRecordZoneChanges), and the folder is cleared at launch.
//  - Inbound: an asset's fileURL is in a staging area "the system regularly deletes" (CKAsset.h),
//    so its data is copied into the store immediately, inside the inbound apply.

import CloudKit
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum SyncImageAsset {
    // Pure image helpers are `nonisolated` (the module defaults to MainActor) so photo pickers
    // can call them from their non-main callbacks.
    nonisolated static let maxPixelDimension = 1600
    nonisolated static let jpegQuality = 0.7

    private static var stagingDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CKAssetStaging", isDirectory: true)
    }

    private static func stagedFileURL(recordName: String) -> URL {
        stagingDirectory.appendingPathComponent("\(recordName).jpg")
    }

    // MARK: - Downscale / encode

    /// Downscales to fit `maxPixelDimension` (applying EXIF orientation) and re-encodes as JPEG
    /// at `jpegQuality`. Returns nil if the data isn't a decodable image.
    nonisolated static func downscaledJPEG(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// True for a JPEG whose long edge is already within `maxPixelDimension`.
    nonisolated private static func isWithinUploadBounds(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source), (type as String) == UTType.jpeg.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return false }
        return max(width, height) <= maxPixelDimension
    }

    // MARK: - Outbound staging

    /// Writes the (downscaled if needed) photo to its staging file and returns a CKAsset for it.
    /// nil if staging failed -- callers then leave the record's photo field untouched, so the
    /// server keeps its current photo rather than having it cleared.
    static func stagedAsset(for data: Data, recordName: String) -> CKAsset? {
        let uploadData = isWithinUploadBounds(data) ? data : (downscaledJPEG(data) ?? data)
        let url = stagedFileURL(recordName: recordName)
        do {
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            try uploadData.write(to: url, options: .atomic)
            return CKAsset(fileURL: url)
        } catch {
            SyncLogger.error(SyncLogger.outbound, "failed staging asset for \(recordName): \(String(describing: error))")
            return nil
        }
    }

    /// Called once a record's send result arrives (saved or failed -- a retry re-stages).
    /// A no-op for records that never had a staged asset.
    static func removeStagedAsset(recordName: String) {
        try? FileManager.default.removeItem(at: stagedFileURL(recordName: recordName))
    }

    /// Clears files left behind by a send that never reported back (e.g. the app was killed).
    /// Only call before the engines start sending.
    static func clearStagingDirectory() {
        try? FileManager.default.removeItem(at: stagingDirectory)
    }

    // MARK: - Upload-once tracking

    /// SHA-256 (hex) of a row's local photo data. LLPuzzle.photoUploadedHash (local, unsynced)
    /// holds this for the photo last confirmed on the server, so makeRecord can omit the photo
    /// field when it hasn't changed and an edit to other fields doesn't re-upload it.
    nonisolated static func contentHash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// What a record currently being sent did with its photo field.
    nonisolated enum PhotoUpload: Sendable {
        case uploaded(hash: String)
        case cleared
    }

    /// Photo state per recordName for records handed to the engine but not yet confirmed.
    /// Moved onto the row (photoUploadedHash) only when that record's save succeeds; dropped on
    /// failure, so a retry sends the photo again. Lock-protected: record building runs inside a
    /// background context's performAndWait.
    nonisolated final class PendingPhotoUploads: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: PhotoUpload] = [:]

        func set(_ upload: PhotoUpload, for recordName: String) {
            lock.withLock { entries[recordName] = upload }
        }

        func take(_ recordName: String) -> PhotoUpload? {
            lock.withLock { entries.removeValue(forKey: recordName) }
        }
    }

    nonisolated static let pendingPhotoUploads = PendingPhotoUploads()

    // MARK: - Record field helpers (LLPuzzle, RecipePhoto)

    /// Outbound: sets `record[key]` only when the photo changed since the last confirmed upload
    /// (`uploadedHash`, the row's local unsynced photoUploadedHash). Unchanged, the key is
    /// omitted entirely so the server keeps its photo -- confirmed on device in Batch 2 (a
    /// notes-only puzzle edit preserved the photo). A removed photo sends the clear. The new
    /// hash is committed to the row only when the save succeeds
    /// (SyncController.handleSentRecordZoneChanges).
    static func setPhotoField(_ key: String, on record: CKRecord, photoData: Data?, uploadedHash: String?, recordName: String) {
        let currentHash = photoData.map(contentHash)
        guard currentHash != uploadedHash else { return }
        if let photoData, let currentHash {
            // Staging failure leaves the key unset, so the server keeps its current photo.
            if let asset = stagedAsset(for: photoData, recordName: recordName) {
                record[key] = asset
                pendingPhotoUploads.set(.uploaded(hash: currentHash), for: recordName)
            }
        } else {
            record[key] = nil
            pendingPhotoUploads.set(.cleared, for: recordName)
        }
    }

    enum InboundPhoto {
        /// Copied out of the asset; `hash` becomes the row's photoUploadedHash.
        case photo(Data, hash: String)
        /// The record has no photo: clear the local one (and its hash).
        case none
        /// An asset is present but its file isn't readable: keep the local photo and hash.
        case unreadable
    }

    /// Inbound: reads `record[key]`, copying asset data out of CloudKit's temporary staging area
    /// immediately.
    static func inboundPhoto(_ key: String, from record: CKRecord) -> InboundPhoto {
        guard let asset = record[key] as? CKAsset else { return .none }
        guard let data = data(from: asset) else {
            SyncLogger.error(SyncLogger.inbound, "\(record.recordType) \(record.recordID.recordName): \(key) asset had no readable file; kept local photo")
            return .unreadable
        }
        return .photo(data, hash: contentHash(data))
    }

    // MARK: - Inbound

    /// Copies an inbound asset's data out of CloudKit's temporary staging area. nil if the file
    /// isn't there (e.g. the asset wasn't downloaded).
    static func data(from asset: CKAsset) -> Data? {
        guard let url = asset.fileURL else { return nil }
        return try? Data(contentsOf: url)
    }
}
