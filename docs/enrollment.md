# band identity and enrollment

kinesis 0.2 can authenticate as a band's enrolled owner. a p-256 identity key
stored in the mac keychain signs the band's `enabletrust` proof, so a band that
is still owned by a meta account unlocks on connect without a factory reset.
this is the cold-start path verified against hardware in the
`local/band-recovery-2026-09-16` recovery work. kinesis also runs the one-time
enrollment ceremony itself, the same exchange the meta ai app runs when it
registers a band; it is described at the end of this document.

## identity lifecycle

- `BandIdentity` (`KinesisCore/BandIdentity.swift`) stores one generic-password
  keychain item per band. the service is `local.callbacked.kinesis.identity`
  and the account is the band's corebluetooth uuid. the value is the raw
  32-byte representation of a p-256 signing key. an optional second item
  (account suffix `.band`) holds the band's 65-byte x9.63 identity public key.
- the api is `save`, `load`, `generate`, `delete`, and `exists`, all keyed by
  the band identifier. key bytes never appear in logs or user-facing text.
- a fresh identity can be generated per band, but the useful flow is import:
  a raw 32-byte key file recovered from the phone-side keystore, optionally
  with its `band-identity-record.json`. the record's `AppPrivateKey` and
  `AppPublicKey` must both match the imported key file, and the record's
  `AppECPubicKey` (spelling preserved from the reference records) becomes the
  stored band key. the import panel (`IdentityImport`) is a developer
  workflow; the band page itself exposes no identity surfaces.
- when a band identifier has a stored identity, `NativeBandConnection` creates
  the session in enrolled mode. without an identity the session is unchanged.

## enrolled trust flow

the sequence mirrors `check-enrolled-identity.py`'s `EnrolledHandshake` exactly.
for sender `S` and receiver `R` the transcript digest is:

`digest = SHA256(SHA256(R.challenge16 || R.ephemeralPub64) || SHA256(S.seed32 || S.ephemeralPub64))`

signatures are p-256 ecdsa over that digest, encoded as raw 64-byte `r || s`.

1. transport handshake as today: `RequestEncryption` / `EnableEncryption`.
2. the host sends `EnableTrust` on the identity service channel (words
   `0x81000024` + `0x02001000` on `0x8002`). field 1 is the sha-256 of the
   host identity public key's raw 64-byte point. field 2 is the host identity
   signature over the digest, with the band as receiver (its `RequestEncryption`
   challenge and public key) and the host as sender (its `EnableEncryption`
   seed and public key). the legacy empty identity query (`0x02003000`) is not
   sent in this mode.
3. the band answers with an identity result code on channel 2 (word family
   `0x0300xxxx`). `0x03001000` accepts the host identity. `0x03001043` means
   the band is enrolled to a different key. any other code is a rejection.
4. the band sends its own `EnableTrustEC` proof (`0x02001001` on a channel with
   the rx bit set, observed on `0x8003`) with a hint in field 1, the 64-byte
   signature in field 2, and provisioning capabilities in field 3. when the
   band identity public key from the record is stored, the host verifies the
   signature over the digest with the band as sender and the host as receiver,
   then acknowledges with `0x03001000` on the proof's low channel. without the
   record there is nothing to verify against, so band acceptance is what
   matters. a wrong signature under a stored band key fails the connection
   before any acknowledgement.
5. once both directions are trusted, the host sends `EndLinkSetup` (`0x8001`,
   `0x02001000`) and the flow rejoins the existing startup: device-info query
   on `0x8003`, then the input subscription, handedness read, and streams.

result codes are diagnosed per the reference: `0x1000` success, `0x1001`
failure, `0x1002` unsupported, `0x1003` unavailable, `0x1010` key missing,
`0x1040` receipt invalid, `0x1041` nonce invalid, `0x1042` user invalid,
`0x1043` app identity invalid, `0x1044` signature invalid, `0x1045` time
invalid. the two responses in step 3 and 4 may arrive in either order.

### mismatch fallback

