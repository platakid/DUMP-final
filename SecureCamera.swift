import SwiftUI
import AVFoundation

/// A fresh object and private revocable lease for each camera presentation.
/// Never retain the vault master itself: use a separately owned copy that is
/// destroyed on cancel even when the vault remains unlocked.
final class SecureCamera: NSObject, ObservableObject,
    AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate,
    AVCapturePhotoCaptureDelegate {
    enum Mode: String, CaseIterable { case photo = "Photo", video = "Video" }
    @Published private(set) var mode: Mode = .photo
    @Published private(set) var ready = false
    @Published private(set) var recording = false
    @Published private(set) var processing = false
    @Published private(set) var flash = false
    @Published private(set) var flashAvailable = false
    @Published private(set) var status = "Preparing camera…"
    @Published private(set) var recordingStarted: Date?
    @MainActor private(set) var requestingPermission = false
    @MainActor private var started = false

    let session = AVCaptureSession()
    // All presentations share a hardware queue: an old teardown must complete
    // before a newly opened camera can activate the shared audio session.
    private static let hardwareQueue = DispatchQueue(label: "local.dump.camera", qos: .userInitiated)
    private let queue = SecureCamera.hardwareQueue
    private let lease: SessionLease
    private let master: SecretBytes
    private let store: MediaStore
    private let gate = NSLock()
    private var cancelled = false
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    // Everything below is owned exclusively by queue.
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var encoder: SecureVideoEncoder?
    private var photoID: Int64?
    private var captureMode: Mode = .photo
    private var useFlash = false
    private var audioActive = false
    private var limitTimer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private let saved: @MainActor (MediaInfo) -> Void

    @MainActor
    init(store: MediaStore, master: SecretBytes, saved: @escaping @MainActor (MediaInfo) -> Void) throws {
        self.store = store
        let captureLease = SessionLease()
        self.lease = captureLease
        var bytes = try master.copyData()
        defer { bytes.wipe() }
        self.master = try captureLease.own(SecretBytes(bytes))
        self.saved = saved
        super.init()
        for name in [AVCaptureSession.wasInterruptedNotification, AVCaptureSession.runtimeErrorNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) {
                [weak self] _ in self?.fail("Camera interrupted. Unfinished capture discarded. Close and reopen the camera.")
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
            object: nil, queue: nil) { [weak self] _ in
                self?.fail("Audio interrupted. Unfinished capture discarded. Close and reopen the camera.")
            })
    }

    private var live: Bool { gate.withLock { !cancelled } }

    private func publish(_ body: @escaping @MainActor (SecureCamera) -> Void) {
        Task { @MainActor [weak self] in
            guard let self, self.live else { return }
            body(self)
        }
    }

    @MainActor
    func start() async {
        guard !started, live else { return }
        started = true
        requestingPermission = true
        let allowed = await Self.permission(.video)
        requestingPermission = false
        guard live else { return }
        guard allowed else {
            status = "Allow Camera access in iOS Settings, then reopen the camera."
            return
        }
        queue.async { [self] in
            do {
                try lease.check()
                try configure(position: .back)
                try lease.check()
                session.startRunning()
                try lease.check()
                publish { $0.ready = true; $0.status = "Saved only in your encrypted vault" }
            } catch { fail("Camera unavailable. Close and try again.") }
        }
    }

    @MainActor
    private static func permission(_ type: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: type)
        default: return false
        }
    }

    private func configure(position: AVCaptureDevice.Position) throws {
        try lease.check()
        session.beginConfiguration()
        var configuring = true
        defer { if configuring { session.commitConfiguration() } }
        session.automaticallyConfiguresApplicationAudioSession = false
        guard session.canSetSessionPreset(.hd1280x720) else { throw VaultError.unavailable }
        session.sessionPreset = .hd1280x720
        if let videoInput { session.removeInput(videoInput); self.videoInput = nil }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            throw VaultError.unavailable
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw VaultError.unavailable }
        session.addInput(input); videoInput = input
        if !session.outputs.contains(photoOutput) {
            guard session.canAddOutput(photoOutput), session.canAddOutput(videoOutput) else { throw VaultError.unavailable }
            session.addOutput(photoOutput)
            session.addOutput(videoOutput)
            photoOutput.maxPhotoQualityPrioritization = .balanced
            videoOutput.alwaysDiscardsLateVideoFrames = true
            let pixelFormat = videoOutput.availableVideoPixelFormatTypes.contains(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
                ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            guard videoOutput.availableVideoPixelFormatTypes.contains(pixelFormat) else { throw VaultError.unavailable }
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
            videoOutput.setSampleBufferDelegate(self, queue: queue)
            audioOutput.setSampleBufferDelegate(self, queue: queue)
        }
        // Fix sensor output to upright portrait. UI may rotate, capture does not
        // change dimensions or orientation midway through a recording.
        for output in [photoOutput as AVCaptureOutput, videoOutput] {
            if let connection = output.connection(with: .video) {
                if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = false
                }
            }
        }
        session.commitConfiguration()
        configuring = false
        try lease.check()
        // Inspect the actual format selected by the committed session preset.
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        let dimensions = device.activeFormat.supportedMaxPhotoDimensions
            .filter { $0.width > 0 && $0.height > 0 && Int64($0.width) * Int64($0.height) <= 12_600_000 }
            .min { Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height) }
        guard let dimensions else { throw VaultError.unavailable }
        photoOutput.maxPhotoDimensions = dimensions
        if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) {
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
        }
        useFlash = false
        let available = captureMode == .photo && device.hasFlash
        publish { $0.flash = false; $0.flashAvailable = available }
    }

    @MainActor
    func select(_ newMode: Mode) async {
        guard live, ready, !processing, !recording, mode != newMode else { return }
        processing = true
        if newMode == .video {
            requestingPermission = true
            let allowed = await Self.permission(.audio)
            requestingPermission = false
            guard live else { return }
            guard allowed else {
                processing = false
                status = "Video needs microphone access. Allow it in iOS Settings."
                return
            }
        }
        queue.async { [self] in
            do {
                try lease.check()
                if newMode == .video { try attachAudio() } else { detachAudio() }
                captureMode = newMode
                useFlash = false
                let available = newMode == .photo && videoInput?.device.hasFlash == true
                publish {
                    $0.mode = newMode; $0.processing = false; $0.flash = false
                    $0.flashAvailable = available
                    $0.status = newMode == .video ? "Video with audio · up to 10 minutes" : "Saved only in your encrypted vault"
                }
            } catch { fail("Microphone unavailable. Close and try again.") }
        }
    }

    private func attachAudio() throws {
        try lease.check()
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker])
        try audio.setActive(true)
        audioActive = true
        guard let device = AVCaptureDevice.default(for: .audio) else { throw VaultError.unavailable }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(input), session.canAddOutput(audioOutput) else { throw VaultError.unavailable }
        session.addInput(input); audioInput = input
        session.addOutput(audioOutput)
    }

    private func detachAudio() {
        session.beginConfiguration()
        if let audioInput { session.removeInput(audioInput); self.audioInput = nil }
        if session.outputs.contains(audioOutput) { session.removeOutput(audioOutput) }
        session.commitConfiguration()
        if audioActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            audioActive = false
        }
    }

    @MainActor
    func switchCamera() {
        guard ready, !processing, !recording else { return }
        processing = true
        queue.async { [self] in
            do {
                try configure(position: videoInput?.device.position == .back ? .front : .back)
                let available = captureMode == .photo && videoInput?.device.hasFlash == true
                publish { $0.processing = false; $0.flashAvailable = available }
            } catch { fail("This camera is unavailable. Close and try again.") }
        }
    }

    @MainActor
    func toggleFlash() {
        guard live, ready, !processing, !recording, flashAvailable, mode == .photo else { return }
        flash.toggle()
        let enabled = flash
        queue.async { [self] in useFlash = enabled }
    }

    @MainActor
    func capturePhoto() {
        guard live, ready, mode == .photo, !processing else { return }
        processing = true
        queue.async { [self] in
            do {
                try lease.check()
                guard photoID == nil, encoder == nil,
                      photoOutput.availablePhotoCodecTypes.contains(.jpeg) else { throw VaultError.unavailable }
                let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
                settings.photoQualityPrioritization = .balanced
                let requested: AVCaptureDevice.FlashMode = useFlash ? .on : .off
                if photoOutput.supportedFlashModes.contains(requested) { settings.flashMode = requested }
                photoID = settings.uniqueID
                photoOutput.capturePhoto(with: settings, delegate: self)
            } catch { fail("Photo capture failed. No photo was saved.") }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        // Only one outstanding photo. Never write to Photos or to a plaintext URL.
        queue.async { [self] in
            guard live else { return }
            do {
                try lease.check()
                guard error == nil, photoID == photo.resolvedSettings.uniqueID else { throw VaultError.unavailable }
                defer { photoID = nil }
                guard var bytes = photo.fileDataRepresentation() else { throw VaultError.unavailable }
                defer { bytes.wipe() }
                guard !bytes.isEmpty, bytes.count <= 32 * 1_048_576 else { throw VaultError.unavailable }
                let writer = try MediaWriter(store: store, master: master, lease: lease)
                try writer.append(bytes)
                let result = try writer.finish(name: "Photo-\(UUID().uuidString.prefix(8)).jpg", typeIdentifier: "public.jpeg")
                publish { camera in
                    camera.processing = false; camera.status = "Photo saved in DUMP"
                    camera.saved(result)
                }
            } catch { fail("Photo capture failed. Unfinished encrypted data discarded.") }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        if error != nil { fail("Photo capture failed. Close and try again.") }
    }

    @MainActor
    func startVideo() {
        guard live, ready, mode == .video, !processing, !recording else { return }
        processing = true
        queue.async { [self] in
            do {
                try lease.check()
                guard encoder == nil, audioInput != nil else { throw VaultError.unavailable }
                encoder = try SecureVideoEncoder(store: store, master: master, lease: lease)
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + SecureVideoFormat.maximumDuration - 1)
                timer.setEventHandler { [weak self] in self?.finishVideo() }
                limitTimer = timer; timer.resume()
                publish {
                    $0.recording = true; $0.recordingStarted = Date(); $0.processing = false
                    $0.status = "Recording · encrypted as you capture"
                }
            } catch { fail("Video recording could not start.") }
        }
    }

    @MainActor
    func stopVideo() {
        guard live, recording, !processing else { return }
        processing = true
        queue.async { [self] in finishVideo() }
    }

    private func finishVideo() {
        guard let encoder else { return }
        limitTimer?.cancel(); limitTimer = nil
        publish { $0.processing = true; $0.status = "Verifying encrypted video…" }
        do {
            let result = try encoder.finish()
            self.encoder = nil
            publish { camera in
                camera.recording = false; camera.processing = false
                camera.recordingStarted = nil
                camera.status = "Video saved in DUMP"; camera.saved(result)
            }
        } catch { fail("Video could not be saved. Unfinished encrypted data discarded.") }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard live, let encoder else { return }
        do {
            if output === videoOutput { try encoder.video(sampleBuffer) }
            else if output === audioOutput { try encoder.audio(sampleBuffer) }
        } catch { fail("Recording failed or was interrupted. Unfinished capture discarded.") }
    }

    private func fail(_ message: String) {
        cancel()
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.ready = false; self.recording = false; self.recordingStarted = nil
            self.processing = false; self.status = message
        }
    }

    /// Synchronous revocation rejects late callbacks and destroys resource keys.
    /// Hardware stopRunning/invalidate executes off the UI thread; iOS does not
    /// provide an instantaneous, synchronous sensor/GPU/system-buffer wipe.
    func cancel(completion: (@MainActor () -> Void)? = nil) {
        gate.lock()
        defer { gate.unlock() }
        if !cancelled {
            cancelled = true
            lease.revoke()
            queue.async { [self] in
                limitTimer?.cancel(); limitTimer = nil
                videoOutput.setSampleBufferDelegate(nil, queue: nil)
                audioOutput.setSampleBufferDelegate(nil, queue: nil)
                encoder?.cancel(); encoder = nil; photoID = nil
                if session.isRunning { session.stopRunning() }
                detachAudio()
                session.beginConfiguration()
                session.inputs.forEach { session.removeInput($0) }
                session.outputs.forEach { session.removeOutput($0) }
                session.commitConfiguration()
                videoInput = nil
            }
        }
        // Enqueue under gate so this barrier cannot overtake another thread's
        // cancellation. Preview can activate audio only after this completes.
        if let completion {
            queue.async { Task { @MainActor in completion() } }
        }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        lease.revoke()
    }
}

