import Foundation
import AppKit
import Accelerate

// MARK: - Models
// Scryfall replaced `download_uri` (plain JSON array) with `jsonl_download_uri`
// (gzipped JSON Lines) in mid-2026. Accept either so we survive future flips.
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
}

struct ScryfallCardFace: Codable {
    let name: String
    let image_uris: [String: String]?
}

struct CardHashRecord: Codable {
    let id: String
    let hash: UInt64
}

struct WebCardRecord: Codable {
    let id: String
    let name: String
    let set: String
    let faceName: String?
    let hashHex: String
    let imageUri: String?
}

struct DatabaseManifest: Codable {
    let version: Int
    let cardCount: Int
    let lastUpdated: String
}

// MARK: - Config
enum Config {
    static let env = ProcessInfo.processInfo.environment
    /// Where output files are written (default: current directory).
    static let outputDir = URL(fileURLWithPath: env["OUTPUT_DIR"] ?? ".", isDirectory: true)
    /// Optional cap on faces hashed, for quick local test runs.
    static let limit = env["MTG_LIMIT"].flatMap(Int.init)
    /// Abort instead of publishing if fewer than this fraction of faces hash successfully.
    static let minSuccessRatio = 0.98
}

// Scryfall's API guidelines require a descriptive User-Agent and an Accept header.
let session: URLSession = {
    let config = URLSessionConfiguration.default
    config.httpAdditionalHeaders = [
        "User-Agent": "MTGImageHash/1.0 (+https://github.com/missingems/MTGImageHash)",
        "Accept": "application/json;q=0.9,*/*;q=0.8",
    ]
    config.timeoutIntervalForRequest = 60
    return URLSession(configuration: config)
}()

/// Downloads the bulk card file and decodes it, handling both the legacy JSON array
/// and the gzipped JSON Lines format.
func fetchCards() async throws -> [ScryfallCard] {
    let (metaData, _) = try await session.data(from: URL(string: "https://api.scryfall.com/bulk-data/default-cards")!)
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
        guard gunzip.terminationStatus == 0 else { throw NSError(domain: "Indexer", code: 2, userInfo: [NSLocalizedDescriptionKey: "gunzip failed"]) }
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
        let (data, _) = try await session.data(from: url)
        return try decoder.decode([ScryfallCard].self, from: data)
    }
    throw NSError(domain: "Indexer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bulk data response had no download URI: \(String(decoding: metaData, as: UTF8.self))"])
}

// MARK: - pHash Engine Setup
// Wrapped in an enum to prevent "top-level code" compiler errors in a script
enum MathEngine {
    static let pHashDCTSetup = vDSP_DCT_CreateSetup(nil, 32, .II)!
}

