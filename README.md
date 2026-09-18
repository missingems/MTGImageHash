# MTGImageHash
The Magic: The Gathering card-recognition database used by Mooligan's scanner, rebuilt twice daily from Scryfall.

Each card face is stored as an Apple Vision feature print (`VNGenerateImageFeaturePrintRequest` revision 2, `scaleFill`, 768 floats), computed from Scryfall's `normal` image. Only paper cards are included; substitute, checklist and art-series layouts are skipped. This matches the pipeline in the MTGCards app, which produced the database bundled in Mooligan.

## Published files

Served from https://missingems.github.io/MTGImageHash/:

| File | Contents |
| --- | --- |
| `manifest.json` | `{masterVersion: String, masterChunks, latestPatch, cardCount, lastUpdated}` |
| `MTG_Hashes_Master_<0…7>.lzfse` | The full current database, split into chunks. Each chunk is an LZFSE-compressed binary plist of `[faceId: NSKeyedArchiver(VNFeaturePrintObservation)]`. |
| `patch_<n>.lzfse` | Entries added or changed since patch `n-1`, in the same format. |
| `visualizer_data.json` | Card metadata for the web visualizer. It also serves as the index for incremental builds. |

Face IDs are the Scryfall card ID, or `<cardId>-face<i>` for multi-faced cards without top-level images.

### Client protocol
- If `masterVersion` differs from the client's copy, or the client is more than 20 patches behind, it downloads every master chunk. The master always contains every patch.
- Otherwise the client applies `patch_(local+1)` through `patch_latest` in order.

`masterVersion` changes when a rebase happens: after 14 patches (about a week), or on a manual full rebuild. Faces that leave Scryfall's catalog are dropped only at a rebase, because patches can only add or replace entries.

## How it runs

`indexer.swift` downloads Scryfall's `default_cards` bulk data and fetches the currently published site as state. It recomputes vectors only for faces whose image URL changed (the URL embeds a timestamp), then writes the new site.

The `MTG Indexing` workflow runs it at 10:17 and 22:17 UTC and deploys the result to GitHub Pages. Run it manually with **full_rebuild** to recompute everything and start a new master.

Local test run:

```bash
OUTPUT_DIR=site FULL_REBUILD=1 MTG_LIMIT=300 swift indexer.swift
```

`FULL_REBUILD=1` skips fetching the previous state. Without it, the run aborts if the state server is unreachable, so a network blip never triggers a full rebuild.