private final class CameraSurface: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

private struct CameraPreviewSurface: UIViewRepresentable {
    let camera: SecureCamera
    func makeUIView(context: Context) -> CameraSurface {
        let view = CameraSurface()
        view.preview.videoGravity = .resizeAspect
        view.preview.session = camera.session
        if let connection = view.preview.connection, connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        return view
    }
    func updateUIView(_ uiView: CameraSurface, context: Context) {
        if let connection = uiView.preview.connection {
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
        }
    }
    static func dismantleUIView(_ uiView: CameraSurface, coordinator: ()) {
        uiView.preview.session = nil
    }
}

struct SecureCameraView: View {
    @ObservedObject var camera: SecureCamera
    @ObservedObject var model: AppModel
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreviewSurface(camera: camera).ignoresSafeArea()
            VStack(spacing: 18) {
                HStack {
                    Button { model.closeCamera() } label: {
                        Image(systemName: "xmark").padding(14).background(.ultraThinMaterial, in: Circle())
                    }.accessibilityLabel("Cancel and close camera")
                    Spacer()
                    Label("DUMP", systemImage: "lock.fill").font(.headline)
                    Spacer()
                    Button { camera.toggleFlash() } label: {
                        Image(systemName: camera.flash ? "bolt.fill" : "bolt.slash.fill")
                            .padding(14).background(.ultraThinMaterial, in: Circle())
                    }.disabled(!camera.flashAvailable || camera.processing || camera.recording)
                        .accessibilityLabel(camera.flash ? "Turn flash off" : "Turn flash on")
                }
                Spacer()
                if let started = camera.recordingStarted {
                    Text(started, style: .timer).monospacedDigit().foregroundStyle(.red)
                        .font(.title2.bold()).padding(8).background(.ultraThinMaterial, in: Capsule())
                }
                Text(camera.status).font(.footnote).multilineTextAlignment(.center)
                    .padding(12).background(.ultraThinMaterial, in: Capsule())
                    .accessibilityAddTraits(.updatesFrequently)
                HStack(spacing: 32) {
                    ForEach(SecureCamera.Mode.allCases, id: \.self) { mode in
                        Button(mode.rawValue) { Task { await camera.select(mode) } }
                            .font(.headline).foregroundStyle(camera.mode == mode ? .yellow : .white)
                            .disabled(camera.processing || camera.recording || !camera.ready)
                    }
                }
                HStack {
                    Image(systemName: "lock.shield").font(.title2).frame(width: 55)
                    Spacer()
                    Button {
                        if camera.mode == .photo { model.capturePhoto() }
                        else if camera.recording { model.stopVideo() }
                        else { model.startVideo() }
                    } label: {
                        ZStack {
                            Circle().stroke(.white, lineWidth: 4).frame(width: 80, height: 80)
                            if camera.processing { ProgressView().tint(.white) }
                            else if camera.recording { RoundedRectangle(cornerRadius: 6).fill(.red).frame(width: 32, height: 32) }
                            else { Circle().fill(camera.mode == .photo ? Color.white : Color.red).frame(width: 66, height: 66) }
                        }
                    }.disabled(!camera.ready || camera.processing)
                        .accessibilityLabel(camera.mode == .photo ? "Take photo" : camera.recording ? "Stop and save video" : "Record video")
                    Spacer()
                    Button { camera.switchCamera() } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera").font(.title2).frame(width: 55, height: 55)
                    }.disabled(!camera.ready || camera.processing || camera.recording)
                        .accessibilityLabel("Switch front or back camera")
                }
                Text("No automatic copy in Photos").font(.caption).foregroundStyle(.secondary)
            }.padding(24).foregroundStyle(.white)
        }.preferredColorScheme(.dark).interactiveDismissDisabled()
            .task { await camera.start() }
            .onDisappear { camera.cancel() }
    }
}
