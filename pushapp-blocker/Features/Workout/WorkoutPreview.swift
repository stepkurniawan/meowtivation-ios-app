import AVFoundation
import SwiftUI
import UIKit

struct WorkoutPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let frame: PoseFrame?
    let configuration: WorkoutPoseConfiguration
    let onRotation: (Double) -> Void

    func makeUIView(context _: Context) -> WorkoutPreviewView {
        let view = WorkoutPreviewView()
        view.preview.session = session
        view.configuration = configuration
        view.onRotation = onRotation
        return view
    }

    func updateUIView(_ view: WorkoutPreviewView, context _: Context) {
        view.frameData = frame
        view.configuration = configuration
        view.imageAspect = frame?.imageAspectRatio ?? view.imageAspect
        view.setNeedsLayout()
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
    var frameData: PoseFrame?
    var configuration: WorkoutPoseConfiguration?
    var imageAspect = 9.0 / 16
    private var angle: Double?
    private let validJoints = CAShapeLayer()
    private let rejectedJoints = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        preview.videoGravity = .resizeAspect
        for (shape, color) in [(validJoints, UIColor.systemGreen), (rejectedJoints, UIColor.systemOrange)] {
            shape.fillColor = color.cgColor
            shape.strokeColor = color.cgColor
            shape.lineWidth = 2
            layer.addSublayer(shape)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Preview layout also maps Vision points and draws the current skeleton.
    // Preview layout maps points and draws the current skeleton in one pass.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
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

        let size = CGSize(width: min(bounds.width, bounds.height * imageAspect),
                          height: min(bounds.height, bounds.width / imageAspect))
        let rect = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                          width: size.width, height: size.height)
        func point(_ joint: PoseJoint) -> CGPoint {
            CGPoint(x: rect.minX + CGFloat(1 - joint.imagePoint.x) * rect.width,
                    y: rect.minY + CGFloat(1 - joint.imagePoint.y) * rect.height)
        }

        let good = UIBezierPath(), bad = UIBezierPath()
        if let frameData, let configuration {
            for bone in configuration.bones {
                if let start = frameData.joints[bone.start], let end = frameData.joints[bone.end],
                   start.isUsable, end.isUsable
                {
                    good.move(to: point(start)); good.addLine(to: point(end))
                }
            }
            for bodyJoint in configuration.trackedJoints {
                guard let joint = frameData.joints[bodyJoint],
                      joint.imagePoint.x.isFinite, joint.imagePoint.y.isFinite else { continue }
                let position = point(joint)
                (joint.isUsable ? good : bad).append(UIBezierPath(ovalIn:
                    CGRect(x: position.x - 3, y: position.y - 3, width: 6, height: 6)))
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        validJoints.path = good.cgPath
        rejectedJoints.path = bad.cgPath
        CATransaction.commit()
    }
}
