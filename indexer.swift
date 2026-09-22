// Builds the Vision feature-print database consumed by Mooligan's
// CardImageHashSyncManager, incrementally, from Scryfall bulk data.
//
// The per-image pipeline mirrors the MTGCards app, which produced the database
// bundled in Mooligan: Scryfall `normal` image → NSImage → CGImage →
// VNGenerateImageFeaturePrintRequest revision 2 (scaleFill) → NSKeyedArchiver.
// Changing any of that changes the vector space and breaks matching against
// vectors already on users' devices, so bump `masterVersion` if you do.
//
// Published layout (everything in OUTPUT_DIR is deployed to GitHub Pages):
//   manifest.json                 {masterVersion: String, masterChunks, latestPatch}
//   MTG_Hashes_Master_<i>.lzfse   full current database, split into chunks
//   patch_<n>.lzfse               entries added/changed since patch n-1
//   visualizer_data.json          card metadata; doubles as the incremental-build index
//
// The flat index, which Mooligan downloads straight to disk and maps instead of
// unarchiving a hundred thousand feature prints on the phone (1 GB and every core
// for seconds, measured):
//   index.json                    FlatIndexManifest: parts, patch level, projection digest
//   index_<i>.bin                 byte ranges of one file in Mooligan's CardFeaturePrintIndex
//                                 layout, Float16 vectors and search shortlist included
//   projection.bin                the master's shortlist projection (Float32), kept until a
//                                 rebase so patches are projected the way devices' copies are
//   patch_<n>.bin                 FlatPatch: patch n's ids, Float16 vectors and projected rows
//
// Master chunks always hold the full current state (including every patch), so a
// client that downloads the master is immediately current. `masterVersion` only
// changes on a rebase, which is when clients re-download everything.

import Foundation
import AppKit
import Vision
import Accelerate
import CryptoKit

// MARK: - Config

enum Config {
    static let env = ProcessInfo.processInfo.environment
    /// Directory the site is written to.
    static let outputDir = URL(fileURLWithPath: env["OUTPUT_DIR"] ?? "site", isDirectory: true)
    /// Where the previous run's output is served from.
    static let stateBaseURL = env["STATE_BASE_URL"] ?? "https://missingems.github.io/MTGImageHash"
    /// Ignore previous state and rebuild every vector.
    static let fullRebuild = env["FULL_REBUILD"] == "1"
    /// Optional cap on faces processed, for quick local test runs.
    static let limit = env["MTG_LIMIT"].flatMap(Int.init)
    /// Rebase (new masterVersion, patches cleared) once this many patches exist.
    /// Mooligan re-downloads the master when it is more than 20 patches behind anyway.
    static let maxPatches = Int(env["MAX_PATCHES"] ?? "") ?? 14
    /// Master chunk count. Mooligan fetches MTG_Hashes_Master_0…9 and stops at the first miss.
    static let masterChunks = 8
    /// Abort instead of publishing if more than this fraction of pending faces fail.
    static let maxFailureRatio = 0.02
    static let concurrency = 16
}

// MARK: - Models

// Scryfall replaced `download_uri` (JSON array) with `jsonl_download_uri`
// (gzipped JSON Lines) in mid-2026. Accept either.
struct BulkDataResponse: Codable {
    let downloadUri: String?
    let jsonlDownloadUri: String?
    enum CodingKeys: String, CodingKey {
        case downloadUri = "download_uri"
        case jsonlDownloadUri = "jsonl_download_uri"
    }
}

struct ScryfallCard: Codable {
    let id, name, set: String
    let image_uris: [String: String]?
    let card_faces: [ScryfallCardFace]?
    let games: [String]?
    let layout: String?
}

struct ScryfallCardFace: Codable {
    let name: String
    let image_uris: [String: String]?
}

/// Mooligan decodes `masterVersion` as a String.
struct Manifest: Codable {
    let masterVersion: String
    let masterChunks: Int
    let latestPatch: Int
    var cardCount: Int?
    var lastUpdated: String?
}

struct WebCardRecord: Codable {
    let id: String
    let name: String
    let set: String
    let faceName: String?
    let imageUri: String
}

struct Face {
    let record: WebCardRecord
    let url: URL
}

