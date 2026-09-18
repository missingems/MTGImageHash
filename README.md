# MTGImageHash
A Magic: The Gathering perceptual-hash (pHash) database, rebuilt twice daily from Scryfall.

## Download links (stable)

These URLs never change; the files behind them are replaced on every rebuild.

| File | URL |
| --- | --- |
| iOS database (LZFSE-compressed binary plist of `[{id, hash}]`) | https://github.com/missingems/MTGImageHash/releases/download/db-latest/MTG_Hashes.bplist |
| Manifest (`version`, `cardCount`, `lastUpdated`) | https://github.com/missingems/MTGImageHash/releases/download/db-latest/manifest.json |
| Web/visualizer data (JSON) | https://github.com/missingems/MTGImageHash/releases/download/db-latest/visualizer_data.json |

Legacy: `https://raw.githubusercontent.com/missingems/MTGImageHash/main/MTG_Hashes.bplist` is also kept up to date for older Mooligan builds. New builds should use the release URL.

Clients should fetch `manifest.json` first and download the database only when `version` is newer than the cached copy.

Visualizer: https://missingems.github.io/MTGImageHash/

## How it works

`indexer.swift` downloads Scryfall's `default_cards` bulk data, fetches every card face's `small` image, and computes a 64-bit DCT pHash (32×32 grayscale → 2D DCT via Accelerate → 8×8 low-frequency block minus DC → median threshold).

The `MTG Indexing` GitHub Actions workflow runs it at 10:17 and 22:17 UTC and publishes the output to the `db-latest` release.

Local test run:

```bash
OUTPUT_DIR=dist MTG_LIMIT=300 swift indexer.swift
```
