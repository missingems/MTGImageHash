import Foundation
import AppKit
import Accelerate

// MARK: - Models
struct BulkDataResponse: Codable {
    let downloadUri: String
    enum CodingKeys: String, CodingKey { case downloadUri = "download_uri" }
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

// MARK: - pHash Engine Setup
// Wrapped in an enum to prevent "top-level code" compiler errors
enum MathEngine {
    static let pHashDCTSetup = vDSP_DCT_CreateSetup(nil, 32, .II)!
}

func generatePHash(from url: URL) async -> UInt64? {
    do {
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        
        let size = 32
        var pixelBytes = [UInt8](repeating: 0, count: size * size)
        
        guard let ctx = CGContext(data: &pixelBytes, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
        
        var pixels = [Float](repeating: 0, count: size * size)
        vDSP_vfltu8(pixelBytes, 1, &pixels, 1, vDSP_Length(size * size))
        
        // 1. DCT Rows (Safely accessing memory pointers)
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
        
        // 3. DCT Columns (Safely accessing memory pointers)
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

@main
struct Indexer {
    static func main() async {
        print("🚀 Starting Daily MTG Indexer...")
        let startTime = Date()
        
        do {
            print("📥 Fetching Scryfall Bulk Data Catalog...")
            let (metaData, _) = try await URLSession.shared.data(from: URL(string: "https://api.scryfall.com/bulk-data/default-cards")!)
            let bulkMeta = try JSONDecoder().decode(BulkDataResponse.self, from: metaData)
            
            print("📥 Downloading JSON Catalog...")
            let (data, _) = try await URLSession.shared.data(from: URL(string: bulkMeta.downloadUri)!)
            let cards = try JSONDecoder().decode([ScryfallCard].self, from: data)
            
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
            
            try compressedIosData.write(to: URL(fileURLWithPath: "MTG_Hashes.bplist"))
            try webData.write(to: URL(fileURLWithPath: "visualizer_data.json"))
            try manifestData.write(to: URL(fileURLWithPath: "manifest.json"))
            
            let elapsed = Date().timeIntervalSince(startTime)
            print("✅ Finished successfully in \(Int(elapsed / 60)) minutes!")
            
        } catch {
            print("❌ Fatal Error: \(error)")
            exit(1)
        }
    }
}