// MARK: - Networking

// Scryfall's API guidelines require a descriptive User-Agent and an Accept header.
let session: URLSession = {
    let config = URLSessionConfiguration.default
    config.httpAdditionalHeaders = [
        "User-Agent": "MTGImageHash/2.0 (+https://github.com/missingems/MTGImageHash)",
        "Accept": "application/json;q=0.9,*/*;q=0.8",
    ]
    config.timeoutIntervalForRequest = 60
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.httpMaximumConnectionsPerHost = Config.concurrency
    return URLSession(configuration: config)
}()

struct HTTPError: Error, CustomStringConvertible {
    let url: URL
    let status: Int
    var description: String { "HTTP \(status) for \(url.absoluteString)" }
}

/// Fetches a URL, returning nil on 404 and throwing on any other failure.
func fetch(_ url: URL, retries: Int = 3) async throws -> Data? {
    var attempt = 0
    while true {
        do {
            let (data, response) = try await session.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 404 { return nil }
            if status == 200 { return data }
            throw HTTPError(url: url, status: status)
        } catch {
            attempt += 1
            if attempt > retries { throw error }
            try await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
        }
    }
}

func fail(_ message: String) -> Never {
    print("❌ \(message)")
    exit(1)
}

// MARK: - Scryfall catalog

func fetchCards() async throws -> [ScryfallCard] {
    guard let metaData = try await fetch(URL(string: "https://api.scryfall.com/bulk-data/default-cards")!) else {
        fail("Scryfall bulk-data endpoint returned 404")
    }
    let bulkMeta = try JSONDecoder().decode(BulkDataResponse.self, from: metaData)
    let decoder = JSONDecoder()

    if let jsonl = bulkMeta.jsonlDownloadUri, let url = URL(string: jsonl) {
        print("📥 Downloading JSONL catalog: \(url.lastPathComponent)")
        let (tmp, _) = try await session.download(from: url)
        let gz = tmp.deletingLastPathComponent().appendingPathComponent("default-cards-\(UUID().uuidString).jsonl.gz")
        try FileManager.default.moveItem(at: tmp, to: gz)
        defer { try? FileManager.default.removeItem(at: gz) }

        let gunzip = Process()
        gunzip.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        gunzip.arguments = ["-f", gz.path]
        try gunzip.run()
        gunzip.waitUntilExit()
        guard gunzip.terminationStatus == 0 else { fail("gunzip failed") }
        let jsonlFile = gz.deletingPathExtension()
        defer { try? FileManager.default.removeItem(at: jsonlFile) }

        let data = try Data(contentsOf: jsonlFile)
        var cards: [ScryfallCard] = []
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            cards.append(try decoder.decode(ScryfallCard.self, from: Data(line)))
        }
        return cards
    } else if let json = bulkMeta.downloadUri, let url = URL(string: json) {
        print("📥 Downloading JSON catalog: \(url.lastPathComponent)")
        guard let data = try await fetch(url) else { fail("Bulk file 404") }
        return try decoder.decode([ScryfallCard].self, from: data)
    }
    fail("Bulk data response had no download URI: \(String(decoding: metaData, as: UTF8.self))")
}

/// Same selection and face-id scheme as the MTGCards app.
func faces(from cards: [ScryfallCard]) -> [Face] {
    let invalidLayouts: Set<String> = ["substitute", "checklist", "art_series"]
    var result: [Face] = []
    for card in cards {
        guard card.games?.contains("paper") ?? false, !invalidLayouts.contains(card.layout ?? "") else { continue }
        let set = card.set.uppercased()
        if let normal = card.image_uris?["normal"], let url = URL(string: normal) {
            result.append(Face(record: WebCardRecord(id: card.id, name: card.name, set: set, faceName: nil, imageUri: normal), url: url))
        } else if let cardFaces = card.card_faces {
            for (idx, face) in cardFaces.enumerated() {
                guard let normal = face.image_uris?["normal"], let url = URL(string: normal) else { continue }
                result.append(Face(record: WebCardRecord(id: "\(card.id)-face\(idx)", name: card.name, set: set, faceName: face.name, imageUri: normal), url: url))
            }
        }
    }
    return result
}

