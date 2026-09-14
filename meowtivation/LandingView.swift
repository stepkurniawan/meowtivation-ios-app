//
//  LandingView.swift
//  meowtivation
//
//  Created by stephen on 01.09.26.
//

import SwiftUI
import UIKit

struct LandingView: View {
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
    @State private var isWorkoutChooserVisible = false
    @State private var selectedExercise: WorkoutExercise?

    var body: some View {
        NavigationStack {
            ZStack {
                // Replace LandingBackground.png in the image set to use a custom photo.
                Image("LandingBackground")
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
                    .accessibilityHidden(true)

                Color.black.opacity(0.12)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    HStack {
                        NavigationLink {
                            BlockedAppsView()
                        } label: {
                            Image(systemName: "gearshape.fill")
                                .font(.title3.weight(.semibold))
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.bordered)
                        .tint(.primary)
                        .accessibilityLabel("Settings")

                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                    Spacer(minLength: 24)

                    Text("meowtivation")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    Spacer(minLength: 24)

                    Button {
                        isWorkoutChooserVisible = true
                    } label: {
                        Label("Start Workout", systemImage: "figure.strengthtraining.traditional")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)

                    if isWorkoutChooserVisible {
                        VStack(spacing: 10) {
                            workoutChoice(.pushUp,
                                          title: "Push-up",
                                          symbol: "figure.strengthtraining.traditional")
                            workoutChoice(.squat,
                                          title: "Squat",
                                          symbol: "figure.strengthtraining.functional")
                            Button("Cancel", role: .cancel) {
                                isWorkoutChooserVisible = false
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 12)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(alignment: .bottom) {
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
            }
            .onAppear { isLandingVisible = true }
            .onDisappear {
                isLandingVisible = false
                resetTapProgress()
            }
            .onChange(of: scenePhase) { _, _ in resetTapProgress() }
            .onChange(of: selectedExercise) { _, _ in resetTapProgress() }
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
            .fullScreenCover(item: $selectedExercise, onDismiss: {
                isWorkoutChooserVisible = false
            }) { exercise in
                WorkoutView(exercise: exercise)
            }
        }
    }

    private func resetTapProgress() {
        tapProgress = []
        lastTap = nil
    }

    private func handleCornerTap(_ side: TapSide) {
        guard isLandingVisible, scenePhase == .active, selectedExercise == nil,
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

    private func workoutChoice(_ exercise: WorkoutExercise, title: String, symbol: String) -> some View {
        Button {
            select(exercise)
        } label: {
            Label(title, systemImage: symbol)
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private func select(_ exercise: WorkoutExercise) {
        resetTapProgress()
        isWorkoutChooserVisible = false
        selectedExercise = exercise
    }
}

#Preview {
    LandingView()
        .environmentObject(BlockedAppsStore())
}
