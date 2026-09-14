//
//  ContentView.swift
//  pushapp-blocker
//
//  Created by stephen on 01.09.26.
//

import SwiftUI
import UIKit

struct ContentView: View {
    private enum TapSide {
        case left, right
    }

    private enum DeveloperCommand {
        case block, unblock
    }

    private static let commandSequences: [DeveloperCommand: [TapSide]] = [
        .block: [.left, .right, .left, .right, .left, .left],
        .unblock: [.left, .right, .left, .right, .right, .right],
    ]

    @EnvironmentObject private var store: BlockedAppsStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var tapProgress: [TapSide] = []
    @State private var lastTap: TimeInterval?
    @State private var statusMessage: String?
    @State private var commandError: String?
    @State private var isLandingVisible = false
    @State private var isCameraOpen = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Text("PushApp Blocker")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Button {
                    openWorkout()
                } label: {
                    Label("Start Workout", systemImage: "figure.strengthtraining.traditional")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 40)

                NavigationLink {
                    BlockedAppsView()
                } label: {
                    Label("Blocked Apps", systemImage: "lock.app.dashed")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .padding(.horizontal, 40)

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: 96, height: 96)
                        .contentShape(Rectangle())
                        .onTapGesture { handleCornerTap(.left) }
                    Spacer()
                    Color.clear
                        .frame(width: 96, height: 96)
                        .contentShape(Rectangle())
                        .onTapGesture { handleCornerTap(.right) }
                }
                .ignoresSafeArea(.container, edges: .bottom)
                .accessibilityHidden(true)
            }
            .onAppear { isLandingVisible = true }
            .onDisappear {
                isLandingVisible = false
                resetTapProgress()
            }
            .onChange(of: scenePhase) { _, _ in resetTapProgress() }
            .onChange(of: isCameraOpen) { _, _ in resetTapProgress() }
            .onChange(of: commandError) { _, _ in resetTapProgress() }
            .overlay(alignment: .bottom) {
                if let statusMessage {
                    Text(statusMessage)
                        .font(.footnote)
                        .padding()
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom)
                        .allowsHitTesting(false)
                }
            }
            .task(id: statusMessage) {
                guard statusMessage != nil else { return }
                do {
                    try await Task.sleep(for: .seconds(3))
                    statusMessage = nil
                } catch {}
            }
            .alert("App Blocking Failed", isPresented: Binding(
                get: { commandError != nil },
                set: {
                    if !$0 {
                        commandError = nil
                    }
                }
            )) {
                Button("OK", role: .cancel) { commandError = nil }
            } message: {
                Text(commandError ?? "Unable to change restrictions.")
            }
            .fullScreenCover(isPresented: $isCameraOpen) {
                WorkoutView()
            }
        }
    }

    private func resetTapProgress() {
        tapProgress = []
        lastTap = nil
    }

    private func handleCornerTap(_ side: TapSide) {
        guard isLandingVisible, scenePhase == .active, !isCameraOpen,
              commandError == nil else { return }
        let timestamp = ProcessInfo.processInfo.systemUptime
        if let lastTap, timestamp - lastTap > 1.5 {
            resetTapProgress()
        }
        lastTap = timestamp
        tapProgress.append(side)
        if let command = Self.commandSequences.first(where: { $0.value == tapProgress })?.key {
            resetTapProgress()
            do {
                try store.setDeveloperLockOverride(isLocked: command == .block)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                statusMessage = (command == .block) ? "Selected apps blocked" : "Selected apps unlocked for today"
                if let error = store.monitoringError {
                    commandError = "Restrictions applied. Daily reset unavailable: \(error)"
                }
            } catch {
                statusMessage = nil
                commandError = error.localizedDescription
            }
            return
        }
        while !tapProgress.isEmpty, !Self.commandSequences.values.contains(where: { $0.starts(with: tapProgress) }) {
            tapProgress.removeFirst()
        }
    }

    private func openWorkout() {
        resetTapProgress()
        isCameraOpen = true
    }
}

#Preview {
    ContentView()
        .environmentObject(BlockedAppsStore())
}
