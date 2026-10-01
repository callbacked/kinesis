# trackpad decoder

an experiment in dev builds (`./scripts/build.sh --dev`): read a fingertip's touch and slide from the band's raw sEMG, so any surface could work like a trackpad. it learns from your own use of the mac's trackpad. no one else's data, and no calibration screen.

## where the labels come from

"record while I work" (dev builds, band menu) saves the band's raw sEMG and gyro while you use the mac normally. it is off until you turn it on, and everything it saves stays in `~/Library/Application Support/Kinesis/Lab` on your mac. it also logs each key press and release with its key code, to know when the band hand is typing. secure fields such as passwords never reach it, and nothing is uploaded. it also reads every contact on the built-in trackpad through apple's private MultitouchSupport framework, palms included. the trackpad says exactly when a finger touched and where it slid, so each 20 ms of sEMG gets a label:

- touching or not.
- a lone finger's velocity in mm/s, when there is one.

the trainer leaves out moments with a palm down or a mouse moving the pointer. learning inside kinesis leaves out palms. the recorder pauses by itself when you're away, the band charges or is off the wrist, or the finger cursor is on.

## the recipe

every step uses only the past, exactly as kinesis computes it live:

1. four band-pass filters: 20–60, 60–120, 120–250 and 250–450 hz.
2. per band, the 8 × 8 covariance of the channels over the last 160 ms.
3. each covariance is re-centered on a running average of this wearing's covariances, then mapped to a flat space by a matrix log (the riemannian tangent space). the re-centering carries a model from one wearing to the next: a re-worn band sits a little differently, and without it up-down fell to chance on a new day.
4. the band's gyro over the last 180 ms, less its running average. a slide rocks the wrist a little. on a new day it lifted up-down direction from 64 % to 77 %.
5. a small network (459 → 256 → 128 → 3) reads the features of now, 80 ms ago and 160 ms ago, and the gyro. it outputs touch and velocity.

`scripts/trackpad-train.py` trains it on every recording and writes `~/Library/Application Support/Kinesis/Lab/decoder.json`. it needs pytorch. it first prints an honest score: a model from the earlier days meets the newest day as a new wearing.

## learning inside kinesis

`LiveTrackpad.swift` runs one decoder for the preview, the finger cursor and learning. while the recorder records, the trackpad labels each frame, and every 2 minutes of labels the whole network is fine-tuned in the background on this wearing's frames, starting from the trained network each time (`TrackpadFineTune.swift`, about 2 s on a full buffer). what a wearing learned survives a relaunch.

## how well it does

scored on 2026-09-30 by a model trained on 2026-09-25 alone, about 1.5 hours of use. touch 0.5 and direction 50 % are chance. direction is scored on slides over 20 mm/s, frame by frame and over whole strokes of 200 ms or more.

| | touch | left-right | up-down | strokes left-right | strokes up-down |
| --- | --- | --- | --- | --- | --- |
| the first linear decoder | 0.78 | 65 % | 52 % | | |
| this recipe, fresh | 0.81 | 87 % | 74 % | 85 % | 73 % |
| after 2 min of trackpad use | 0.84 | 89 % | 80 % | 88 % | 80 % |
| after 10 min | 0.88 | 89 % | 80 % | 87 % | 81 % |

tried and left out, because they scored no better: 480 ms of memory, two-finger scrolls as extra labels, a wider or deeper network, and learning to tell keys apart from the keystroke log. (the band can tell which of 24 keys was pressed 35 to 42 % of the time, against 4 % by chance.)

## trying it

- **decoder preview**: a white dot is your finger on the trackpad, a blue dot is what the band reads. it shows how often the direction agreed over the last 30 s, and how much it learned on this wearing. each session logs its frames to `Lab/preview-*.csv`.
- **finger cursor**: the decoder moves the real pointer. on the desk it rarely believes a finger is down yet, since it only learned the trackpad, so hold control while you slide to count as touching. escape stops it.

each finger cursor session saves the band's sEMG and gyro to `Lab/desk`, with when control was held. a fingertip is on the desk while control is down, so those frames are sure desk touches. learning inside kinesis takes them in at once, and the trainer uses them too. they teach touch only, never direction, and the not-touching examples still come from the trackpad. no calibration screen.

## the tests

`TrackpadDecoderTests.swift` checks the swift decoder against the python recipe on synthetic sEMG and gyro fed in arrival order, and the swift fine-tune against pytorch, weight for weight. `scripts/trackpad-train.py --fixture` rewrites both fixtures. `TrackpadBenchmark.swift` times decoding and fine-tuning in a release build on request.
