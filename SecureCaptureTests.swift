import XCTest
import AVFoundation
@testable import DUMP

final class SecureCaptureTests: XCTestCase {
    private var store: MediaStore!
    private var lease: SessionLease!
    private var master: SecretBytes!

    override func setUpWithError() throws {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        store = try MediaStore(directory: base.appendingPathComponent("DUMPCaptureTests-" + UUID().uuidString))
        lease = SessionLease()
        master = try lease.own(AESBox.generateKey())
    }
    override func tearDownWithError() throws {
        lease.revoke()
        try FileManager.default.removeItem(at: store.directory)
    }

    private func pcm() throws -> SecureVideoFormat.Audio {
        try SecureVideoFormat.Audio(AudioStreamBasicDescription(mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0))
    }

    private func writeFixture(end: Bool = true, trailing: Bool = false) throws -> MediaInfo {
        let writer = try MediaWriter(store: store, master: master, lease: lease)
        try writer.append(SecureVideoFormat.magic)
        // Framing fixtures deliberately do not claim to be decodable H.264.
        try SecureVideoFormat.append(.init(kind: 1, seconds: 0, duration: 1.0 / 30,
            samples: 1, sps: Data([0x67]), pps: Data([0x68])),
            payload: Data([0, 0, 0, 1, 0x65]), to: writer)
        try SecureVideoFormat.append(.init(kind: 2, seconds: 0, duration: 0.01,
            samples: 480, audio: try pcm()), payload: Data(repeating: 0x12, count: 960), to: writer)
        if end {
            try SecureVideoFormat.append(.init(kind: 3, seconds: 0, duration: 0, samples: 0), payload: Data(), to: writer)
        }
        if trailing { try writer.append(Data([42])) }
        return try writer.finish(name: "fixture.dumpvideo", typeIdentifier: SecureVideoFormat.typeIdentifier)
    }

    private func open(_ info: MediaInfo) throws -> SecureVideoReader {
        try SecureVideoReader(MediaReader(url: store.url(info.id), id: info.id, master: master, lease: lease))
    }

    func testAuthenticatedContainerRoundTripAndEnd() throws {
        let source = try open(writeFixture())
        defer { source.close() }
        XCTAssertEqual(try source.next()?.0.kind, 1)
        var audio = try XCTUnwrap(source.next())
        defer { audio.1.wipe() }
        XCTAssertEqual(audio.1, Data(repeating: 0x12, count: 960))
        XCTAssertEqual(audio.0.samples, 480)
        XCTAssertNil(try source.next())
    }

    func testMissingEndAndTrailingBytesRejected() throws {
        for options in [(false, false), (true, true)] {
            let source = try open(writeFixture(end: options.0, trailing: options.1))
            defer { source.close() }
            _ = try source.next(); _ = try source.next()
            XCTAssertThrowsError(try source.next())
        }
    }

    func testRevocationRejectsAlreadyCachedPlaintext() throws {
        let source = try open(writeFixture())
        defer { source.close() }
        _ = try source.next()
        lease.revoke()
        XCTAssertThrowsError(try source.next())
    }

    func testHostileLengthRejectedBeforeAllocation() throws {
        let writer = try MediaWriter(store: store, master: master, lease: lease)
        try writer.append(SecureVideoFormat.magic)
        try writer.append(MediaFormat.integer(UInt32.max))
        try writer.append(MediaFormat.integer(UInt32.max))
        let info = try writer.finish(name: "bad", typeIdentifier: SecureVideoFormat.typeIdentifier)
        let source = try open(info)
        defer { source.close() }
        XCTAssertThrowsError(try source.next())
    }

    func testPCMLayoutAndPacketSizeValidation() throws {
        var format = try pcm()
        format.flags |= kAudioFormatFlagIsNonInterleaved
        XCTAssertThrowsError(try format.validate())
        let metadata = SecureVideoFormat.Metadata(kind: 2, seconds: 0, duration: 0.01,
            samples: 480, audio: try pcm())
        XCTAssertThrowsError(try metadata.validate(payloadCount: 959))
        XCTAssertNoThrow(try metadata.validate(payloadCount: 960))
        var nonfinite = metadata
        nonfinite.seconds = .infinity
        XCTAssertThrowsError(try nonfinite.validate(payloadCount: 960))
    }

    func testPCMCoreMediaSampleOwnsIndependentBytes() throws {
        let metadata = SecureVideoFormat.Metadata(kind: 2, seconds: 0, duration: 0.01,
            samples: 480, audio: try pcm())
        var bytes = Data(repeating: 0x12, count: 960)
        let sample = try SecureVideoSamples.make(metadata, payload: bytes)
        bytes.wipe()
        let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
        var copy = Data(count: 960)
        defer { copy.wipe() }
        let status = copy.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: 960, destination: $0.baseAddress!)
        }
        XCTAssertEqual(status, noErr)
        XCTAssertEqual(copy, Data(repeating: 0x12, count: 960))
    }

    func testEncoderCancellationRemovesPartialWithoutHardware() throws {
        let encoder = try SecureVideoEncoder(store: store, master: master, lease: lease)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).count, 1)
        encoder.cancel()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).isEmpty)
        XCTAssertThrowsError(try encoder.finish())
    }

    @MainActor
    func testCameraCancellationKeepsVaultMasterUsable() throws {
        let camera = try SecureCamera(store: store, master: master) { _ in XCTFail("No capture requested") }
        camera.cancel()
        var copy = try master.copyData()
        defer { copy.wipe() }
        XCTAssertEqual(copy.count, 32)
        XCTAssertNoThrow(try lease.check())
    }
}
