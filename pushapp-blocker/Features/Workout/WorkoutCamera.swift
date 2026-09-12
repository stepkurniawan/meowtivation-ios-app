import AVFoundation
import CoreMotion
import Foundation
import Vision
import simd

nonisolated enum WorkoutCameraState: Equatable, Sendable {
    case idle, requestingPermission, running, denied, unavailable, interrupted, failed(String)
    var message: String {
        switch self {
        case .idle: "Camera paused"
        case .requestingPermission: "Allow camera access to start your workout."
        case .running: ""
        case .denied: "Allow Camera access in Settings to start your workout."
        case .unavailable: "A front camera is unavailable. Use a physical iPhone to track your workout."
        case .interrupted: "Camera interrupted. Tracking will resume when the camera is available."
        case .failed(let message): message
        }
    }
}

nonisolated enum WorkoutCameraEvent: Sendable {
    case state(WorkoutCameraState)
    case frame(PoseFrame, milliseconds: Double)
}

nonisolated protocol WorkoutCameraControlling: AnyObject {
    var session: AVCaptureSession { get }
    func start(generation: Int, rotation: Double)
    func stop()
    func updateRotation(_ angle: Double)
    func updatePoseConfiguration(_ configuration: WorkoutPoseConfiguration)
}

nonisolated extension WorkoutCameraControlling {
    func updatePoseConfiguration(_ configuration: WorkoutPoseConfiguration) { }
}

