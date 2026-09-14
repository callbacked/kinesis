<picture>
  <source media="(prefers-color-scheme: dark)" srcset="design/kinesis-links-dark.svg">
  <img src="design/kinesis-links.svg" width="80" alt="kinesis">
</picture>

# kinesis

use your meta neural band to control your mac


https://github.com/user-attachments/assets/25e974bc-a6ca-450f-83f0-732c6d40075c



swipe between desktops, open mission control, control your music, and pinch + turn for volume or brightness. pick your own mappings, practice in setup, then keep it in the menu bar.

native swift, built on some tinkering i did with astra in [neural-band-poc](https://github.com/callbacked/neural-band-poc), so naturally i wanted to harness it to make it do something useful

## run it
**be sure to unpair your band from the meta app before you get started**

[download kinesis](https://github.com/callbacked/kinesis/releases/latest), open the dmg, and drag it into applications. needs macos 14+ and a neural band. works on apple silicon and intel.

set your band in pairing mode, connect, and allow bluetooth + accessibility when prompted. enable controls and you're in.

## build it

xcode with swift 6.

```sh
git clone https://github.com/callbacked/kinesis.git
cd kinesis
./scripts/build.sh
open dist/Kinesis.app
```

quit kinesis before rebuilding.
