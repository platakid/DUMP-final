import AVFoundation

/// Framing only: ALL bytes, including this header and codec metadata, are passed
/// through MediaWriter. Authentication, random keys and AAD remain its job.
enum SecureVideoFormat {
    static let typeIdentifier = "local.dump.secure-video"
    static let magic = Data("DUMPVID1".utf8)
    static let maximumPayload = MediaFormat.chunkSize
    static let maximumMetadata = 16_384
    static let maximumDuration = 600.0

    struct Audio: Codable, Equatable {
        var rate: Double
        var flags: UInt32
        var bytesPerFrame: UInt32
        var channels: UInt32
        var bits: UInt32

        init(_ description: AudioStreamBasicDescription) throws {
            guard description.mFormatID == kAudioFormatLinearPCM,
                  description.mFramesPerPacket == 1,
                  description.mBytesPerPacket == description.mBytesPerFrame else {
                throw VaultError.unavailable
            }
            rate = description.mSampleRate
            flags = description.mFormatFlags
            bytesPerFrame = description.mBytesPerFrame
            channels = description.mChannelsPerFrame
            bits = description.mBitsPerChannel
            try validate()
        }

        func validate() throws {
            // AVCapture supplies interleaved LPCM. Reject unknown layouts;
            // never reinterpret planar channels as contiguous interleaved data.
            guard rate.isFinite, (8_000...96_000).contains(rate),
                  (1...2).contains(channels), [16, 32].contains(bits),
                  bytesPerFrame == channels * (bits / 8),
                  flags & kAudioFormatFlagIsNonInterleaved == 0,
                  flags & kAudioFormatFlagIsBigEndian == 0,
                  flags & kAudioFormatFlagIsPacked != 0,
                  flags & ~(kAudioFormatFlagIsFloat | kAudioFormatFlagIsSignedInteger |
                            kAudioFormatFlagIsPacked) == 0,
                  (flags & kAudioFormatFlagIsFloat == 0 || bits == 32),
                  (flags & kAudioFormatFlagIsFloat != 0) !=
                    (flags & kAudioFormatFlagIsSignedInteger != 0) else {
                throw VaultError.damaged
            }
        }

        func format() throws -> CMAudioFormatDescription {
            try validate()
            var asbd = AudioStreamBasicDescription(mSampleRate: rate,
                mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags,
                mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1,
                mBytesPerFrame: bytesPerFrame, mChannelsPerFrame: channels,
                mBitsPerChannel: bits, mReserved: 0)
            var result: CMAudioFormatDescription?
            guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                magicCookie: nil, extensions: nil, formatDescriptionOut: &result) == noErr,
                let result else { throw VaultError.damaged }
            return result
        }
    }

    struct Metadata: Codable {
        // 1 = H.264 AVCC (4-byte NAL lengths), 2 = interleaved LPCM, 3 = end.
        var kind: Int
        var seconds: Double
        var duration: Double
        var samples: Int
        var sps: Data? = nil
        var pps: Data? = nil
        var audio: Audio? = nil

        func validate(payloadCount: Int) throws {
            guard seconds.isFinite, duration.isFinite,
                  (0...SecureVideoFormat.maximumDuration).contains(seconds),
                  (0...1).contains(duration),
                  (0...SecureVideoFormat.maximumPayload).contains(payloadCount) else {
                throw VaultError.damaged
            }
            switch kind {
            case 1:
                guard samples == 1, payloadCount > 4, duration > 0,
                      let sps, let pps, (1...4096).contains(sps.count),
                      (1...4096).contains(pps.count), audio == nil else {
                    throw VaultError.damaged
                }
            case 2:
                guard let audio, sps == nil, pps == nil, (1...96_000).contains(samples),
                      payloadCount == samples * Int(audio.bytesPerFrame), duration > 0 else {
                    throw VaultError.damaged
                }
                try audio.validate()
                guard abs(duration - Double(samples) / audio.rate) < 0.00001 else {
                    throw VaultError.damaged
                }
            case 3:
                guard samples == 0, payloadCount == 0, duration == 0,
                      audio == nil, sps == nil, pps == nil else { throw VaultError.damaged }
            default: throw VaultError.damaged
            }
        }
    }

    static func append(_ metadata: Metadata, payload: Data, to writer: MediaWriter) throws {
        try metadata.validate(payloadCount: payload.count)
        var json = try JSONEncoder().encode(metadata)
        defer { json.wipe() }
        guard json.count <= maximumMetadata else { throw VaultError.damaged }
        try writer.append(MediaFormat.integer(UInt32(json.count)))
        try writer.append(MediaFormat.integer(UInt32(payload.count)))
        try writer.append(json)
        try writer.append(payload)
    }
}

