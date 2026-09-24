//
//  SceneDelegate.swift
//  Livin Log
//
//  Phase 3b (sharing). Mirrors SyncSpike/SceneDelegate.swift's proven pattern exactly: handle
//  both the warm-launch accept hook and the cold-launch connectionOptions metadata, rather than
//  relying only on the simpler AppDelegate-level `userDidAcceptCloudKitShareWith:` (which this
//  app used pre-3b -- that hook covers warm launch but has no documented cold-launch path, unlike
//  `scene(_:willConnectTo:options:)`'s `connectionOptions.cloudKitShareMetadata`).
//

import CloudKit
import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        SyncLogger.log(SyncLogger.engine, "windowScene(_:userDidAcceptCloudKitShareWith:) fired. participantStatus=\(cloudKitShareMetadata.participantStatus)")
        Task { @MainActor in
            SyncController.shared.captureIncomingShareMetadata(cloudKitShareMetadata)
        }
    }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let metadata = connectionOptions.cloudKitShareMetadata {
            SyncLogger.log(SyncLogger.engine, "scene(_:willConnectTo:options:) carried cloudKitShareMetadata (cold launch via share link)")
            Task { @MainActor in
                SyncController.shared.captureIncomingShareMetadata(metadata)
            }
        }
    }
}
