# setup + controls

## run it

[download the dmg](https://github.com/callbacked/kinesis/releases/latest) and drag kinesis into applications. needs macos 14+ and bluetooth.

to build from source, install xcode with a swift 6 toolchain:

```sh
./scripts/build.sh
open dist/Kinesis.app
```

the build produces a universal app for apple silicon and intel. the app is native swift, including bluetooth, packet decoding, and the dial. no python worker or environment to keep running.

the script uses your apple development signing identity if exactly one is available. you can choose one with `KINESIS_SIGNING_IDENTITY`. without one, it uses ad hoc signing, which can make macos ask for accessibility access again after a rebuild. quit kinesis before rebuilding.

## connect

1. stop the old browser console's band connection if it's running.
2. put your band in pairing mode, click **find band**, select it, then **connect**. it remembers the band afterward.
3. allow bluetooth when macos asks. grant kinesis accessibility access to send shortcuts.
4. click **enable controls** and try a gesture.

closing the window keeps the connection in the menu bar. pause controls there whenever you want. quitting disconnects the band. the battery reading refreshes while connected.

turn on **start automatically** under **band** to reconnect and enable controls when kinesis opens. it waits for a live connection and accessibility access. pausing or opening quick setup keeps controls paused for the rest of that run, until you enable them again.

the first launch has a short setup: connect, try a swipe, practice a pinch and turn, and allow mac controls. controls stay paused while you practice; the setup dial never changes your volume or brightness. **quick setup** in the sidebar brings it back anytime. you can skip it too.

choose your hand during setup or under **band**. kinesis reads the band's current setting when it connects. changing hands pauses mac controls, updates the band, and checks the setting again before confirming it. move the band to that wrist, then enable controls when you're ready. swipe directions come directly from the band; the app adjusts its own wrist-turn dial for the selected hand.

**overview** shows your gestures, **gestures** holds the assignments, and **band** has the connection details. the appearance menu switches between light, dark, and your system setting.

the overview keeps a running count of recognized swipes and taps, saved on this mac across launches. duplicate packets and individual dial ticks aren't added to the count.

## controls

everything is selectable in the app. the initial mappings are:

| gesture | action |
| --- | --- |
| thumb swipe left / right | previous / next desktop |
| thumb swipe up | mission control |
| thumb swipe down | dismiss with escape |
| index double tap | play / pause |
| middle double tap | mute / unmute |
| index or middle single tap | unassigned |
| pinch thumb + index, then turn your wrist | volume |

the dial can also control brightness or be turned off. release and pinch again after changing its settings. media controls use the mac's current audio output, including connected airpods. brightness uses the normal brightness keys, so external displays may not respond.

desktop and mission control actions use the standard control + arrow shortcuts. those need to be enabled in macos keyboard settings, and desktop switching needs another desktop. dismiss sends escape; outside mission control it can dismiss the current view. window and tab shortcuts act within the current app.

## under the hood

swiftui window and menu bar, corebluetooth for the band connection, and swift decoding of the gesture + motion stream from the poc. no raw semg recording in this client. stale input and duplicate gesture messages are filtered before controls run; reconnects don't replay old gestures.

the app shows which command it sent. that isn't confirmation that another app acted on it. the dial is relative wrist motion, with adjustable sensitivity, rather than a tracked hand pose.

the hand stays still, palm facing you. the thumb and the relevant fingertip light up on a gesture, and stay lit during a pinch. it isn't live finger tracking. the mesh comes from [webxr input profiles](https://github.com/immersive-web/webxr-input-profiles), with its mit notice bundled. `scripts/export-hand.mjs` exports the neutral mesh and fingertip locations. [hand reference notes](hand-references.md) cover the research.

the band uses a background-removed [meta product image published by gizmodo](https://gizmodo.com/metas-smart-glasses-now-have-a-screen-and-a-magic-wristband-2000659760); it isn't a 3d model.

```sh
swift test -Xswiftc -warnings-as-errors
```

[protocol notes and source](protocol.md).

## release files

```sh
./scripts/release.sh
```

this checks the code, builds the app, and writes a source archive and a local app archive under `dist/release/`. local recordings, preferences, research copies, and signing credentials stay out of those archives. [release notes](release-notes.md).

the local app archive stays separate from the public dmg. to make a public release, choose a developer id application identity and notarize the app first. `asc` uses your configured apple api credentials.

```sh
KINESIS_SIGNING_IDENTITY="Developer ID Application: your name (team id)" ./scripts/build.sh
ditto -c -k --keepParent dist/Kinesis.app dist/Kinesis-notary.zip
asc notarization submit --file dist/Kinesis-notary.zip --wait
xcrun stapler staple dist/Kinesis.app
./scripts/dmg.sh dist/Kinesis.app
```

the dmg script requires a stapled app, adds the applications shortcut, signs and notarizes the disk image, and checks gatekeeper before writing `dist/Kinesis-<version>.dmg`. both the app and the disk image carry notarization tickets for offline installation. set `KINESIS_SIGNING_IDENTITY` for this script too if more than one developer id identity is installed.