// MARK: - Feature prints

// Vision's perform() blocks while it waits on its own internal queues. Calling it
// from Swift concurrency's fixed-size cooperative pool can occupy every thread
// and deadlock, so it runs on a dedicated, bounded OperationQueue instead.
let visionQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = ProcessInfo.processInfo.activeProcessorCount
    queue.qualityOfService = .userInitiated
    return queue
}()

func computeFeaturePrint(_ imageData: Data) -> Data? {
    guard let image = NSImage(data: imageData),
          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let request = VNGenerateImageFeaturePrintRequest()
    request.revision = VNGenerateImageFeaturePrintRequestRevision2
    request.imageCropAndScaleOption = .scaleFill
    do {
        try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        guard let observation = request.results?.first as? VNFeaturePrintObservation else { return nil }
        return try NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true)
    } catch {
        return nil
    }
}

/// Rounds an archived feature print's floats to Float16 precision.
///
/// Apple Silicon Macs and iPhones compute feature prints on the Neural Engine in
/// half precision, so their vectors (including the database bundled in Mooligan)
/// are Float16-exact. CI's virtualised Mac falls back to full-precision CPU
/// output, which is no more accurate for matching but compresses ~40% worse.
/// Rounding brings CI output back in line with on-device vectors. Idempotent.
func quantizeToHalfPrecision(_ archived: Data) -> Data {
    guard let observation = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: archived),
          observation.elementType == .float,
          var plist = try? PropertyListSerialization.propertyList(from: archived, options: [], format: nil) as? [String: Any],
          var objects = plist["$objects"] as? [Any],
          let index = objects.firstIndex(where: { ($0 as? Data) == observation.data }) else { return archived }

    var floats = [Float](repeating: 0, count: observation.elementCount)
    _ = floats.withUnsafeMutableBytes { observation.data.copyBytes(to: $0) }
    let rounded = floats.map { Float(Float16($0)) }
    guard rounded != floats else { return archived }

    objects[index] = rounded.withUnsafeBytes { Data($0) }
    plist["$objects"] = objects
    guard let result = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0),
          let check = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: result),
          check.data == objects[index] as? Data else { return archived }
    return result
}

func featurePrint(for url: URL) async -> Data? {
    guard let imageData = try? await fetch(url) else { return nil }
    return await withCheckedContinuation { continuation in
        visionQueue.addOperation { continuation.resume(returning: computeFeaturePrint(imageData).map(quantizeToHalfPrecision)) }
    }
}

// MARK: - Database files

func encodeDatabase(_ dict: [String: Data]) throws -> Data {
    let plist = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
    return try (plist as NSData).compressed(using: .lzfse) as Data
}

func decodeDatabase(_ data: Data) throws -> [String: Data] {
    let plist = try (data as NSData).decompressed(using: .lzfse) as Data
    guard let dict = try PropertyListSerialization.propertyList(from: plist, options: [], format: nil) as? [String: Data] else {
        fail("Database file is not a [String: Data] plist")
    }
    return dict
}

/// Pages sits behind a CDN with a 10-minute TTL; a unique query string makes
/// back-to-back runs read the deployment that just finished, not a cached one.
struct CacheBustingBase {
    let base: URL
    let token = String(Int(Date().timeIntervalSince1970))
    init(_ base: URL) { self.base = base }
    func appendingPathComponent(_ path: String) -> URL {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "t", value: token)]
        return components.url!
    }
}

struct PreviousState {
    let manifest: Manifest
    var vectors: [String: Data]
    var imageUris: [String: String]
    var patches: [Int: Data]
    /// The shortlist projection the flat index was published with, nil before the flat index existed.
    var projection: [Float]?
}

