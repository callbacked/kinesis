# hand references

checked september 14, 2026. these are animation references for kinesis. the band connection supplies recognized gestures and wrist motion, not a measured 25-joint hand skeleton. the on-screen fingers remain an illustration of the recognized gesture. see [protocol notes](protocol.md).

## reusable poses

meta's [immersive web emulation runtime (iwer)](https://github.com/meta-quest/immersive-web-emulation-runtime) has a useful starting point: complete relaxed, index-pinch, and pointing poses using the standard 25 webxr joint names. the source is [mit licensed](https://github.com/meta-quest/immersive-web-emulation-runtime/blob/ffca804e90f607a2506f2847bcfca173a7f8d0c0/LICENSE), copyright meta platforms, inc. and affiliates. keep its full license with any copied or derived pose data.

pinned source commit: `ffca804e90f607a2506f2847bcfca173a7f8d0c0`.

- [relaxed pose](https://github.com/meta-quest/immersive-web-emulation-runtime/blob/ffca804e90f607a2506f2847bcfca173a7f8d0c0/packages/iwer/src/device/configs/hand/relaxed.ts)
- [pinch pose](https://github.com/meta-quest/immersive-web-emulation-runtime/blob/ffca804e90f607a2506f2847bcfca173a7f8d0c0/packages/iwer/src/device/configs/hand/pinch.ts)
- [point pose](https://github.com/meta-quest/immersive-web-emulation-runtime/blob/ffca804e90f607a2506f2847bcfca173a7f8d0c0/packages/iwer/src/device/configs/hand/point.ts)

these are shared emulator presets. meta’s [getting started guide](https://meta-quest.github.io/immersive-web-emulation-runtime/getting-started.html) describes the presets as derived from obfuscated quest 3 hand-tracking captures. [`XRDevice`](https://github.com/meta-quest/immersive-web-emulation-runtime/blob/ffca804e90f607a2506f2847bcfca173a7f8d0c0/packages/iwer/src/device/XRDevice.ts) creates both hands with the same `oculusHandConfig`. the runtime emulates input; importing its poses does not add hand tracking to the neural band.

## conversion notes

[`XRHandInput.ts`](https://github.com/meta-quest/immersive-web-emulation-runtime/blob/ffca804e90f607a2506f2847bcfca173a7f8d0c0/packages/iwer/src/device/XRHandInput.ts) defines the data and interpolation:

- each joint has a column-major 4×4 `offsetMatrix` and radius. all joints are relative to the hand's target-ray space, rather than their anatomical parent.
- stored poses are left-handed. the right-hand conversion flips matrix entries 1, 2, 4, 8, and 12. for these affine matrices this equals `S × M × S`, where `S = diag(-1, 1, 1, 1)`.
- to form a finger hierarchy, use `inverse(parentMatrix) × jointMatrix`. fixing the wrist removes the captured whole-hand offset and orientation.
- iwer decomposes matrices, interpolates translation and scale, and uses quaternion slerp for rotation. it does not interpolate mesh vertices.

webxr joint `-Z` points along the next bone toward the fingertip; `-Y` points out from the palm. the wrist points approximately into the palm and each tip inherits its distal joint's direction. the standard names and order cover the wrist plus thumb, index, middle, ring, and pinky chains. [webxr hand input specification](https://immersive-web.github.io/webxr-hand-input/#xrjointspace-interface)

local diagnostics compared these presets with the existing amazon/webxr `right-hand.glb`. parent-relative bone directions agree: most phalanx links differ by less than 2°, so the rotation convention is compatible. dimensions differ, particularly fingertip offsets. keeping the mesh's bind translations and applying the iwer pinch rotations leaves about 19.6 mm between thumb and index tip joints; the original iwer pose has about 2.1 mm. joint distance is not skin contact, so this needs visual checking rather than an automatic tip-to-tip constraint.

kinesis keeps the hand still, with its palm facing the user. a recognized gesture lights the thumb and the relevant fingertip; a pinch keeps them lit until release. no iwer data or pose animations ship in the app. the links above remain useful references if articulated animation is revisited.

`scripts/export-hand.mjs` exports the neutral amazon/webxr mesh and the thumb, index, and middle tip positions. the native material uses those points for soft, localized light, without moving any vertices.

```sh
node scripts/export-hand.mjs ../neural-band-poc/dashboard/static
```

## other useful meta material

[synthetic hands](https://developers.meta.com/horizon/documentation/unity/unity-isdk-input-processing/) separate tracked input from the rendered pose, constrain fingers during contact, and ease joints into and out of overrides. that separation is a useful design reference for kinesis's gesture illustrations.

[hand pose studio](https://developers.meta.com/horizon/documentation/unreal/unreal-isdk-hand-grab-poses/) supports authoring poses and setting transition time. the [unity interaction sdk samples](https://github.com/oculus-samples/Unity-InteractionSDK-Samples) are useful examples, but their main license is the oculus sdk license, not iwer's mit license. no sample assets were imported.

meta's [hand interaction guidance](https://developers.meta.com/horizon/design/hands-interaction-types/) recommends visual gesture instructions and immediate feedback for successful input. for onboarding, the practical direction is one readable movement, visible thumb contact, and a clear distinction between a demo and input received from the band.


## telepathy reference study

the telepathy onboarding was a design reference. the useful details are in the sequence, not just the colors:

- around 00:02–00:05, pairing progress and its checkmark occupy the same control. feedback does not make the user search elsewhere.
- around 00:08–00:26, one motion is taught at a time. framing follows the active part of the hand; blue marks the relevant area and the rest stays quiet.
- around 01:20–01:59, calibration moves from an instruction to an obvious visible result. extra controls arrive after the main action is understandable.

for kinesis, this means a short connect → practice → controls flow, a still palm view with all five fingers visible, light on the relevant tips, and confirmation beside the illustration. the practice page keeps previews separate from received input and pauses mac controls. there is no cursor calibration or full-hand tracking to imply yet. the loops, typography, layout, and wording remain kinesis’s own.
