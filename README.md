# kinesis

use your meta neural band to control your mac. no glasses or phone needed.

swipe between desktops, open mission control, control your music, and pinch + turn for volume or brightness. pick your own mappings, practice in setup, then keep it in the menu bar.

native swift all the way down. built on [neural-band-poc](https://github.com/callbacked/neural-band-poc).

## run it

macos 14+, xcode with swift 6, and a neural band.

```sh
git clone https://github.com/callbacked/kinesis.git
cd kinesis
./scripts/build.sh
open dist/Kinesis.app
```

find your band in setup, connect, and allow bluetooth + accessibility when prompted. enable controls and you're in. quit kinesis before rebuilding.

the build supports apple silicon and intel. build from source for now; a public download needs signing and notarization.

## a few things

- light and dark mode, fingertip feedback, and a saved gesture count.
- optional automatic connection and controls when the app opens.
- media controls work with your mac's current output, including airpods.
- handedness mirrors the hand illustration; the band's calibration stays as it is.
- this uses recognized gestures and wrist motion. no cursor tracking or raw semg recording yet.

[setup + controls](docs/usage.md) · [protocol notes](docs/protocol.md) · [release notes](docs/release-notes.md)

shoutout astra for reviving this project lol