/// Loads the previously published site. Returns nil when there is nothing usable
/// to build on (first run, or the old pHash format); throws when state exists but
/// could not be fetched, so a flaky network never triggers an accidental rebuild.
func loadPreviousState() async throws -> PreviousState? {
    let base = CacheBustingBase(URL(string: Config.stateBaseURL)!)
    guard let manifestData = try await fetch(base.appendingPathComponent("manifest.json")),
          let manifest = try? JSONDecoder().decode(Manifest.self, from: manifestData) else { return nil }
    print("📦 Previous state: master \(manifest.masterVersion), patch \(manifest.latestPatch), \(manifest.masterChunks) chunks")

    var vectors: [String: Data] = [:]
    for i in 0..<manifest.masterChunks {
        guard let chunk = try await fetch(base.appendingPathComponent("MTG_Hashes_Master_\(i).lzfse")) else {
            throw HTTPError(url: base.appendingPathComponent("MTG_Hashes_Master_\(i).lzfse"), status: 404)
        }
        vectors.merge(try decodeDatabase(chunk)) { _, new in new }
    }

    var patches: [Int: Data] = [:]
    if manifest.latestPatch > 0 {
        for n in 1...manifest.latestPatch {
            let url = base.appendingPathComponent("patch_\(n).lzfse")
            guard let patch = try await fetch(url) else { throw HTTPError(url: url, status: 404) }
            patches[n] = patch
        }
    }

    guard let indexData = try await fetch(base.appendingPathComponent("visualizer_data.json")) else {
        throw HTTPError(url: base.appendingPathComponent("visualizer_data.json"), status: 404)
    }
    let records = try JSONDecoder().decode([WebCardRecord].self, from: indexData)
    let imageUris = Dictionary(records.map { ($0.id, $0.imageUri) }, uniquingKeysWith: { _, new in new })

    let projection = try await fetch(base.appendingPathComponent("projection.bin")).map { data in
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    return PreviousState(manifest: manifest, vectors: vectors, imageUris: imageUris, patches: patches, projection: projection)
}

// MARK: - Main

struct Indexer {
    static func main() async {
        let startTime = Date()
        do {
            print("🚀 Starting MTG feature-print indexer")
            var allFaces = faces(from: try await fetchCards())
            if let limit = Config.limit { allFaces = Array(allFaces.prefix(limit)) }
            print("⚙️ \(allFaces.count) paper card faces in catalog")

            let previous = Config.fullRebuild ? nil : try await loadPreviousState()
            if previous == nil { print("🆕 No usable previous state: full build") }

            // Carry over vectors whose image hasn't changed (the URL embeds a timestamp).
            let currentIds = Set(allFaces.map(\.record.id))
            var vectors = previous?.vectors ?? [:]
            let removedIds = Set(vectors.keys).subtracting(currentIds)
            var requantized = 0
            for (id, data) in vectors {
                let rounded = quantizeToHalfPrecision(data)
                if rounded != data { vectors[id] = rounded; requantized += 1 }
            }
            if requantized > 0 { print("🔧 Rounded \(requantized) carried-over vectors to half precision") }
            let pending = allFaces.filter { face in
                let upToDate = vectors[face.record.id] != nil && previous?.imageUris[face.record.id] == face.record.imageUri
                return !upToDate
            }
            print("🧮 \(pending.count) faces to (re)compute, \(allFaces.count - pending.count) reused, \(removedIds.count) no longer in catalog")

            var changed: [String: Data] = [:]
            var failures: [String] = []
            var completed = 0
            await withTaskGroup(of: (String, Data?).self) { group in
                var iterator = pending.makeIterator()
                for _ in 0..<Config.concurrency {
                    guard let face = iterator.next() else { break }
                    group.addTask { (face.record.id, await featurePrint(for: face.url)) }
                }
                for await (id, data) in group {
                    completed += 1
                    if let data { changed[id] = data } else { failures.append(id) }
                    if completed % 1000 == 0 {
                        let rate = Double(completed) / Date().timeIntervalSince(startTime)
                        print("⏳ \(completed) / \(pending.count) (\(Int(rate))/s)")
                    }
                    if let face = iterator.next() {
                        group.addTask { (face.record.id, await featurePrint(for: face.url)) }
                    }
                }
            }

            let failureRatio = Double(failures.count) / Double(max(pending.count, 1))
            print("📊 Computed \(changed.count), failed \(failures.count) (\(String(format: "%.2f", failureRatio * 100))%)")
            if !failures.isEmpty { print("   e.g. \(failures.prefix(5).joined(separator: ", "))") }
            guard failureRatio <= Config.maxFailureRatio else { fail("Too many failures; refusing to publish") }

            vectors.merge(changed) { _, new in new }
            // Faces that failed keep their old vector (if any), so keep their old URL
            // in the index too; that makes the next run retry them.
            var records = allFaces.map(\.record)
            if let previous {
                let failed = Set(failures)
                records = records.map { r in
                    guard failed.contains(r.id), let oldUri = previous.imageUris[r.id] else { return r }
                    return WebCardRecord(id: r.id, name: r.name, set: r.set, faceName: r.faceName, imageUri: oldUri)
                }
            }
            records = records.filter { vectors[$0.id] != nil }.sorted { $0.id < $1.id }

            // Decide master/patch versioning.
            let now = Date()
            var patches = previous?.patches ?? [:]
            var masterVersion = previous?.manifest.masterVersion ?? String(Int(now.timeIntervalSince1970))
            var latestPatch = previous?.manifest.latestPatch ?? 0
            if previous != nil && (!changed.isEmpty || requantized > 0) {
                if latestPatch >= Config.maxPatches || requantized > 0 {
                    // Patches can only add/replace entries, so faces that left the
                    // catalog linger on devices until a rebase drops them. Rebasing
                    // for every removal would make every client re-download the master.
                    masterVersion = String(Int(now.timeIntervalSince1970))
                    for id in removedIds { vectors[id] = nil }
                    latestPatch = 0
                    patches = [:]
                    print("🔁 Rebasing to master \(masterVersion)")
                } else {
                    latestPatch += 1
                    patches[latestPatch] = try encodeDatabase(changed)
                    print("🩹 Patch \(latestPatch) with \(changed.count) entries")
                }
            } else if previous != nil {
                print("✨ No changes")
            }

            // Write the site.
            let fm = FileManager.default
            try? fm.removeItem(at: Config.outputDir)
            try fm.createDirectory(at: Config.outputDir, withIntermediateDirectories: true)

            let sortedIds = vectors.keys.sorted()
            let chunkSize = (sortedIds.count + Config.masterChunks - 1) / Config.masterChunks
            for i in 0..<Config.masterChunks {
                let ids = sortedIds[min(i * chunkSize, sortedIds.count)..<min((i + 1) * chunkSize, sortedIds.count)]
                let chunk = Dictionary(uniqueKeysWithValues: ids.map { ($0, vectors[$0]!) })
                try encodeDatabase(chunk).write(to: Config.outputDir.appendingPathComponent("MTG_Hashes_Master_\(i).lzfse"))
            }
            for (n, data) in patches {
                try data.write(to: Config.outputDir.appendingPathComponent("patch_\(n).lzfse"))
            }
            try JSONEncoder().encode(records).write(to: Config.outputDir.appendingPathComponent("visualizer_data.json"))

            // The flat index. Its projection is the master's, carried over while the master holds, so
            // rows published in later patches are projected as devices' copies were.
            let keepsProjection = previous?.manifest.masterVersion == masterVersion
            try writeFlatIndex(
                vectors: vectors,
                patches: patches,
                masterVersion: masterVersion,
                latestPatch: latestPatch,
                previousProjection: keepsProjection ? previous?.projection : nil,
                to: Config.outputDir
            )

            let manifest = Manifest(masterVersion: masterVersion, masterChunks: Config.masterChunks, latestPatch: latestPatch,
                                    cardCount: vectors.count, lastUpdated: ISO8601DateFormatter().string(from: now))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: Config.outputDir.appendingPathComponent("manifest.json"))

            print("✅ \(vectors.count) vectors, master \(masterVersion), patch \(latestPatch), in \(Int(Date().timeIntervalSince(startTime) / 60)) min")
        } catch {
            fail("Fatal Error: \(error)")
        }
    }
}

