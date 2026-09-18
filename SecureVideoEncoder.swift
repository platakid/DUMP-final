import AVFoundation
import VideoToolbox

/// Input methods and finish/cancel run on the camera's serial queue.
/// VideoToolbox callbacks use sinkLock, never that queue (draining cannot deadlock).
final class SecureVideoEncoder {
    private let lease: SessionLease
    private var writer: MediaWriter?
    private var compression: VTCompressionSession?
    private let sinkLock = NSLock()
    private let slots = DispatchSemaphore(value: 3)
    private var failure: Error?
    private var closed = false
    private var origin: CMTime?
    private var lastVideoInput = -1.0
    private var lastVideoOutput = -1.0
    private var lastAudioOutput = -1.0
    private var endTime = 0.0
    private var videoCount = 0
    private var audioCount = 0
    private var audioFormat: SecureVideoFormat.Audio?
    private var width = 0
    private var height = 0

    init(store: MediaStore, master: SecretBytes, lease: SessionLease) throws {
        self.lease = lease
        let writer = try MediaWriter(store: store, master: master, lease: lease)
        self.writer = writer
        try writer.append(SecureVideoFormat.magic)
    }

    func video(_ sample: CMSampleBuffer) throws {
        try lease.check()
        try sinkLock.withLock {
            if let failure { throw failure }
            guard !closed else { throw VaultError.locked }
        }
        guard let image = CMSampleBufferGetImageBuffer(sample) else { throw VaultError.unavailable }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isNumeric else { throw VaultError.damaged }
        if origin == nil { origin = pts }
        let relative = CMTimeSubtract(pts, origin!)
        let seconds = relative.seconds
        guard seconds.isFinite, seconds >= 0, seconds <= SecureVideoFormat.maximumDuration else {
            throw VaultError.unavailable
        }
        guard seconds > lastVideoInput else { return }
        // Backpressure: drop frames before handing them to VT, never enqueue an
        // unbounded collection of camera-owned CVPixelBuffers.
        guard slots.wait(timeout: .now()) == .success else { return }
        do {
            if compression == nil { try configure(image) }
            guard width == CVPixelBufferGetWidth(image), height == CVPixelBufferGetHeight(image),
                  let compression else { throw VaultError.unavailable }
            lastVideoInput = seconds
            let status = VTCompressionSessionEncodeFrame(compression, imageBuffer: image,
                presentationTimeStamp: relative, duration: CMTime(value: 1, timescale: 30),
                frameProperties: nil, infoFlagsOut: nil) { [self] status, flags, encoded in
                    defer { slots.signal() }
                    sinkLock.withLock {
                        guard !closed, failure == nil else { return }
                        do {
                            try lease.check()
                            guard status == noErr else { throw VaultError.unavailable }
                            if flags.contains(.frameDropped) { return }
                            guard let encoded else { throw VaultError.unavailable }
                            try writeVideo(encoded)
                        } catch { failure = error }
                    }
                }
            // On a nonzero return VT does not accept the frame/callback.
            guard status == noErr else { throw VaultError.unavailable }
        } catch {
            slots.signal()
            throw error
        }
    }