/// One bounded packet at a time; no movie-sized plaintext cache or index.
final class SecureVideoReader {
    let reader: MediaReader
    private var offset: UInt64 = 8
    private var ended = false
    private var videoTime = -1.0
    private var audioTime = -1.0
    private var audioFormat: SecureVideoFormat.Audio?
    private var videoSPS: Data?
    private var videoPPS: Data?
    private var cache = Data()
    private var cacheOffset: UInt64 = 0

    init(_ reader: MediaReader) throws {
        self.reader = reader
        var header = try reader.read(offset: 0, count: 8)
        defer { header.wipe() }
        guard reader.info.typeIdentifier == SecureVideoFormat.typeIdentifier,
              header == SecureVideoFormat.magic else { throw VaultError.damaged }
    }

    func next() throws -> (SecureVideoFormat.Metadata, Data)? {
        // Validate the underlying lease even when plaintext is already cached.
        _ = try reader.read(offset: 0, count: 0)
        if ended { return nil }
        var sizes = try take(8)
        defer { sizes.wipe() }
        let metadataCount = Int(try MediaFormat.uint32(Data(sizes.prefix(4))))
        let payloadCount = Int(try MediaFormat.uint32(Data(sizes.suffix(4))))
        guard (1...SecureVideoFormat.maximumMetadata).contains(metadataCount),
              (0...SecureVideoFormat.maximumPayload).contains(payloadCount) else {
            throw VaultError.damaged
        }
        var json = try take(metadataCount)
        defer { json.wipe() }
        let metadata = try JSONDecoder().decode(SecureVideoFormat.Metadata.self, from: json)
        try metadata.validate(payloadCount: payloadCount)
        switch metadata.kind {
        case 1:
            guard metadata.seconds > videoTime,
                  videoSPS == nil || (videoSPS == metadata.sps && videoPPS == metadata.pps) else {
                throw VaultError.damaged
            }
            videoTime = metadata.seconds
            videoSPS = metadata.sps; videoPPS = metadata.pps
        case 2:
            guard metadata.seconds > audioTime,
                  audioFormat == nil || audioFormat == metadata.audio else { throw VaultError.damaged }
            audioTime = metadata.seconds; audioFormat = metadata.audio
        case 3:
            guard videoTime >= 0, audioTime >= 0, offset == reader.info.byteCount,
                  metadata.seconds >= max(videoTime, audioTime) else { throw VaultError.damaged }
            ended = true
            return nil
        default: throw VaultError.damaged
        }
        return (metadata, try take(payloadCount))
    }

    private func take(_ count: Int) throws -> Data {
        _ = try reader.read(offset: 0, count: 0)
        guard offset <= reader.info.byteCount,
              UInt64(count) <= reader.info.byteCount - offset else { throw VaultError.damaged }
        var data = Data()
        data.reserveCapacity(count)
        do {
            while data.count < count {
                if cache.isEmpty || offset < cacheOffset || offset >= cacheOffset + UInt64(cache.count) {
                    cache.wipe()
                    cacheOffset = offset
                    cache = try reader.read(offset: offset,
                        count: Int(min(UInt64(MediaFormat.chunkSize), reader.info.byteCount - offset)))
                }
                let start = Int(offset - cacheOffset)
                let amount = min(count - data.count, cache.count - start)
                guard amount > 0 else { throw VaultError.damaged }
                data.append(cache[start..<(start + amount)])
                offset += UInt64(amount)
            }
            return data
        } catch { data.wipe(); throw error }
    }

