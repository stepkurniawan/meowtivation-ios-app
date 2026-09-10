//
//  ContentView.swift
//  pushapp-blocker
//
//  Created by stephen on 01.09.26.
//

import SwiftUI
import UIKit

struct ContentView: View {
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

    private func openCamera() {
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
}
