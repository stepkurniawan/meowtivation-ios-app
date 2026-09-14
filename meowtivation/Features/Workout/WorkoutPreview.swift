import AVFoundation
import SwiftUI
import UIKit

struct WorkoutPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let onRotation: (Double) -> Void

    func makeUIView(context _: Context) -> WorkoutPreviewView {
        let view = WorkoutPreviewView()
        view.preview.session = session
        view.onRotation = onRotation
        return view
    }

    func updateUIView(_ view: WorkoutPreviewView, context _: Context) {
        view.onRotation = onRotation
    }
}

final class WorkoutPreviewView: UIView {
    // UIView requires this override to remain a class property.
    // swiftlint:disable:next static_over_final_class
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var preview: AVCaptureVideoPreviewLayer {
        guard let previewLayer = layer as? AVCaptureVideoPreviewLayer else {
            fatalError("WorkoutPreviewView must use AVCaptureVideoPreviewLayer")
        }
        return previewLayer
    }

    var onRotation: ((Double) -> Void)?
    private var angle: Double?

    override init(frame: CGRect) {
        super.init(frame: frame)
        preview.videoGravity = .resizeAspect
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Preview layout keeps the camera feed aligned with the Vision orientation.
    override func layoutSubviews() {
        super.layoutSubviews()
        let rotation: Double
        switch window?.windowScene?.effectiveGeometry.interfaceOrientation {
        case .landscapeLeft: rotation = 0
        case .landscapeRight: rotation = 180
        case .portraitUpsideDown: rotation = 270
        default: rotation = 90
        }
        if let connection = preview.connection {
            if connection.isVideoRotationAngleSupported(rotation) {
                connection.videoRotationAngle = rotation
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
        }
        if angle != rotation {
            angle = rotation
            DispatchQueue.main.async { [weak self] in self?.onRotation?(rotation) }
        }
    }
}