if the band rejects the stored identity, the session fails with the surfaced
message (for `0x03001043`: "band enrolled to a different key. forget the stored
band identity to reconnect without it."). `NativeBandConnection` remembers the
rejection for that band for the rest of the process and retries the legacy
startup without an identity, so a stale identity never blocks a band that
would otherwise connect in pairing mode. forgetting the identity from settings
restores enrolled attempts. the memory also clears when a new ownership
ceremony adopts a fresh key for that band, so a re-enrolled band connects
enrolled again.

## meta session persistence and re-enrollment

the account session from the login chain survives relaunch. `MetaSessionStore`
(`Kinesis/MetaAuth.swift`) keeps one keychain item under the service
`local.callbacked.kinesis.meta` holding the session json (access token, user
id, device id, universe, obtained-at time); token material never reaches logs.

- the band page runs the whole pipeline through one "pair band" button
  (`BandModel.pairBand`): it scans when nothing is remembered, connects, and
  reads the band's response. a stored identity unlocks on connect. a
  mismatch (0x1043), a second consecutive legacy rejection (0xc001-class), or
  a band with no stored identity enrolls with the saved session and then
  reconnects, so the fresh key settles before the run reports done.
- the sign-in sheet appears only when nothing is saved, or when a ceremony
  http step fails with an auth-class error (http 401/403, or graph error code
  190): that throws `MetaSessionInvalidError`, the saved session is dropped,
  and the sheet asks for one sign-in. the ceremony restarts from its identity
  read; its state machine lived in the closed connection, so a mid-ceremony
  resume is not possible. the band must stay in pairing mode.
- the requirement is a meta account for the first claim. after that the band
  is locked to that account, and unenrolling is not mapped, so another account
  needs a factory reset. the surface therefore offers an account switch in one
  place only: the wrong-account failure (`0x1042`), where the band is owned by
  another of the person's accounts and signing in with it is the cheap fix.
  "sign in with another account" drops the refused session
  (`switchMetaAccount`) and pairs again, which opens the sign-in sheet. the
  factory reset guide sits beside it.
- "forget this band" is one confirmed step (`forgetEverything`): it clears the
  remembered band, the stored identity, and the meta session. the session only
  exists to claim a band, so it has no control of its own. the band stays
  enrolled server-side; pairing again rebinds it. right after the forget, a
  reminder sheet (`FactoryResetReminder`) says the band is still claimed and
  how to wipe it, with "i've reset it" as the acknowledgement and a quiet
  "not now". it records nothing: either answer only closes the sheet.
- the pairing surface (`PairingFlowView`) draws one value,
  `PairingPresentation`, which `BandModel.pairing` derives from the route, the
  enrollment stage, and the failure. it shows four steps (find, sign in,
  claim, ready), the live one marked. the reconnect after a claim is "ready",
  never a second "find". a failed run marks the step it stopped at
  (`pairFailedStep`) and names it in the headline; the wrong-account failure
  links to meta's factory reset guide. the band artwork calls out the button
  while a run scans and after an empty scan. a run can be cancelled at any
  stage (`cancelPairing`). until the band is paired this card stands in for
  the band card and the settings rows: a band that was found and never claimed
  reads "setup incomplete" with its artwork greyed, and one that stopped
  trusting this mac reads "pair it again". all of it hides while the band is
  connected, busy, or streaming.
- macos pairs with an unbonded band when kinesis reads the input channel, and
  that waits on a request the person must accept. a read that stays open for
  1.5 seconds emits `systemPairingPending`: the surface says so, and the startup
  deadline extends to cover the 30-second pairing window.
- a factory reset gives the band a new identity key (irk). macos still shows the
  pairing request, and after it is accepted refuses to keep the pairing:
  bluetoothd logs "already paired, with a different irk. unpair first", the
  read fails with att error 15, and the band hangs up 30 seconds later when its
  own pairing timer runs out. nothing on the app's side of the link can fix
  that, and nothing removes the entry either: the unpublished
  `IOBluetoothDevice.remove` that blueutil uses reports success for the band
  and leaves the entry in place (tried and dropped). so the person does it. the
  reminder after forget has two steps, factory reset the band and forget it in
  bluetooth settings, each with its link. att error 15 is reworded into the
  same advice with the same link; errors 5 and 8 keep the "accept the request"
  advice.
- the sign-in sheet opens on a short preface (why, what is stored, how to undo
  it) and contacts meta only after "continue to meta". while the page is up
  the sheet shows its current host.
- `KINESIS_RENDER_DIR=<dir> swift test --filter pairingStatesRenderForReview`
  draws every pairing state and the sign-in preface to png files, light and
  dark, for a visual check without a band.

## enrollment ceremony

bands require one-time official enrollment: an owner identity must be
provisioned through meta before any trust proof can succeed. the band only
accepts an owner whose receipt meta's server has signed, and that server only
signs for a signed-in meta account. that is the whole reason for the sign-in.
kinesis 0.2 performs the ceremony in-app (`OwnershipCeremony`,
`MetaPairClient`), with a key it generates for the band, so no extraction
workflow is needed. the field
maps below come from the com.meta.identity implementation recovered in the
meta ai android build; see
`local/band-recovery-2026-09-16/meta-ai-startup-map.md` for the source
analysis and
`local/band-recovery-2026-09-16/phone-home-pairing-dgz958jd/receipt-structure.json`
for the captured receipt shapes.

1. account login: a `WKWebView` on meta's own sign-in page (`MetaLoginView`,
   `MetaAuth`) obtains the user access token (token universe `ar`) that the
   graph routes require, together with the public hardware app credential.
   kinesis never sees the password.
2. device identity read: band types `0x3000` → `0x3001` return the device
   certificate (field 1), serial (field 2), and optional registration challenge
   package (field 3).
3. nonce: band types `0x2000` → `0x2001` return the 16-byte pending ownership
   change nonce in field 1.
4. pending receipt: `URLSession` posts route `pair_request` to
   `graph.facebook-hardware.com` with the device certificate, serial number,
   and additional data (base64 device nonce, app public key, secondary
   certificate). the server answers with the
   `ServerPendingOwnershipReceipt` string and its der signature. the captured
   receipt carries serial, user id, server challenge, signature algorithm,
   expiry and current times, and the additional-data json described above.
5. start change owner: band type `0x2002` carries the decoded signature bytes
   in field 1 and the exact receipt string in field 2. the band answers
   `0x2003` with its pending receipt (signature field 1, receipt field 2).
6. final receipt: `URLSession` posts route `pair` with the pending receipt and
   its signature. the server answers with the final ownership receipt.
7. finish change owner: band type `0x2004` carries the final signature and
   receipt, same field map. band type `0x2005` confirms ownership; the app then
   stores the owned flag and the device public key from the final receipt's
   `additional_data.device_ec_public_key`, and proceeds to the trust flow
   above.

receipt strings are signed bytes: kinesis must keep them verbatim and must not
reformat the json. the routes and the app credentials are meta's own and
undocumented, so meta can change them; a band that is already enrolled keeps
working, because connecting only needs the stored key.