func generatePHash(from url: URL) async -> UInt64? {
    do {
        let (data, _) = try await session.data(from: url)
        guard let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        
        let size = 32
        var pixelBytes = [UInt8](repeating: 0, count: size * size)
        
        guard let ctx = CGContext(data: &pixelBytes, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
        
        var pixels = [Float](repeating: 0, count: size * size)
        vDSP_vfltu8(pixelBytes, 1, &pixels, 1, vDSP_Length(size * size))
        
        // 1. DCT Rows
        var rowDCT = [Float](repeating: 0, count: size * size)
        for row in 0..<size {
            pixels.withUnsafeBufferPointer { src in
                rowDCT.withUnsafeMutableBufferPointer { dst in
                    vDSP_DCT_Execute(MathEngine.pHashDCTSetup, src.baseAddress! + row * size, dst.baseAddress! + row * size)
                }
            }
        }
        
        // 2. Transpose
        var transposed = [Float](repeating: 0, count: size * size)
        vDSP_mtrans(rowDCT, 1, &transposed, 1, vDSP_Length(size), vDSP_Length(size))
        
        // 3. DCT Columns
        var colDCT = [Float](repeating: 0, count: size * size)
        for row in 0..<size {
            transposed.withUnsafeBufferPointer { src in
                colDCT.withUnsafeMutableBufferPointer { dst in
                    vDSP_DCT_Execute(MathEngine.pHashDCTSetup, src.baseAddress! + row * size, dst.baseAddress! + row * size)
                }
            }
        }
        
        // 4. Transpose Back
        var dct = [Float](repeating: 0, count: size * size)
        vDSP_mtrans(colDCT, 1, &dct, 1, vDSP_Length(size), vDSP_Length(size))
        
        // 5. Extract 8x8 Low Frequency
        var low = [Float]()
        low.reserveCapacity(63)
        for y in 0..<8 {
            for x in 0..<8 {
                guard !(x == 0 && y == 0) else { continue }
                low.append(dct[y * size + x])
            }
        }
        
        // 6. Compute Median & Hash
        let median = low.sorted()[low.count / 2]
        var hash: UInt64 = 0
        for (i, v) in low.enumerated() where v > median {
            hash |= (1 << i)
        }
        return hash
    } catch {
        return nil
    }
}

// MARK: - Main Pipeline
struct Job {
    let faceId: String
    let cardName: String
    let setName: String
    let faceName: String?
    let url: URL
}

struct Indexer {
    static func main() async {
        print("🚀 Starting Daily MTG Indexer...")
        let startTime = Date()
        
        do {
            print("📥 Fetching Scryfall Bulk Data Catalog...")
            let cards = try await fetchCards()
            
            var jobs: [Job] = []
            for card in cards {
                if let uris = card.image_uris, let small = uris["small"], let url = URL(string: small) {
                    jobs.append(Job(faceId: card.id, cardName: card.name, setName: card.set, faceName: nil, url: url))
                } else if let faces = card.card_faces {
                    for (idx, face) in faces.enumerated() {
                        if let uris = face.image_uris, let small = uris["small"], let url = URL(string: small) {
                            jobs.append(Job(faceId: "\(card.id)-face\(idx)", cardName: card.name, setName: card.set, faceName: face.name, url: url))
                        }
                    }
                }
            }
            
            if let limit = Config.limit { jobs = Array(jobs.prefix(limit)) }

            print("⚙️ Parsed \(cards.count) cards. Hashing \(jobs.count) faces...")
            
            var iosRecords: [CardHashRecord] = []
            var webRecords: [WebCardRecord] = []
            var completed = 0
            
            // TaskGroup with concurrency limit
            await withTaskGroup(of: (Job, UInt64?).self) { group in
                let maxConcurrent = 20
                var index = 0
                
                while index < maxConcurrent && index < jobs.count {
                    let job = jobs[index]
                    group.addTask { return (job, await generatePHash(from: job.url)) }
                    index += 1
                }
                
                for await (job, hash) in group {
                    completed += 1
                    if completed % 1000 == 0 { print("⏳ Progress: \(completed) / \(jobs.count)") }
                    
                    if let h = hash {
                        iosRecords.append(CardHashRecord(id: job.faceId, hash: h))
                        webRecords.append(WebCardRecord(id: job.faceId, name: job.cardName, set: job.setName.uppercased(), faceName: job.faceName, hashHex: String(h, radix: 16).uppercased(), imageUri: job.url.absoluteString))
                    }
                    
                    if index < jobs.count {
                        let nextJob = jobs[index]
                        group.addTask { return (nextJob, await generatePHash(from: nextJob.url)) }
                        index += 1
                    }
                }
            }
            
            let ratio = Double(iosRecords.count) / Double(max(jobs.count, 1))
            print("📊 Hashed \(iosRecords.count) / \(jobs.count) faces (\(String(format: "%.2f", ratio * 100))%)")
            guard ratio >= Config.minSuccessRatio else {
                print("❌ Success ratio below \(Config.minSuccessRatio * 100)%; refusing to publish a partial database.")
                exit(1)
            }

            // Task group completion order is random; sort so output is deterministic.
            iosRecords.sort { $0.id < $1.id }
            webRecords.sort { $0.id < $1.id }

            print("💾 Encoding iOS BPLIST Database...")
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let iosData = try encoder.encode(iosRecords)
            let compressedIosData = try (iosData as NSData).compressed(using: .lzfse) as Data
            
            print("💾 Encoding Web JSON Database...")
            let webData = try JSONEncoder().encode(webRecords)
            
            print("📄 Generating Manifest...")
            let manifest = DatabaseManifest(version: Int(Date().timeIntervalSince1970), cardCount: iosRecords.count, lastUpdated: ISO8601DateFormatter().string(from: Date()))
            let jsonEncoder = JSONEncoder()
            jsonEncoder.outputFormatting = .prettyPrinted
            let manifestData = try jsonEncoder.encode(manifest)
            
            try FileManager.default.createDirectory(at: Config.outputDir, withIntermediateDirectories: true)
            try compressedIosData.write(to: Config.outputDir.appendingPathComponent("MTG_Hashes.bplist"))
            try webData.write(to: Config.outputDir.appendingPathComponent("visualizer_data.json"))
            try manifestData.write(to: Config.outputDir.appendingPathComponent("manifest.json"))
            
            let elapsed = Date().timeIntervalSince(startTime)
            print("✅ Finished successfully in \(Int(elapsed / 60)) minutes!")
            
        } catch {
            print("❌ Fatal Error: \(error)")
            exit(1)
        }
    }
}

// Execution trigger for the script environment
await Indexer.main()