// MARK: - Flat index

/// Mooligan's CardFeaturePrintIndex file header magic ("MTGV") and FlatPatch magic ("MTGP").
let flatIndexMagic: UInt32 = 0x5647_544D
let flatPatchMagic: UInt32 = 0x5047_544D
let flatIndexParts = 8
let shortlistDimension = 128

struct FlatIndexManifest: Codable {
    /// 1: CardFeaturePrintIndex format version 1, split into `parts`.
    let format: Int
    let masterVersion: String
    let latestPatch: Int
    let cardCount: Int
    let dimension: Int
    let shortlistDimension: Int
    let parts: [String]
    let bytes: Int
    /// SHA-256 of the projection's bytes: a device whose copy was projected differently takes the
    /// whole index rather than patches it cannot line up.
    let projection: String
}

/// Feature prints as Float16 rows, in the order of `ids`, skipping any that do not unarchive or are
/// not finite, as Mooligan does.
func halfRows(_ vectors: [String: Data], ids: [String]) -> (ids: [String], dimension: Int, rows: [Float16]) {
    var kept: [String] = []
    var rows: [Float16] = []
    var dimension = 0
    for id in ids {
        autoreleasepool {
            guard let archive = vectors[id],
                  let observation = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: archive),
                  observation.elementType == .float else { return }
            if dimension == 0 {
                dimension = observation.elementCount
                rows.reserveCapacity(ids.count * dimension)
            }
            guard observation.elementCount == dimension else { return }
            var floats = [Float](repeating: 0, count: dimension)
            _ = floats.withUnsafeMutableBytes { observation.data.copyBytes(to: $0) }
            guard floats.allSatisfy(\.isFinite) else { return }
            kept.append(id)
            rows.append(contentsOf: floats.map { Float16($0) })
        }
    }
    return (kept, dimension, rows)
}

