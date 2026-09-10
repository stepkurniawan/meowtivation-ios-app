//
//  pushapp_blockerApp.swift
//  pushapp-blocker
//
//  Created by stephen on 01.09.26.
//

import SwiftUI
import Combine
import UIKit

@main
struct pushapp_blockerApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var blockedAppsStore = BlockedAppsStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(blockedAppsStore)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { // when the app becomes active, refresh the lock state to ensure it's up to date
                        blockedAppsStore.refreshLockState()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                    blockedAppsStore.refreshLockState()
                }
        }
    }
}
