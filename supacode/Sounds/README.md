# Notification sounds

These sounds are bundled as the selectable notification tones in
**Settings → Notifications → Notification sound**.

## Synthesized (original work)

`chime.wav`, `ding.wav`, `gong.wav`, `inbound-train.wav`, and `stand-clear.wav`
are **original work**, synthesized from scratch by
[`scripts/generate-notification-sounds.py`](../../scripts/generate-notification-sounds.py)
using additive synthesis (no sampled or third-party audio). They ship under the
repository's license with no attribution requirement. Regenerate them with:

```bash
python3 scripts/generate-notification-sounds.py
```

## Third-party recording

`choo-choo.wav` is **not** synthesized — it is a converted copy of a free
"Choo Choo Train" sound effect (from a YouTube "no copyright / free to use"
sound library), transcoded to mono 44.1 kHz 16-bit WAV.

⚠️ **Licensing caveat:** "no copyright / free to use" is the uploader's claim,
not a verified open license (CC0/CC-BY/etc.). Confirm the original source's
actual terms before relying on this in a public release; if in doubt, swap it
for a synthesized whistle (earlier revisions of the generator script produced
one) or a properly-licensed clip.

## Notes

- We deliberately do **not** ship recordings of trademarked transit jingles
  (e.g. SNCF, NYC MTA, SF Muni, Paris Métro).
- The "Classic" sound is `supacode/notification.wav` (outside this folder) and
  is intentionally left unchanged.
