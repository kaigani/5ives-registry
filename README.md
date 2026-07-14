# 5ives LIVE — Official Channel Registry

This repository is the **default registry** for the 5ives LIVE app: a set of signed
JSON files describing channels, schedules, collections, and assets (magnet URIs +
optional HTTP mirrors). The app fetches these files raw, verifies each against
`keys/registry.pub` (minisign), and caches them for offline use.

**This layout is the federation spec.** Anyone can publish their own registry on any
static host (`fives-prep registry init` scaffolds one) and users add it in the app via
Settings → Channel Sources. This repo is a default, not a gatekeeper.

Official media is distributed peer-to-peer first. Each signed asset also names
a per-asset GitHub prerelease containing `video_1080p.mp4` and `poster.jpg`, so a
fresh viewer behind NAT or a network that blocks torrent discovery still has a
range-capable HTTP origin. `scripts/refresh-official.sh` creates/reuses those
releases, signs their URLs into the asset documents, and refreshes schedules.

```
registry.json (+ .minisig)     root index: registry id/name, channel list, tracker URLs, spec version
keys/registry.pub              this registry's minisign public key
channels/<id>/channel.json     channel identity (+ .minisig)
channels/<id>/schedules/<UTC-date>.json   one signed schedule manifest per UTC day
collections/<id>.json          ordered asset lists used by curated blocks (+ .minisig)
assets/<id>.json               asset metadata: magnet_uri, info_hash, mirror_urls, files, license (+ .minisig)
```

## Contributing

Channel/asset submissions are pull requests. Merging = publication. Every JSON file
must carry a valid detached `.minisig` signature from this registry's key.
