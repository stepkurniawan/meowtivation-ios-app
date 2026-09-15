//
//  meowtivation.swift
//  meowtivation
//
//  Created by stephen on 01.09.26.
//

import Combine
import SwiftUI
import UIKit

@main
struct MeowtivationApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var blockedAppsStore = BlockedAppsStore()

    var body: some Scene {
        WindowGroup {
            LandingView()
                .environmentObject(blockedAppsStore)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    guard phase == .active else { return }
                    Task { @MainActor in
                        // Let the first frame use the state loaded from shared defaults.
                        await Task.yield()
                        blockedAppsStore.reconcile()
                    }
                }
                .onReceive(NotificationCenter.default
                    .publisher(for: UIApplication.significantTimeChangeNotification))
                { _ in
                    blockedAppsStore.refreshLockState()
                }
        }
    }
}