/// All mutable capture and Vision state is confined to queue. The preview only
/// attaches the session; it never starts, stops, or configures capture itself.
nonisolated final class WorkoutCamera: NSObject, WorkoutCameraControlling, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "workout.capture", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
    private let motion = CMMotionManager()
    private let pose2D = VNDetectHumanBodyPoseRequest()
    private var configuration: WorkoutPoseConfiguration
    private let onEvent: @Sendable (Int, WorkoutCameraEvent) -> Void
    private var observers: [NSObjectProtocol] = []
    private var device: AVCaptureDevice?
    private var configured = false
    private var active = false
    private var generation = 0
    private var lastAnalysis = -Double.infinity
    private var failures = 0
    private var rotation = 90.0
    private var movingUntil = 0.0
    private var poseStabilizer = PoseStabilizer()
    private var didSetCameraTarget = false

    init(configuration: WorkoutPoseConfiguration,
         onEvent: @escaping @Sendable (Int, WorkoutCameraEvent) -> Void) {
        self.configuration = configuration
        self.onEvent = onEvent
        super.init()
        for name in [AVCaptureSession.wasInterruptedNotification,
                     AVCaptureSession.interruptionEndedNotification,
                     AVCaptureSession.runtimeErrorNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { [weak self] note in
                let name = note.name
                self?.queue.async { [weak self] in self?.handleNotification(name) }
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        motion.stopDeviceMotionUpdates()
    }

    /// Start the camera and begin analyzing frames for body pose.
    /// - Parameters:
    ///   - generation: A unique identifier for this camera session. If a new session is started, the previous session will be ignored.
    ///   - rotation: The rotation of the camera in degrees. The camera is rotated to match the device orientation, so the image is always upright.
    func start(generation: Int, rotation: Double) {
        queue.async { [self] in
            self.generation = generation
            self.rotation = rotation
            active = true
            failures = 0
            lastAnalysis = -.infinity
            poseStabilizer.reset()
            didSetCameraTarget = false
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: configureAndStart()
            case .notDetermined:
                emit(.state(.requestingPermission))
                AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                    guard let self else { return }
                    self.queue.async {
                        guard self.active, self.generation == generation else { return }
                        if allowed { self.configureAndStart() } else { self.emit(.state(.denied)) }
                    }
                }
            default: emit(.state(.denied))
            }
        }
    }

    func stop() {
        queue.async { [self] in
            active = false
            motion.stopDeviceMotionUpdates()
            if session.isRunning { session.stopRunning() }
        }
    }

    func updateRotation(_ angle: Double) {
        queue.async { [self] in
            guard rotation != angle else { return }
            rotation = angle
            applyRotation()
            lastAnalysis = -.infinity
            poseStabilizer.reset()
            didSetCameraTarget = false
            if let device { configureAutomaticFocusAndExposure(on: device, at: CGPoint(x: 0.5, y: 0.5)) }
            movingUntil = ProcessInfo.processInfo.systemUptime + 0.75
            emit(.frame(PoseFrame(timestamp: ProcessInfo.processInfo.systemUptime, joints: [:],
                                  cameraIsMoving: true), milliseconds: 0))
        }
    }

    func updatePoseConfiguration(_ configuration: WorkoutPoseConfiguration) {
        queue.async { [self] in
            self.configuration = configuration
            poseStabilizer.reset()
            didSetCameraTarget = false
        }
    }

    private func emit(_ event: WorkoutCameraEvent) { onEvent(generation, event) }

    private func configureAndStart() {
        guard active else { return }
        do {
            if !configured {
                guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
                    emit(.state(.unavailable)); return
                }
                self.device = device
                let input = try AVCaptureDeviceInput(device: device)
                session.beginConfiguration()
                defer { session.commitConfiguration() }
                guard session.canAddInput(input), session.canAddOutput(output) else {
                    emit(.state(.unavailable)); return
                }
                if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
                requestTargetFrameRate(on: device)
                session.addInput(input)
                output.alwaysDiscardsLateVideoFrames = true
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
                output.setSampleBufferDelegate(self, queue: queue)
                session.addOutput(output)
                configured = true
                applyRotation()
            }
            if let device { configureAutomaticFocusAndExposure(on: device, at: CGPoint(x: 0.5, y: 0.5)) }
            if motion.isDeviceMotionAvailable {
                motion.deviceMotionUpdateInterval = 1.0 / 30
                motion.startDeviceMotionUpdates()
            }
            if !session.isRunning { session.startRunning() }
            emit(.state(session.isRunning ? .running : .failed("Unable to start the camera. Try again.")))
        } catch {
            emit(.state(.failed("Unable to configure the camera. Try again.")))
        }
    }

    private func requestTargetFrameRate(on device: AVCaptureDevice) {
        let targetFPS = PoseDetectionParameters.targetFPS
        guard device.activeFormat.videoSupportedFrameRateRanges.contains(where: {
            $0.minFrameRate <= targetFPS && targetFPS <= $0.maxFrameRate
        }) else { return }

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            let frameDuration = CMTime(seconds: 1.0 / targetFPS, preferredTimescale: 600)
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration
        } catch {
            // Keep the camera's default frame rate when configuration is unavailable.
        }
    }

    /// Camera configuration stays here; the active exercise supplies its target.
    private func configureAutomaticFocusAndExposure(on device: AVCaptureDevice, at point: CGPoint) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = point }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = point }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        } catch {
            // Preserve the device's default automatic behavior when it cannot be configured.
        }
    }

    private func applyRotation() {
        guard let connection = output.connection(with: .video) else { return }
        if connection.isVideoRotationAngleSupported(rotation) { connection.videoRotationAngle = rotation }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
    }

    private func handleNotification(_ name: Notification.Name) {
        guard active else { return }
        if name == AVCaptureSession.interruptionEndedNotification {
            lastAnalysis = -.infinity
            configureAndStart()
        } else if name == AVCaptureSession.wasInterruptedNotification {
            emit(.state(.interrupted))
        } else {
            emit(.state(.failed("The camera stopped unexpectedly. Try again.")))
            active = false
            motion.stopDeviceMotionUpdates()
            if session.isRunning { session.stopRunning() }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard active, !session.isInterrupted else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastAnalysis >= 1.0 / PoseDetectionParameters.targetFPS else { return }
        lastAnalysis = now
        if let reading = motion.deviceMotion {
            let rate = reading.rotationRate, acceleration = reading.userAcceleration
            if sqrt(rate.x * rate.x + rate.y * rate.y + rate.z * rate.z) > 0.15 ||
                sqrt(acceleration.x * acceleration.x + acceleration.y * acceleration.y + acceleration.z * acceleration.z) > 0.08 {
                movingUntil = now + 0.75
            }
        }
        do {
            // The output connection physically rotates the buffer; Vision sees an upright,
            // unmirrored image. The preview performs the mirror only for display.
            let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up, options: [:])
            try handler.perform([pose2D])
            let observations = pose2D.results ?? []
            var rawJoints: [BodyJoint: PoseJoint] = [:]
            if let body = observations.first {
                for joint in configuration.trackedJoints {
                    guard let point2D = try? body.recognizedPoint(joint.vision2DName) else { continue }
                    let observed = SIMD2(Float(point2D.location.x), Float(point2D.location.y))
                    rawJoints[joint] = PoseJoint(position: observed,
                                                  imagePoint: observed,
                                                  confidence2D: point2D.confidence)
                }
            }
            if !didSetCameraTarget, let target = configuration.cameraTarget(rawJoints), let device {
                // Vision image points start at the lower left; AVCapture points start at the upper left.
                configureAutomaticFocusAndExposure(on: device,
                                                    at: CGPoint(x: CGFloat(target.x), y: CGFloat(1 - target.y)))
                didSetCameraTarget = true
            }
            let joints = poseStabilizer.stabilize(rawJoints,
                                                  tracking: configuration.trackedJoints,
                                                  at: now)
            failures = 0
            let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
            let aspect = imageBuffer.map { Double(CVPixelBufferGetWidth($0)) / Double(CVPixelBufferGetHeight($0)) } ?? 9.0 / 16
            emit(.frame(PoseFrame(timestamp: now, joints: joints,
                                  cameraIsMoving: now < movingUntil, imageAspectRatio: aspect),
                        milliseconds: (ProcessInfo.processInfo.systemUptime - now) * 1000))
        } catch {
            failures += 1
            emit(.frame(PoseFrame(timestamp: now, joints: [:]), milliseconds: 0))
            if failures >= 3 {
                emit(.state(.failed("Body tracking is unavailable. Try again with the required joints visible.")))
                active = false
                motion.stopDeviceMotionUpdates()
                session.stopRunning()
            }
        }
    }
}

nonisolated private extension BodyJoint {
    var vision2DName: VNHumanBodyPoseObservation.JointName {
        switch self {
        case .leftShoulder: .leftShoulder
        case .leftElbow: .leftElbow
        case .leftWrist: .leftWrist
        case .leftHip: .leftHip
        case .leftKnee: .leftKnee
        case .leftAnkle: .leftAnkle
        case .rightShoulder: .rightShoulder
        case .rightElbow: .rightElbow
        case .rightWrist: .rightWrist
        case .rightHip: .rightHip
        case .rightKnee: .rightKnee
        case .rightAnkle: .rightAnkle
        }
    }
}