/// The 128 directions the vectors vary along most, from ~8,000 of them, one row of `dimension` each,
/// as Mooligan's `compressedForSearch()` works them out.
func shortlistProjection(_ rows: [Float16], count: Int, dimension: Int) -> [Float] {
    let sampleRows = Array(stride(from: 0, to: count, by: max(1, count / 8_192)))
    var sample = [Float](repeating: 0, count: sampleRows.count * dimension)
    for (position, row) in sampleRows.enumerated() {
        for column in 0..<dimension { sample[position * dimension + column] = Float(rows[row * dimension + column]) }
    }
    var mean = [Float](repeating: 0, count: dimension)
    for column in 0..<dimension {
        var total: Float = 0
        for position in 0..<sampleRows.count { total += sample[position * dimension + column] }
        mean[column] = total / Float(sampleRows.count)
    }
    var covariance = [Float](repeating: 0, count: dimension * dimension)
    cblas_sgemm(CblasRowMajor, CblasTrans, CblasNoTrans, Int32(dimension), Int32(dimension), Int32(sampleRows.count),
                1 / Float(sampleRows.count), sample, Int32(dimension), sample, Int32(dimension), 0, &covariance, Int32(dimension))
    cblas_sger(CblasRowMajor, Int32(dimension), Int32(dimension), -1, mean, 1, mean, 1, &covariance, Int32(dimension))

    var eigenvalues = [Float](repeating: 0, count: dimension)
    var order = __CLPK_integer(dimension), leading = __CLPK_integer(dimension)
    var workSize = __CLPK_integer(-1), optimal: Float = 0, info = __CLPK_integer(0)
    var jobz = Int8(UInt8(ascii: "V")), uplo = Int8(UInt8(ascii: "U"))
    ssyev_(&jobz, &uplo, &order, &covariance, &leading, &eigenvalues, &optimal, &workSize, &info)
    workSize = __CLPK_integer(optimal)
    var work = [Float](repeating: 0, count: Int(workSize))
    ssyev_(&jobz, &uplo, &order, &covariance, &leading, &eigenvalues, &work, &workSize, &info)
    guard info == 0 else { fail("Could not work out the shortlist projection (ssyev \(info))") }
    // Eigenvectors come by ascending eigenvalue, one per run of `dimension`: the last 128 are wanted.
    return Array(covariance[(dimension - shortlistDimension) * dimension..<dimension * dimension])
}

