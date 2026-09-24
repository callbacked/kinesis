# air cursor

the air cursor is a laser pointer from your forearm. it uses the band's orientation quaternion (stream flag 8), not the gyro.

## what the quaternion means

measured on 2026-09-24 with spoken, timed holds on a right wrist:

| hold | band +y in the world, as elevation |
| --- | --- |
| forearm at the ceiling | +67° |
| pointing at the screen | +16° |
| arm hanging down | −65° |

- the wire order is w, x, y, z, and the quaternion rotates the band's body frame into the world.
- the world's +z is up. it follows gravity: turning the whole body rotated the band around world z.
- the band's body +y runs along the forearm, toward the hand. a wrist twist rotated mostly around y.
- the compass angle around gravity is relative. the band has no magnetometer.

an earlier comparison on the september 14 captures matched the same order and frame against integrated gyro within about 3 %. `scripts/check-cursor-orientation.py` reproduces it on a capture.

## the pointer

- forearm direction in the world gives a compass angle and an elevation. a twist changes neither, so twisting the wrist never moves the pointer.
- turning it on anchors it: the aim at that moment points at the pointer. after that, 40° of forearm turn crosses the main display at sensitivity 1, and the same aim always gives the same point, also after the pointer stopped at a screen edge.
- a move by the trackpad, a pinch, Option, or a gap in the stream re-anchors at the pointer's position instead of jumping.
- near straight up or down (beyond 75°) the compass angle is undefined, so it holds still there.

## steadiness

a held arm sways by about 0.2° typically and up to 1°, and 87 % of that sway is between 1 and 3 Hz. a low-pass filter can't remove sway that slow without lag. so a light 1€ filter takes the tremor, and a dead zone takes the sway: the pointer stays still until the aim leaves a circle of 0.1° to 1° (the steadiness setting), then follows it on a rope. above 30°/s the circle shrinks to nothing, so a quick move lands where the arm points. a slow move can stop up to one circle short.

## late data

on a congested radio link the band's samples reached the mac up to 12 s late, in bursts, while the link stayed up (macOS drops it after 4 s of radio silence). host arrival time can't see that. `ArrivalDelay` compares the band's timestamps with the mac's clock, and input more than 0.3 s late is never acted on: no pointer move, click, shortcut, or dial step. gestures share the pipe with motion, so they use the motion delay. after a second of late data the band's column says so.

## developer log

`open -n --env KINESIS_MOTION_LOG=/path/motion.jsonl dist/Kinesis.app` writes every gyro, orientation, and gesture event with both clocks, one JSON object per line.
