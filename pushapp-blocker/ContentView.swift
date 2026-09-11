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
        .unblock: [.left, .right, .left, .right, .right, .right]
    ]

    @EnvironmentObject private var store: BlockedAppsStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var tapProgress: [TapSide] = []
    @State private var lastTap: TimeInterval?
    @State private var statusMessage: String?
    @State private var commandError: String?
    @State private var isLandingVisible = false
    @State private var isCameraOpen = false
    @State private var isShowingCameraUnavailable = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Text("PushApp Blocker")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Button {
                    openCamera()
                } label: {
                    Label("Open Camera", systemImage: "camera.fill")
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
            .onChange(of: isShowingCameraUnavailable) { _, _ in resetTapProgress() }
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
                } catch { }
            }
            .alert("App Blocking Failed", isPresented: Binding(
                get: { commandError != nil },
                set: { if !$0 { commandError = nil } }
            )) {
                Button("OK", role: .cancel) { commandError = nil }
            } message: {
                Text(commandError ?? "Unable to change restrictions.")
            }
            .sheet(isPresented: $isCameraOpen) {
                CameraView()
                    .ignoresSafeArea()
            }
            .alert("Camera Unavailable", isPresented: $isShowingCameraUnavailable) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("This device does not have an available camera.")
            }
        }
    }

    private func resetTapProgress() {
        tapProgress = []
        lastTap = nil
    }

    private func handleCornerTap(_ side: TapSide) {
        guard isLandingVisible, scenePhase == .active, !isCameraOpen,
              !isShowingCameraUnavailable, commandError == nil else { return }
        let timestamp = ProcessInfo.processInfo.systemUptime
        if let lastTap, timestamp - lastTap > 1.5 { resetTapProgress() }
        lastTap = timestamp
        tapProgress.append(side)
        if let command = Self.commandSequences.first(where: { $0.value == tapProgress })?.key {
            resetTapProgress()
            do {
                try store.setDeveloperLockOverride(isLocked: (command == .block))
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
        while !tapProgress.isEmpty && !Self.commandSequences.values.contains(where: { $0.starts(with: tapProgress) }) {
            tapProgress.removeFirst()
        }
    }

    private func openCamera() {
        resetTapProgress()
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            isCameraOpen = true
        } else {
            isShowingCameraUnavailable = true
        }
    }
}

struct CameraView: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) { }

    func makeCoordinator() -> Coordinator {
        Coordinator(dismiss: dismiss)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let dismiss: DismissAction

        init(dismiss: DismissAction) {
            self.dismiss = dismiss
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            dismiss()
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(BlockedAppsStore())
}
