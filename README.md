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
| `index.json` | The flat index: `{format, masterVersion, latestPatch, cardCount, dimension, shortlistDimension, parts, bytes, projection}`, where `projection` is the SHA-256 of `projection.bin`. |
| `index_<0…7>.bin` | Byte ranges of one file in Mooligan's `CardFeaturePrintIndex` layout (format 1): header, Float16 vectors, shortlist projection, Float16 shortlist rows, master version, ids. Concatenated in order, it is the index Mooligan maps, with nothing to unarchive. |
| `projection.bin` | The master's shortlist projection, 128 × 768 Float32. Kept until a rebase, so every patch is projected the same way as devices' copies. |
| `patch_<n>.bin` | Patch `n` as rows: a header (`"MTGP"`, version 1, count, dimension, shortlist dimension, ids length, patch number), Float16 vectors, projected Float16 shortlist rows, ids. |

Face IDs are the Scryfall card ID, or `<cardId>-face<i>` for multi-faced cards without top-level images.

### Pack data

`odds.swift` runs after the indexer and publishes, from MTGJSON's AllSetFiles:

| File | Contents |
| --- | --- |
| `pull-odds-meta.json` | `{format, mtgjsonVersion, bytes, printings, products}`: what Mooligan checks each day. |
| `pull-odds.json` | Every printing's chance in each product that holds it, keyed by Scryfall id: `{format, mtgjsonVersion, products: [{id, name, setName}], odds: {scryfallId: [[productIndex, chance, foilChance, nonFoilChance]]}}`. Covers other sets' packs: commander decks in the parent's Collector Booster, bonus sheets, and printings filed under one set but sold in another's. |
| `boosters/<SET>.json` | The set's MTGJSON `booster` object, unchanged, with a stub (`uuid`, `rarity`, `identifiers.scryfallId`) for every card its sheets draw from, whichever set it is filed under. |

The chance maths is Mooligan's `MTGJSONBoosterConfig.chances()`, and the two are kept in step.

It also writes `work/scryfall-ids.tsv`, MTGJSON uuid to Scryfall id, for the price step. That file is not published.

### Prices

`prices.swift` runs after the pack data, compiled with `-O` because it streams MTGJSON's AllPrices (about 1.2 GB unpacked). It keeps only what Mooligan's card page shows: TCGplayer's retail price per finish, day by day, and Card Kingdom's latest retail and buylist price per finish.

| File | Contents |
| --- | --- |
| `prices-meta.json` | `{format, mtgjsonVersion, firstDay, lastDay, cards, full: {path, bytes}, days: [{day, previousDay, path, bytes}]}`: what Mooligan checks, four times a day at most. |
| `prices/history.bin.gz` | Every card's prices over the days MTGJSON keeps (about 90), about 7 MB. |
| `prices/<YYYY-MM-DD>.bin.gz` | The cards whose prices changed that day, for each of the last 14 days MTGJSON has, about 700 KB each. A price that is not listed held from `previousDay`. |

The binary layouts are described at the top of `prices.swift`. A phone whose prices run up to one of the listed `previousDay`s downloads only the days after it. Otherwise it downloads the whole history again.

### Client protocol

Mooligan uses the flat index when `index.json` is published: it downloads the parts straight into its index file, and applies `patch_<n>.bin` files when its copy is on the same master with the same projection and at most 20 patches behind. Older versions keep using the archived files below, which are still published unchanged.

For the archived files:
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

The price step reads a local AllPrices file when `ALLPRICES_FILE` is set:

```bash
swift odds.swift && swiftc -O prices.swift -o prices-builder && ALLPRICES_FILE=AllPrices.json.xz ./prices-builder
```

`FULL_REBUILD=1` skips fetching the previous state. Without it, the run aborts if the state server is unreachable, so a network blip never triggers a full rebuild.