    func close() {
        ended = true
        cache.wipe(); videoSPS?.wipe(); videoPPS?.wipe()
        reader.close()
    }
    deinit { close() }
}

enum SecureVideoSamples {
    static func videoFormat(sps: Data, pps: Data) throws -> CMVideoFormatDescription {
        var result: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { p in
                let pointers = [s.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                p.baseAddress!.assumingMemoryBound(to: UInt8.self)]
                let sizes = [sps.count, pps.count]
                return pointers.withUnsafeBufferPointer { pointers in
                    sizes.withUnsafeBufferPointer { sizes in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault, parameterSetCount: 2,
                            parameterSetPointers: pointers.baseAddress!,
                            parameterSetSizes: sizes.baseAddress!, nalUnitHeaderLength: 4,
                            formatDescriptionOut: &result)
                    }
                }
            }
        }
        guard status == noErr, let result else { throw VaultError.damaged }
        let dimensions = CMVideoFormatDescriptionGetDimensions(result)
        guard dimensions.width > 0, dimensions.height > 0,
              dimensions.width <= 1280, dimensions.height <= 1280 else { throw VaultError.damaged }
        return result
    }

    static func make(_ metadata: SecureVideoFormat.Metadata, payload: Data) throws -> CMSampleBuffer {
        try metadata.validate(payloadCount: payload.count)
        let format: CMFormatDescription
        let sampleSize: Int
        var sync = true
        if metadata.kind == 1, let sps = metadata.sps, let pps = metadata.pps {
            // Validate AVCC boundaries before submitting bytes to the decoder.
            var cursor = 0
            sync = false
            while cursor < payload.count {
                guard payload.count - cursor >= 4 else { throw VaultError.damaged }
                let length = Int(try MediaFormat.uint32(payload.subdata(in: cursor..<(cursor + 4))))
                cursor += 4
                guard length > 0, length <= payload.count - cursor else { throw VaultError.damaged }
                if payload[cursor] & 0x1f == 5 { sync = true }
                cursor += length
            }
            format = try videoFormat(sps: sps, pps: pps)
            sampleSize = payload.count
        } else if metadata.kind == 2, let audio = metadata.audio {
            format = try audio.format()
            sampleSize = Int(audio.bytesPerFrame)
        } else { throw VaultError.damaged }

        // CoreMedia owns this separate allocation until its last renderer user
        // releases it. Wipe ONLY in that final-owner callback, never on enqueue.
        let memory = UnsafeMutableRawPointer.allocate(byteCount: payload.count, alignment: 16)
        payload.copyBytes(to: memory.assumingMemoryBound(to: UInt8.self), count: payload.count)
        var source = CMBlockBufferCustomBlockSource(version: 0, AllocateBlock: nil,
            FreeBlock: { _, pointer, size in
                SodiumRuntime.wipe(pointer, count: size)
                pointer.deallocate()
            }, refCon: nil)
        var block: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
            memoryBlock: memory, blockLength: payload.count, blockAllocator: nil,
            customBlockSource: &source, offsetToData: 0, dataLength: payload.count,
            flags: 0, blockBufferOut: &block)
        guard status == noErr, let block else {
            SodiumRuntime.wipe(memory, count: payload.count); memory.deallocate()
            throw VaultError.unavailable
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(seconds: metadata.duration / Double(metadata.samples), preferredTimescale: 1_000_000_000),
            presentationTimeStamp: CMTime(seconds: metadata.seconds, preferredTimescale: 1_000_000_000),
            decodeTimeStamp: .invalid)
        var size = sampleSize
        var result: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: format, sampleCount: metadata.samples,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &result) == noErr, let result else { throw VaultError.damaged }
        if metadata.kind == 1, !sync {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(result, createIfNecessary: true),
                  CFArrayGetCount(attachments) > 0 else { throw VaultError.damaged }
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return result
    }
}
