# protocol notes

kinesis connects directly through corebluetooth. discovery, battery reads, l2cap, encryption, input decoding, and relative wrist motion run in swift inside the app. there is no worker process or json pipe.

the protocol comes from the sibling `neural-band-poc` checkout at `e5083d8cb087f6228349f4be302b31dfbe6f5454`. the native port uses fixed crypto vectors and a synthetic encrypted peer to check handshake ordering, fragmented packets, subscription flags, gesture decoding, dial movement, and shutdown acknowledgements.

- `BandConnection.swift` owns bluetooth discovery, one peripheral connection for battery and input, stream scheduling, and shutdown.
- `AirShield.swift` uses cryptokit for sha-256, hkdf, and hmac, with apple's commoncrypto for aes-cbc. packet macs are checked before plaintext is released.
- `BandWire.swift` reassembles datax frames across authenticated records and reads their protobuf fields.
- `BandSession.swift` owns p-256 key agreement, the handshake, input subscription, and typed events sent to the app.
- `PinchDial.swift` integrates relative gyro motion while a fresh index pinch is held.

the input-service connection requests flags 3, 6, and 8: gestures, gyro, and quaternion. it sends the observed end-link-setup message and disables those same streams on the original subscription channel during shutdown. developer mode can add raw sEMG flag 2 to that subscription after startup, keeping the other flags enabled. shutdown also disables raw sEMG if requested, and waits up to three seconds for the disable acknowledgement before closing the connection; a lost link cannot guarantee that acknowledgement.

raw sEMG configuration is read on channel `0x8007`. the readings view supports the observed 2,048 hz, eight-channel, 16-bit configuration with 16 samples per batch and encoding 0. payload type `0x0200020a` contains sequence, timestamp, and 256 sample bytes, interpreted as little-endian unsigned values interleaved by sample then channel. recordings retain the original sensor payload. the chart leaves gaps between discontinuous batches and reports the received sample rate separately from the configured rate. voltage scaling and physical electrode order remain unverified.

charging is read through `BatteryInfoReq` on channel `0x8008`, every five seconds once streams are enabled. the response contains battery percentage and an optional charging flag. absent, invalid, or timed-out status stays unknown; charging is not inferred from percentage changes. the standard GATT battery characteristic is also read and subscribed to when notifications are supported.

the observed airshield parameter-3 connection uses fresh p-256 keys. the handshake's empty identity query was informed by starcruiser's `Datax.swift` at commit `1bc6f9418ad85a10991817c74e15a84f85078f53`. this does not establish the band's complete owner-authentication protocol or compatibility with other firmware. keys and plaintext are not logged.

the dial emits signed movement independently of the practice dial's 0–100 display value. its scaling remains experimental. it needs a fresh index pinch after controls are enabled, settings change, or motion drops out. gesture and gyro device timestamps use different epochs; only consecutive gyro timestamps are integrated. input freshness and control gates use the mac’s monotonic uptime, so changing the wall clock does not change gesture timing.

fractional rotation reaches the app at up to 50 updates per second. at 1×, two degrees in the relative gyro estimate produce one media-key step. the dial accumulates fractional movement and sends at most one step every 80 ms. excess whole steps from a fast flick are discarded. release, reversal, and stale motion clear pending movement.

connection heartbeats follow authenticated packets independently of gyro freshness. a successful subscription acknowledgement establishes the connection even if the sensors are quiet. after two seconds without traffic, the app reads the existing subscription status; only an authenticated reply refreshes the heartbeat. an unresponsive link still times out and reconnects. a motion gap releases the dial without disabling fresh swipes and taps. corebluetooth and l2cap callbacks run on the main run loop in common modes, so menus and window dragging don't suspend stream delivery. an activity assertion keeps app nap from suspending controls on another desktop. unchanged heartbeats don't redraw the settings screen.

decoded events are delivered directly to the app model on the same actor; there is no intermediate event queue to overflow or replay. each stream callback reads at most 64 kib before yielding to the run loop. connection failures reset the gesture gates and retry with a short backoff. local preferences live in the app's user defaults. the lock at `~/Library/Application Support/Kinesis/band.lock` prevents two kinesis instances from owning the band; it doesn't coordinate with the old poc, so disconnect that first. connection diagnostics use macos unified logging under `local.callbacked.kinesis`.

keyboard actions preserve the arrow events' native function and numeric-pad flags. media actions use the system media-key event format from the macos sdk's `IOKit/hidsystem` headers. no global keyboard listener is installed.

## handedness

`ConfigReq.is_left_handed` is field 10: `50 00` selects right and `50 01` selects left. it is nested in `RpcRequest` field 5, on input service `0xce56`, message `0x02000314`. an empty config request reads the current configuration. the response uses `0x02000315`, status 1 for the observed success response, and `ConfigResp` in field 6 with handedness in field 10. absence is treated as unknown, never as right-handed.

this mapping comes from meta ai build `948093709`: the native `is_left_handed` string is at module offset `0x93d15b0`; the name-map code at `0x35d03b8`–`0x35d03e0` assigns it field 10. descriptor construction at `0x3b1b5f0`–`0x3b1b610` independently associates that string with 10. the earlier right-wrist configuration capture and a live native app read both returned 0. a live write of 1 followed by a separate empty-config request returned 1. after quitting the app and establishing a fresh connection, the initial read still returned left without another write. persistence across a band reboot has not been tested.

kinesis uses configuration channel `0x8006`, separately from the sensor subscription. only field 10 is included in a write. request ids and the response channel must match; a write acknowledgement triggers an independent read, and the picker is confirmed only after that value matches. rejected, missing, invalid, or timed-out responses stay unconfirmed. reconnecting reads the band again instead of overwriting it with a saved illustration preference.

left-wrist testing reported correct swipe directions and reversed dial movement before app normalization. after the correction, the wearer confirmed the left-hand volume dial's direction. the band also acknowledged switching back to right, followed by an independent read returning right; the wearer then confirmed normal right-hand operation. these hardware checks used the same band and wearer.

the band supplies recognized swipes and taps, while kinesis derives the dial from gyro readings. `BandModel` reverses that derived rotation for the confirmed left-hand setting before sending it to either practice or mac actions. swipes are not mirrored. the dial waits for a confirmed hand setting. [public fit and gesture references](handedness-research.md) do not define the private gyro axes.

## replaying a recording

`KINESIS_CAPTURE=/path/to/capture.jsonl swift test --filter nativeDecoderMatchesARecordedBandSession` checks an existing poc capture against the native decoder. it re-encrypts recorded plaintext with a synthetic peer’s fresh keys, then compares every decoded gesture and the motion count. recordings are optional local test input and are never bundled with the app or the source archive.
