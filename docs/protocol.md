# protocol notes

kinesis connects directly through corebluetooth. discovery, battery reads, l2cap, encryption, input decoding, and relative wrist motion run in swift inside the app. there is no worker process or json pipe.

the protocol comes from the sibling `neural-band-poc` checkout at `e5083d8cb087f6228349f4be302b31dfbe6f5454`. the native port uses fixed crypto vectors and a synthetic encrypted peer to check handshake ordering, fragmented packets, subscription flags, gesture decoding, dial movement, and shutdown acknowledgements.

- `BandConnection.swift` owns bluetooth discovery, one peripheral connection for battery and input, stream scheduling, and shutdown.
- `AirShield.swift` uses cryptokit for sha-256, hkdf, and hmac, with apple's commoncrypto for aes-cbc. packet macs are checked before plaintext is released.
- `BandWire.swift` reassembles datax frames across authenticated records and reads their protobuf fields.
- `BandSession.swift` owns p-256 key agreement, the handshake, input subscription, and typed events sent to the app.
- `PinchDial.swift` integrates relative gyro motion while a fresh index pinch is held.

the input-service connection requests flags 3, 6, and 8: gestures, gyro, and quaternion. it sends the observed end-link-setup message and disables those same streams on the original subscription channel during shutdown. raw semg isn't requested. shutdown waits up to three seconds for the disable acknowledgement before closing the connection; a lost link cannot guarantee that acknowledgement.

the observed airshield parameter-3 connection uses fresh p-256 keys. the handshake's empty identity query was informed by starcruiser's `Datax.swift` at commit `1bc6f9418ad85a10991817c74e15a84f85078f53`. this does not establish the band's complete owner-authentication protocol or compatibility with other firmware. keys and plaintext are not logged.

the dial emits signed movement independently of the practice dial's 0–100 display value. its scaling remains experimental. it needs a fresh index pinch after controls are enabled, settings change, or motion drops out. gesture and gyro device timestamps use different epochs; only consecutive gyro timestamps are integrated. input freshness and control gates use the mac’s monotonic uptime, so changing the wall clock does not change gesture timing.

fractional rotation reaches the app at up to 50 updates per second. at 1×, two degrees in the relative gyro estimate produce one media-key step. the dial accumulates fractional movement and sends at most one step every 80 ms. excess whole steps from a fast flick are discarded. release, reversal, and stale motion clear pending movement.

connection heartbeats follow authenticated packets independently of gyro freshness. a successful subscription acknowledgement establishes the connection even if the sensors are quiet. after two seconds without traffic, the app reads the existing subscription status; only an authenticated reply refreshes the heartbeat. an unresponsive link still times out and reconnects. a motion gap releases the dial without disabling fresh swipes and taps. corebluetooth and l2cap callbacks run on the main run loop in common modes, so menus and window dragging don't suspend stream delivery. an activity assertion keeps app nap from suspending controls on another desktop. unchanged heartbeats don't redraw the settings screen.

decoded events are delivered directly to the app model on the same actor; there is no intermediate event queue to overflow or replay. each stream callback reads at most 64 kib before yielding to the run loop. connection failures reset the gesture gates and retry with a short backoff. local preferences live in the app's user defaults. the lock at `~/Library/Application Support/Kinesis/band.lock` prevents two kinesis instances from owning the band; it doesn't coordinate with the old poc, so disconnect that first. connection diagnostics use macos unified logging under `local.callbacked.kinesis`.

keyboard actions preserve the arrow events' native function and numeric-pad flags. media actions use the system media-key event format from the macos sdk's `IOKit/hidsystem` headers. no global keyboard listener is installed.

## replaying a recording

`KINESIS_CAPTURE=/path/to/capture.jsonl swift test --filter nativeDecoderMatchesARecordedBandSession` checks an existing poc capture against the native decoder. it re-encrypts recorded plaintext with a synthetic peer’s fresh keys, then compares every decoded gesture and the motion count. recordings are optional local test input and are never bundled with the app or the source archive.
