//
//  SceneDelegate.swift
//  SyncSpike
//

import CloudKit
import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        SpikeLogger.log(SpikeLogger.share, "windowScene(_:userDidAcceptCloudKitShareWith:) fired. participantStatus=\(cloudKitShareMetadata.participantStatus)")
        Task { @MainActor in
            await SyncController.shared.acceptShare(metadata: cloudKitShareMetadata)
        }
    }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let metadata = connectionOptions.cloudKitShareMetadata {
            SpikeLogger.log(SpikeLogger.share, "scene(_:willConnectTo:options:) carried cloudKitShareMetadata (cold launch via share link)")
            Task { @MainActor in
                await SyncController.shared.acceptShare(metadata: metadata)
            }
        }
    }
}