/// Every row projected onto `projection`, as Float16.
func projected(_ rows: [Float16], count: Int, dimension: Int, projection: [Float]) -> [Float16] {
    var output = [Float16]()
    output.reserveCapacity(count * shortlistDimension)
    var block = [Float](repeating: 0, count: 4_096 * dimension)
    var projectedBlock = [Float](repeating: 0, count: 4_096 * shortlistDimension)
    for start in stride(from: 0, to: count, by: 4_096) {
        let end = min(start + 4_096, count)
        for index in 0..<(end - start) * dimension { block[index] = Float(rows[start * dimension + index]) }
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(end - start), Int32(shortlistDimension), Int32(dimension),
                    1, block, Int32(dimension), projection, Int32(dimension), 0, &projectedBlock, Int32(shortlistDimension))
        output.append(contentsOf: projectedBlock[0..<(end - start) * shortlistDimension].map { Float16($0) })
    }
    return output
}

func littleEndianHeader(_ fields: [UInt32]) -> Data {
    fields.map(\.littleEndian).withUnsafeBytes { Data($0) }
}

func bytes<T>(_ array: [T]) -> Data {
    array.withUnsafeBytes { Data($0) }
}

func writeFlatIndex(
    vectors: [String: Data],
    patches: [Int: Data],
    masterVersion: String,
    latestPatch: Int,
    previousProjection: [Float]?,
    to directory: URL
) throws {
    let (ids, dimension, rows) = halfRows(vectors, ids: vectors.keys.sorted())
    guard dimension > 0 else { fail("No feature prints to write the flat index from") }
    let projection = previousProjection.flatMap { $0.count == shortlistDimension * dimension ? $0 : nil }
        ?? shortlistProjection(rows, count: ids.count, dimension: dimension)
    let shortlist = projected(rows, count: ids.count, dimension: dimension, projection: projection)

    // CardFeaturePrintIndex format 1: header, vectors, projection, shortlist, master version, ids.
    let version = Data(masterVersion.utf8)
    let idData = Data(ids.joined(separator: "\n").utf8)
    var file = littleEndianHeader([
        flatIndexMagic, 1, UInt32(ids.count), UInt32(dimension), UInt32(bitPattern: Int32(latestPatch)),
        UInt32(version.count), UInt32(idData.count), UInt32(shortlistDimension),
    ])
    file.append(bytes(rows))
    file.append(bytes(projection))
    file.append(bytes(shortlist))
    file.append(version)
    file.append(idData)

    let partSize = (file.count + flatIndexParts - 1) / flatIndexParts
    var parts: [String] = []
    for part in 0..<flatIndexParts {
        let range = min(part * partSize, file.count)..<min((part + 1) * partSize, file.count)
        let name = "index_\(part).bin"
        try file.subdata(in: range).write(to: directory.appendingPathComponent(name))
        parts.append(name)
    }
    let projectionData = bytes(projection)
    try projectionData.write(to: directory.appendingPathComponent("projection.bin"))

    for (number, patch) in patches {
        let entries = try decodeDatabase(patch)
        let (patchIDs, patchDimension, patchRows) = halfRows(entries, ids: entries.keys.sorted())
        guard patchDimension == dimension || patchIDs.isEmpty else { fail("Patch \(number) has \(patchDimension)-float prints") }
        let patchShortlist = projected(patchRows, count: patchIDs.count, dimension: dimension, projection: projection)
        let patchIDData = Data(patchIDs.joined(separator: "\n").utf8)
        var patchFile = littleEndianHeader([
            flatPatchMagic, 1, UInt32(patchIDs.count), UInt32(dimension), UInt32(shortlistDimension),
            UInt32(patchIDData.count), UInt32(number), 0,
        ])
        patchFile.append(bytes(patchRows))
        patchFile.append(bytes(patchShortlist))
        patchFile.append(patchIDData)
        try patchFile.write(to: directory.appendingPathComponent("patch_\(number).bin"))
    }

    let manifest = FlatIndexManifest(
        format: 1,
        masterVersion: masterVersion,
        latestPatch: latestPatch,
        cardCount: ids.count,
        dimension: dimension,
        shortlistDimension: shortlistDimension,
        parts: parts,
        bytes: file.count,
        projection: SHA256.hash(data: projectionData).map { String(format: "%02x", $0) }.joined()
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(manifest).write(to: directory.appendingPathComponent("index.json"))
    print("🗂️ Flat index: \(ids.count) faces, \(file.count / 1_048_576) MB in \(flatIndexParts) parts, \(patches.count) flat patches")
}

await Indexer.main()
