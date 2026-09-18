# Device acceptance checklist — not executed

Use an iOS 17+ physical iPhone with device passcode and working biometrics. Run all 23 XCTest cases on a Mac/simulator first. Use disposable test media.

1. Fresh permissions: unlock, Add → Take Photo/Video, allow/deny Camera. Select Video and allow/deny Microphone. No Photos prompt should appear. Background during each permission request and confirm both unlock gates are required on return.
2. Photos: both cameras, supported flash settings, rapid taps, cancellation while processing, successive captures, device rotation, reopen from vault and explicit Photos export. Check orientation and no automatic Photos copy.
3. Video: both cameras; 1-second, 30-second and duration-limit recordings with speech/claps and moving subjects. Verify actual device PCM layout, hardware H.264 availability, audio/video sync, first/last samples, play/pause, reopen-to-replay and fixed portrait orientation.
4. Inspect the app sandbox during capture: only encrypted `.partial`/`.dump` media, no app-written plaintext JPEG/MOV/MP4, Live Photo or preview cache. Confirm Photos count is unchanged. This cannot prove absence of iOS-internal copies.
5. During capture, save/verification and playback, test Home/background, device lock, protected-data unavailability, Control Center, notification interruption, incoming calls, screen recording/mirroring and forced termination. Verify privacy cover, microphone/camera release, no resurrected preview or late save UI, and no playable unfinished item. A pre-cancel committed save may remain.
6. Rapidly alternate camera → close → preview → camera. Verify old teardown cannot deactivate new audio. Test denied/revoked microphone access, audio interruptions, route changes and AirPlay. Internal playback must reject AirPlay.
7. Low disk, thermal pressure, unsupported camera/encoder and memory pressure: clear failure, no silent plaintext fallback or audio omission. Use Instruments to measure memory plateau, frame drops and cancellation latency.
8. Tamper/truncate encrypted fixtures and test malformed internal records. Verify authentication failures and cached-data lease revocation. Check encrypted partial leftovers against existing credential-recovery rules.
9. Regress imported JPEG/HEIC/MOV/MP4 preview, explicit export/cleanup warnings, password changes, cancelled biometrics and background locking. Confirm 16-character password and Argon2id behavior.
10. Confirm internal captured video currently has no seeking/Photos export. Document any device-specific codec/layout incompatibility before release.

Record device/iOS/Xcode versions, exact build revision, results and memory measurements. A successful simulator build is not device capture acceptance or an independent security audit.
