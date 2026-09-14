# kinesis

use your meta neural band to control your mac


https://github.com/user-attachments/assets/25e974bc-a6ca-450f-83f0-732c6d40075c



swipe between desktops, open mission control, control your music, and pinch + turn for volume or brightness. pick your own mappings, practice in setup, then keep it in the menu bar.

native swift, built on some tinkering i did with astra in [neural-band-poc](https://github.com/callbacked/neural-band-poc), so naturally i wanted to harness it to make it do something useful

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