    private func configure(_ image: CVPixelBuffer) throws {
        width = CVPixelBufferGetWidth(image); height = CVPixelBufferGetHeight(image)
        guard width > 0, height > 0, width <= 1280, height <= 1280 else { throw VaultError.unavailable }
        let specification = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
        guard VTCompressionSessionCreate(allocator: kCFAllocatorDefault,
            width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: specification, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &compression) == noErr, let compression else {
            throw VaultError.unavailable
        }
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_Baseline_AutoLevel,
            kVTCompressionPropertyKey_AverageBitRate: 3_000_000,
            kVTCompressionPropertyKey_ExpectedFrameRate: 30,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: 30
        ]
        guard VTSessionSetProperties(compression, propertyDictionary: properties as CFDictionary) == noErr,
              VTCompressionSessionPrepareToEncodeFrames(compression) == noErr else {
            throw VaultError.unavailable
        }
    }

    private func writeVideo(_ sample: CMSampleBuffer) throws {
        guard let writer, CMSampleBufferDataIsReady(sample),
              let format = CMSampleBufferGetFormatDescription(sample),
              let block = CMSampleBufferGetDataBuffer(sample) else { throw VaultError.damaged }
        func parameter(_ index: Int) throws -> Data {
            var pointer: UnsafePointer<UInt8>?
            var count = 0
            var length: Int32 = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format,
                parameterSetIndex: index, parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &count, parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: &length) == noErr,
                let pointer, (1...4096).contains(count), length == 4 else { throw VaultError.damaged }
            return Data(bytes: pointer, count: count)
        }
        let seconds = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        guard seconds > lastVideoOutput else { throw VaultError.damaged }
        var metadata = SecureVideoFormat.Metadata(kind: 1, seconds: seconds,
            duration: 1.0 / 30, samples: 1, sps: try parameter(0), pps: try parameter(1))
        defer { metadata.sps?.wipe(); metadata.pps?.wipe() }
        var bytes = try copy(block)
        defer { bytes.wipe() }
        try SecureVideoFormat.append(metadata, payload: bytes, to: writer)
        lastVideoOutput = seconds
        endTime = max(endTime, seconds)
        videoCount += 1
    }

    func audio(_ sample: CMSampleBuffer) throws {
        try lease.check()
        // Wait for the first video timestamp so both tracks share one clock.
        guard let origin else { return }
        let seconds = CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(sample), origin).seconds
        guard seconds.isFinite else { throw VaultError.damaged }
        if seconds < 0 { return }
        guard seconds <= SecureVideoFormat.maximumDuration,
              let format = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format),
              let block = CMSampleBufferGetDataBuffer(sample) else { throw VaultError.unavailable }
        let pcm = try SecureVideoFormat.Audio(asbd.pointee)
        let count = CMSampleBufferGetNumSamples(sample)
        let metadata = SecureVideoFormat.Metadata(kind: 2, seconds: seconds,
            duration: Double(count) / pcm.rate, samples: count, audio: pcm)
        var bytes = try copy(block)
        defer { bytes.wipe() }
        try sinkLock.withLock {
            try lease.check()
            if let failure { throw failure }
            guard !closed, let writer, seconds > lastAudioOutput,
                  audioFormat == nil || audioFormat == pcm else { throw VaultError.unavailable }
            try SecureVideoFormat.append(metadata, payload: bytes, to: writer)
            audioFormat = pcm
            lastAudioOutput = seconds
            endTime = max(endTime, seconds)
            audioCount += 1
        }
    }

    private func copy(_ block: CMBlockBuffer) throws -> Data {
        let count = CMBlockBufferGetDataLength(block)
        guard (1...SecureVideoFormat.maximumPayload).contains(count) else { throw VaultError.damaged }
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: $0.baseAddress!)
        }
        guard status == noErr else { bytes.wipe(); throw VaultError.damaged }
        return bytes
    }

    func finish() throws -> MediaInfo {
        try lease.check()
        if let compression {
            guard VTCompressionSessionCompleteFrames(compression, untilPresentationTimeStamp: .invalid) == noErr else {
                throw VaultError.unavailable
            }
            VTCompressionSessionInvalidate(compression)
            self.compression = nil
        }
        return try sinkLock.withLock {
            try lease.check()
            if let failure { throw failure }
            guard !closed, videoCount > 0, audioCount > 0, let writer else { throw VaultError.unavailable }
            closed = true
            try SecureVideoFormat.append(.init(kind: 3, seconds: endTime, duration: 0, samples: 0),
                                         payload: Data(), to: writer)
            let result = try writer.finish(name: "Video-\(UUID().uuidString.prefix(8)).dumpvideo",
                                           typeIdentifier: SecureVideoFormat.typeIdentifier)
            self.writer = nil
            return result
        }
    }

    func cancel() {
        // Do not hold sinkLock while invalidating VT (callbacks take that lock).
        sinkLock.withLock { closed = true }
        if let compression {
            VTCompressionSessionInvalidate(compression)
            self.compression = nil
        }
        sinkLock.withLock { writer = nil }
    }

    deinit { cancel() }
}
