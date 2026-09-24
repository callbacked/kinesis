# air cursor

the air cursor moves the mac pointer with your forearm, like a mouse. an index pinch clicks and a middle pinch right-clicks. hold the pinch and move to drag. it uses the band's orientation quaternion (stream flag 8) for where the forearm points, and the gyro (flag 6) for how fast it moves.

## what the quaternion means

measured on 2026-09-24 with spoken, timed holds on a right wrist:

| hold | band +y in the world, as elevation |
| --- | --- |
| forearm at the ceiling | +67° |
| pointing at the screen | +16° |
| arm hanging down | −65° |

- the wire order is w, x, y, z, and the quaternion rotates the band's body frame into the world.
- the world's +z is up. it follows gravity: turning the whole body rotated the band around world z.
- the band's body +y runs along the forearm: toward the hand on a right wrist, and toward the elbow on a left wrist with the hand set to left (forearm at the ceiling −72°, hanging down +71°). a wrist twist rotates around y on both. the air cursor flips the axis for a left hand, or up and down come out inverted.
- the compass angle around gravity is relative. the band has no magnetometer.

`scripts/check-cursor-orientation.py` compares the quaternion with integrated gyro on a capture.

## the pointer

- the forearm's direction gives a compass angle and an elevation. a twist changes neither, so twisting the wrist never moves the pointer.
- the pointer moves by how that direction changes, like a mouse. a laser mapping tied each screen spot to one arm position: the bottom of the screen meant hitting the desk, and sway moved the pointer.
- speed is points per degree of turn, the same on every display, like a mouse. the default, 45, is what scored best in the practice lab on a 3440-point ultrawide: 75° crosses it, and 33° crosses a laptop screen. a scale per display made one move go 2.3 times further on the ultrawide, although a button is the same size in points on both.
- a right arm's "straight up" drifts left, so a slant straightens it. the default is 0.1 compass degree per degree up.
- acceleration: slow aiming moves the pointer at 0.6× the speed, and moves at 30°/s or faster at the flick boost, 1.6× by default. the arm's speed comes from the gyro over 30 ms, so slowing onto a target drops the boost at once. at 2× flicks overshot.
- hold Option to move the arm without moving the pointer.

## the levers

the cursor page has three, each with one sentence on what it does:

- speed, shown as the degrees of turn that cross the screen.
- flick boost, the top acceleration.
- steadiness, the stillness threshold. a live ring beside it shows the arm's turn rate as a dot: inside the ring, the pointer holds still.

above them, the hand mirrors the forearm, so the wearer sees what the band reads. below them, "try it" lights up click, right-click, drag, and double-click as each is done.

## calibration

only in lab builds. four dots, left, right, top, and bottom: the wearer points at each and pinches, and calibration measures the speed and the slant for one arm. on 2026-09-24 the default scored as well as a calibration, and one person's calibrations spread by about 7° across, as much as the gap between the default and a calibration. the speed lever sets the feel more directly.

## holding still

a held arm sways by about 0.2° typically and up to 1°, mostly between 1 and 3 Hz. with the gyro smoothed over 100 ms, holding still ran 0.5°/s typically and 0.9°/s at the 90th percentile, and slow, careful moves ran 1.2 to 1.8°/s. so the pointer stays still below about 0.85°/s and moves fully above about 1.35°/s, at the middle steadiness setting. a positional dead zone gave slow moves backlash, like an arm that was asleep. a light 1€ filter takes the tremor.

## clicks

- a click lands where the pointer is. an earlier version pressed where the pointer was 0.15 s before, to undo the pinch's nudge, and the pointer visibly jumped back.
- after a pinch the forearm drifts 0.2° to 0.8° over 0.3 s, and the haptic buzz adds to it. when the arm was still or slowing onto a target at the pinch, a click guard absorbs that drift for 0.4 s. the guard starts at the arm's speed at the pinch, so slowing on moves nothing and speeding up again, as for a drag, gets through.
- when the arm tracks something that moves, nothing is held back.
- two presses within 0.45 s and 6 points are a double-click.
- a pinch moves the forearm about 150 ms before the band reports it. a moving target travels 40 to 60 points in that time at 280 to 400 points a second, so fast moving targets are hit about 60 % of the time.

## drift and home

with acceleration, a move's gain depends on its speed, and an arm doesn't move at the same speed both ways. a right arm flicked right at over 30°/s and came back left more slowly, so over 40 seconds the arm walked 25° left to keep up. a mouse is lifted and set down again. an arm can't be. so the arm's direction when the cursor turns on is home. while the arm moves, a move back toward home gets up to 25 % more gain and a move away that much less. the pointer never moves on its own. pushing the pointer against a screen edge, releasing Option, or moving the pointer with the trackpad sets home again.

## smooth movement

- the pointer moves on every frame of the display under it, at that display's top rate.
- the band's samples arrive two at a time, every 15 ms and sometimes after 30 ms. posting whatever arrived each frame left 40 % of frames still at 100 Hz. each sample is placed at the time the band's clock gives it, and the movement plays back 30 ms behind the arm, part of a sample when a frame falls between two. that leaves 5 to 8 % of frames still, and adds about 10 ms.

## late data

on a congested radio link the band's samples reached the mac up to 22 s late, in bursts, while the link stayed up. host arrival time can't see that. `ArrivalDelay` compares the band's timestamps with the mac's clock, and input more than 0.3 s late is never acted on: no pointer move, click, shortcut, or dial step. gestures share the pipe with motion, so they use the motion delay. after a second of late data the band's column says so. a held button is released.

the orientation stream runs only while the cursor, calibration, or the readings page needs it. with it on from launch, the link was congested for minutes after each relaunch.

## developer tools

- `open -n --env KINESIS_MOTION_LOG=/path/motion.jsonl dist/Kinesis.app` writes every gyro, orientation, and gesture event with both clocks, one JSON object per line.
- `./scripts/build.sh --dev` makes a dev build, which adds the practice lab and calibration. the lab is a full-screen field with targets, moving targets, and drags. open it from the cursor page or the menu bar. each run saves its motion log, pointer events, trials, and settings to `~/Library/Application Support/Kinesis/Lab`. every run of a mode shows the same targets.
- `scripts/lab-compare.py` prints lab runs side by side: hits, times, misses, straightness, overshoot, and drift.
- `scripts/pointer-lab.sh` replays a motion log or scripted moves through the real cursor, one display frame at a time, at any refresh rate. it compares playback delays and tunings, and it measures uneven frames, lag, jumps at a press, flick overshoot, and drift. a replay can't show how a person reacts to a changed pointer, so live lab runs decide.
