# handedness references

checked september 14, 2026. public documentation establishes the intended gestures and fit, but does not document the band's handedness command or motion coordinate system.

## what meta documents

- wear the band on the hand used for writing, just above the wrist bone, with the reference line facing the wearer and the compute module on top of the wrist. the fit should be snug and comfortable. meta does not give a different fitting rule for the left wrist. [how to use meta neural band](https://www.meta.com/help/ai-glasses/764536076119235/)
- thumb swipes follow the intended scroll direction. index-to-thumb taps select; middle-to-thumb taps go back. while holding index to thumb, clockwise wrist turns increase volume or zoom and counterclockwise turns decrease them. these instructions do not specify a different direction for left-handed wearers or define the viewpoint for “clockwise.” [gesture instructions](https://www.meta.com/help/ai-glasses/764536076119235/)
- meta says the recognition model runs locally on the device. it also lists acceleration, rotation, and orientation among the data the band processes. that does not establish the axes or whether motion sent over the private protocol is already corrected for the selected hand. [emg wearable technology](https://www.meta.com/en-gb/emerging-tech/emg-wearable-technology/)
- the public web-app interface exposes four directional swipes, index pinch, and middle pinch. this is a glasses application interface, not documentation for configuring the band over bluetooth. [wearables developer faq](https://developers.meta.com/wearables/faq/)

## still unknown from public sources

the reviewed meta help and developer pages do not document:

- how the mobile app changes the selected wrist, or whether switching requires another setup step.
- the private request fields, acknowledgement, persistence, or readback for handedness.
- whether that setting changes gesture classification, horizontal swipe labels, raw gyro axes, or quaternion orientation.
- whether any per-person calibration is reset when changing wrists.

meta's launch article says the band is designed to work immediately across a broad population. that claim does not answer what changing the wrist configuration does internally. [meta neural band announcement](https://about.fb.com/news/2025/09/meta-ray-ban-display-ai-glasses-emg-wristband/)

## implication for kinesis

configure the band using verified protocol evidence, then check the returned gestures with the band worn on each wrist. do not infer an axis inversion or swap left/right gesture labels from a mirrored illustration. the decisive checks are distinct index and middle taps, all four swipe directions, and both dial directions after reconnecting. these are implementation and validation recommendations, not claims about meta's private protocol.
