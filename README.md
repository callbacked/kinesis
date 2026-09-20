<picture>
  <source media="(prefers-color-scheme: dark)" srcset="design/kinesis-links-dark.svg">
  <img src="design/kinesis-links.svg" width="80" alt="kinesis">
</picture>

# kinesis

use your meta neural band to control your mac


https://github.com/user-attachments/assets/25e974bc-a6ca-450f-83f0-732c6d40075c



swipe between desktops, open mission control, control your music, and pinch + turn for volume or brightness. pick your own mappings, practice in setup, then keep it in the menu bar.

built on some tinkering i did with astra in [neural-band-poc](https://github.com/callbacked/neural-band-poc) (feel free to go through that repo to do your own thing), so naturally i wanted to harness it to make it do something useful

some things may act quirky or not work at all, if that is the case i would love to know why, but this is all highly experimental

## run it
**be sure to unpair your band from the meta app before you get started**

a [factory reset](https://www.meta.com/help/ai-glasses/1481163499576351/) on the band is a good idea too, so it has no old owner

[download kinesis](https://github.com/callbacked/kinesis/releases/latest), open the dmg, and drag it into applications. needs macos 14+ and a neural band. works on apple silicon and intel.

set your band in pairing mode, hit pair band, and sign in with meta once. allow bluetooth + accessibility when prompted, and accept the bluetooth pairing request from macos. enable controls and you're in.

## why the meta sign-in

the band only trusts an owner that meta has enrolled. kinesis opens meta's own sign-in page once, claims the band for your mac, and keeps the session token in your keychain. it only gets that token, not your password. forget this band clears the key and the sign-in.

## build it

xcode with swift 6.

```sh
git clone https://github.com/callbacked/kinesis.git
cd kinesis
./scripts/build.sh
open dist/Kinesis.app
```

quit kinesis before rebuilding.

## license

[mit](LICENSE).
