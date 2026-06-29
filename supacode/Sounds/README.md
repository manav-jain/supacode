# Notification sounds

These sounds are bundled as the selectable notification tones in
**Settings → Notifications → Notification sound**.

Every `.wav` in this folder is **original work**, synthesized from scratch by
[`scripts/generate-notification-sounds.py`](../../scripts/generate-notification-sounds.py)
using additive synthesis (no sampled or third-party audio). They ship under the
repository's license with no attribution requirement. Regenerate them with:

```bash
python3 scripts/generate-notification-sounds.py
```

We deliberately do **not** ship recordings of real transit jingles (e.g. SNCF,
NYC MTA, SF Muni, Paris Métro) because those are trademarked recordings.

The "Classic" sound is `supacode/notification.wav` (outside this folder) and is
intentionally left unchanged.
