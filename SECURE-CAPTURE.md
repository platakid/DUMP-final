# Secure in-app capture

## Changes

- `SecureCamera.swift`: full-screen camera, Photo/Video modes, front/back cameras, supported photo flash, permissions, recording timer, cancellation, and off-main-thread hardware teardown.
- `SecureVideoEncoder.swift`: hardware H.264, nominal 720p/30 fps, no frame reordering, and native interleaved LPCM audio streamed directly into `MediaWriter`. There is no movie-file recording fallback.
- `SecureVideoContainer.swift`: bounded sequential framing, strict parser, and in-memory CoreMedia sample reconstruction with final-owner memory wiping.
- `SecureVideoPlayback.swift`: synchronized sample-buffer video/audio rendering, play/pause, bounded read-ahead, cleanup, and AirPlay audio-route rejection.
- `MediaPreview.swift`: internal-video dispatch and cleanup. The existing image decoder and imported-movie memory resource loader are retained.
- `AppModel.swift`: camera actions, generation-checked save callbacks, synchronous camera-key revocation, and a teardown barrier before preview can activate audio.
- `VaultView.swift`: Add menu offers Take Photo/Video and Import from Photos; full-screen capture and internal-video playback.
- `DUMPApp.swift`: temporary inactivity cancels an opened camera except during its explicit permission request. Background locking is retained; protected-data unavailability also locks.
- `Info.plist` and `project.pbxproj`: privacy keys and explicit Compile Sources entries for all new Swift files.
- Password help and existing test fixtures now match the already-present 16-character policy. Eight capture tests and a portable project-structure check were added; Codemagic prepare runs the structural check.

## Storage and compatibility

Photos are captured as in-memory JPEG data and passed directly into the existing encrypted writer. Only one photo is in flight, using the smallest supported dimensions up to 12.6 megapixels, with a 32 MiB encoded-data rejection limit. There is no automatic Photos insertion, Live Photo recording, or intentional plaintext photo file.

Video uses `AVCaptureVideoDataOutput` → hardware VideoToolbox H.264 → bounded packets → `MediaWriter`. Audio comes from `AVCaptureAudioDataOutput` and is **uncompressed PCM, not AAC**. This avoids another asynchronous codec at the cost of larger files. All framing/codec metadata is encrypted too. The first persistent app-controlled media representation is encrypted vault data; the reserved empty header contains zeros until finalization.

`Crypto.swift`, `KeychainStore.swift`, and `MediaStore.swift` are byte-for-byte unchanged from the supplied archive. Random resource AES-256 keys, AES-GCM chunk authentication/AAD, encrypted metadata, file protection, backup exclusion, poisoned-writer behavior, verification before commit and encrypted partials are retained. The existing 16-character/Argon2id hardening remains. PhotosImporter.swift and PhotosExporter.swift are also unchanged.

Captured photos retain ordinary image preview and explicit export-to-Photos. Imported movies retain their playback/export paths. **Internal captured videos currently play inside DUMP only: play/pause and reopen-to-replay, without seeking or Photos export/transcoding.** They are not mislabeled as MP4 or passed to Photos as an unsupported format. A compatible export needs a separately implemented, explicit export-only muxing path.

## Internal format and bounds

The decrypted stream begins with eight ASCII bytes `DUMPVID1`. Each record contains two big-endian UInt32 lengths (JSON metadata, payload), then those two sections. Limits: 16 KiB metadata and 1 MiB payload. The existing vault encryption authenticates the complete stream; this framing is not a separate encryption scheme.

Record kinds: 1 = one H.264 AVCC frame with four-byte NAL lengths and SPS/PPS; 2 = interleaved LPCM with validated format/frame count; 3 = mandatory end marker. Records carry relative timestamps. The parser rejects unsupported kinds, invalid lengths/times/layouts, per-track timestamp regression, format changes, missing audio/video tracks, absent end markers and trailing bytes. End time records the maximum track start timestamp; playback includes final sample duration.

Capture uses a common first-video timestamp and at most three encoder frames in flight. Excess video input is dropped before encoding; there is no app-maintained raw-frame queue. Recording stops automatically at approximately ten minutes (599 seconds). Output is fixed upright portrait. Mode and camera changes are disabled during recording. Hardware encoding is required, so unsupported hardware, missing audio, codec errors, I/O failures and interruptions fail closed and discard the unfinished recording.

Playback retains one bounded pending packet and one 1 MiB decrypted read cache, with a half-second renderer submission horizon. Existing MediaReader scratch buffers and framework decoder/render buffers are additional. Cached reads still validate the reader lease. EOF releases the reader/cache; close/error also flushes renderers and removes the displayed image.

## Cancellation and ownership

Each camera presentation owns a separate lease and master-key copy. Closing it does not destroy the active vault master. `AppModel.lock()` synchronously cancels the camera lease before revoking the vault lease and clearing preview/master state. Late callbacks cannot repopulate locked UI. A save committed before cancellation remains valid; unfinished writers are released and encrypted partial deletion is attempted during teardown.

Session configuration, sample input, photo writing and teardown share a serial hardware queue. VideoToolbox callbacks serialize writer access with a separate lock. Encoder completion/invalidation never holds that callback lock, avoiding a drain deadlock. A close barrier prevents old audio-session deactivation from racing with new preview playback.

Revocation immediately denies app access and destroys owned keys. Physical sensor stop, codec invalidation, input removal and framework buffer release are asynchronous; there is no instantaneous hardware-wipe guarantee. Process termination, I/O failure or power loss can leave an **encrypted** partial. Existing conservative credential-recovery behavior for partial files is unchanged.

## Security limits

This is not absolute, unbreakable or “state-secret” security. Camera/ISP memory, CVPixelBuffer, CMSampleBuffer, codecs/decoders, audio renderers, GPU surfaces and other iOS-managed buffers temporarily hold plaintext. Third-party apps cannot guarantee those buffers are wiped. Framework copies, Swift/Data copy-on-write behavior, screenshots already taken by iOS, a compromised OS and external cameras remain limitations.

Mutable app-owned buffers are wiped where ownership permits. Camera/VideoToolbox-owned buffers are never overwritten. Playback's independent sample allocation is wiped only in CoreMedia's final-release callback. This does not guarantee wiping internal framework copies.

Explicit Photos export remains the existing intentional plaintext exception, with its cleanup warnings. Photos/iCloud copies are outside the vault. Taking a photo/video does not request Photos permission or automatically save there.

## Validation status

Prepared on Windows without Swift, Xcode or the iOS SDK. Structural checks passed, but **compilation, XCTest and actual recording/playback were not run**. The ZIP is modified source, not a signed or release-validated app.

On a Mac, run `bash ci/codemagic.sh prepare` then `bash ci/codemagic.sh test`, or the supplied Codemagic workflow. A simulator can run container/security tests but cannot validate this hardware-camera path. See SECURE-CAPTURE-DEVICE-TESTS.md.

API references: [VideoToolbox](https://developer.apple.com/documentation/videotoolbox/vtcompressionsession-api-collection), [sample-buffer audio renderer](https://developer.apple.com/documentation/avfoundation/avsamplebufferaudiorenderer), [CoreMedia block ownership](https://developer.apple.com/documentation/coremedia/cmblockbuffercustomblocksource), [photo settings](https://developer.apple.com/documentation/avfoundation/avcapturephotosettings).
