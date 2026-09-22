// Builds Mooligan's pack data from MTGJSON, once a day on CI, so the app never downloads
// multi-megabyte set files to work out one card's pull rate.
//
// Published beside the card image database (OUTPUT_DIR):
//   pull-odds-meta.json   {format, mtgjsonVersion, bytes}: what the app checks each day
//   pull-odds.json        every paper printing's chance in each product that holds it, keyed by
//                         Scryfall id, across every set: a commander deck's cards in the parent's
//                         Collector Booster, a bonus sheet's in the main set's, and printings filed
//                         under one set but sold in another's (Dominaria United's concept praetors
//                         in Phyrexia: All Will Be One's)
//   boosters/<SET>.json   the set's MTGJSON booster configuration, unchanged, with a stub for every
//                         card its sheets draw from, its own or another set's: what the pack
//                         simulator rolls packs from
//
// The chance maths is Mooligan's `MTGJSONBoosterConfig.chances()`, kept in step with it.

import Foundation

enum OddsConfig {
    static let env = ProcessInfo.processInfo.environment
    static let outputDir = URL(fileURLWithPath: env["OUTPUT_DIR"] ?? "site", isDirectory: true)
    /// A folder of MTGJSON set files to use instead of downloading AllSetFiles.zip, for local runs.
    static let idsFile = URL(fileURLWithPath: env["IDS_FILE"] ?? "work/scryfall-ids.tsv")
    static let setFilesDir = env["MTGJSON_SET_FILES"].map { URL(fileURLWithPath: $0, isDirectory: true) }
}

// MARK: - MTGJSON models (the fields the maths reads)

struct OddsSetFile: Decodable { let data: OddsSetData }

struct OddsSetData: Decodable {
    let code: String
    let name: String?
    let booster: [String: OddsBoosterConfig]?
    let cards: [OddsCardStub]
}

struct OddsCardStub: Decodable {
    struct Identifiers: Decodable { let scryfallId: String? }
    let uuid: String
    let rarity: String?
    let identifiers: Identifiers?
}

struct OddsBoosterConfig: Decodable {
    let name: String?
    let boosters: [OddsLayout]?
    let boostersTotalWeight: Double?
    let sheets: [String: OddsSheet]
}

struct OddsLayout: Decodable {
    let contents: [String: Int]
    let weight: Double
}

struct OddsSheet: Decodable {
    let cards: [String: Double]
    let foil: Bool
    let totalWeight: Double?
    let allowDuplicates: Bool?
    /// A pack takes every card of a fixed sheet, as a Jumpstart pack takes its whole theme.
    let fixed: Bool?
}

struct OddsMeta: Decodable {
    struct Meta: Decodable { let version: String }
    let data: Meta
}

// MARK: - Output

struct PullOddsProduct: Encodable {
    /// "<set code>/<MTGJSON product key>", lowercased, as Mooligan's ProductPullOdds.id.
    let id: String
    /// The product's name without its set's: "Play Booster".
    let name: String
    let setName: String
}

struct PullOddsFile: Encodable {
    let format: Int
    let mtgjsonVersion: String
    let products: [PullOddsProduct]
    /// Scryfall id to [product index, chance, foil chance, non-foil chance] per product.
    let odds: [String: [[Double]]]
}

struct PullOddsMetaFile: Encodable {
    let format: Int
    let mtgjsonVersion: String
    let bytes: Int
    let printings: Int
    let products: Int
}

// MARK: - Maths, as Mooligan's MTGJSONBoosterConfig.chances()

func chances(of config: OddsBoosterConfig) -> [String: (any: Double, foil: Double, nonFoil: Double)] {
    guard let boosters = config.boosters else { return [:] }
    let totalWeight = config.boostersTotalWeight ?? boosters.reduce(0) { $0 + $1.weight }
    guard totalWeight > 0 else { return [:] }

    var chances: [String: (any: Double, foil: Double, nonFoil: Double)] = [:]
    for layout in boosters where layout.weight > 0 {
        var foilMiss: [String: Double] = [:]
        var nonFoilMiss: [String: Double] = [:]
        for (sheetName, count) in layout.contents where count > 0 {
            guard let sheet = config.sheets[sheetName] else { continue }
            let sheetWeight = sheet.totalWeight ?? sheet.cards.values.reduce(0, +)
            guard sheetWeight > 0 else { continue }
            for (uuid, weight) in sheet.cards where weight > 0 {
                let share = weight / sheetWeight
                let hit = sheet.fixed == true ? 1 : sheet.allowDuplicates == true ? 1 - pow(1 - share, Double(count)) : min(1, Double(count) * share)
                if sheet.foil { foilMiss[uuid, default: 1] *= 1 - hit } else { nonFoilMiss[uuid, default: 1] *= 1 - hit }
            }
        }
        let layoutShare = layout.weight / totalWeight
        for uuid in Set(foilMiss.keys).union(nonFoilMiss.keys) {
            let foil = foilMiss[uuid] ?? 1, nonFoil = nonFoilMiss[uuid] ?? 1
            var chance = chances[uuid] ?? (0, 0, 0)
            chance.any += layoutShare * (1 - foil * nonFoil)
            chance.foil += layoutShare * (1 - foil)
            chance.nonFoil += layoutShare * (1 - nonFoil)
            chances[uuid] = chance
        }
    }
    return chances.filter { $0.value.any > 0 }
}

/// "Bloomburrow Play Booster" is "Play Booster": the set is on screen already.
func productName(_ config: OddsBoosterConfig, key: String, setName: String?) -> String {
    guard let full = config.name else {
        return key.split(separator: "-").map(\.capitalized).joined(separator: " ") + " Booster"
    }
    guard let setName, full.hasPrefix(setName), full.count > setName.count else { return full }
    return full.dropFirst(setName.count).trimmingCharacters(in: .whitespaces)
}

/// Four significant figures: enough for "1 in n packs", and a third of the file.
func rounded(_ value: Double) -> Double {
    Double(String(format: "%.4g", value)) ?? value
}

func fail(_ message: String) -> Never {
    print("❌ \(message)")
    exit(1)
}

// MARK: - Main

func run(_ command: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: command)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { fail("\(command) \(arguments.joined(separator: " ")) failed") }
}

func main() async throws {
    let start = Date()
    let fm = FileManager.default
    let session = URLSession(configuration: .default)

    let (metaData, _) = try await session.data(from: URL(string: "https://mtgjson.com/api/v5/Meta.json")!)
    let version = try JSONDecoder().decode(OddsMeta.self, from: metaData).data.version
    print("🎴 MTGJSON \(version)")

    let setFiles: URL
    if let local = OddsConfig.setFilesDir {
        setFiles = local
    } else {
        let work = fm.temporaryDirectory.appendingPathComponent("mtgjson-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        print("📥 Downloading AllSetFiles.zip")
        let (zip, _) = try await session.download(from: URL(string: "https://mtgjson.com/api/v5/AllSetFiles.zip")!)
        try run("/usr/bin/unzip", ["-q", zip.path, "-d", work.path])
        setFiles = work
    }
    let files = (fm.enumerator(at: setFiles, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
        .filter { $0.pathExtension == "json" }
    guard files.isEmpty == false else { fail("No set files in \(setFiles.path)") }

    // Every card's stub, across every set, for joining sheets' uuids to Scryfall ids.
    var stubs: [String: [String: Any]] = [:]
    var scryfallByUUID: [String: String] = [:]
    var sets: [(data: OddsSetData, booster: [String: Any])] = []
    for file in files {
        try autoreleasepool {
            let data = try Data(contentsOf: file)
            guard let set = try? JSONDecoder().decode(OddsSetFile.self, from: data).data else { return }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let setObject = object["data"] as? [String: Any],
                  let cards = setObject["cards"] as? [[String: Any]] else { return }
            for card in cards {
                guard let uuid = card["uuid"] as? String else { continue }
                var stub: [String: Any] = ["uuid": uuid]
                if let rarity = card["rarity"] { stub["rarity"] = rarity }
                if let identifiers = card["identifiers"] as? [String: Any], let scryfall = identifiers["scryfallId"] as? String {
                    stub["identifiers"] = ["scryfallId": scryfall]
                    scryfallByUUID[uuid] = scryfall.lowercased()
                }
                stubs[uuid] = stub
            }
            if let booster = setObject["booster"] as? [String: Any], booster.isEmpty == false {
                sets.append((set, booster))
            }
        }
    }
    print("🗂️ \(files.count) set files, \(stubs.count) cards, \(sets.count) sets with boosters")

    // Pull odds for every product that is a pack someone opens.
    var products: [PullOddsProduct] = []
    var odds: [String: [[Double]]] = [:]
    for (set, _) in sets.sorted(by: { $0.data.code < $1.data.code }) {
        for (key, config) in (set.booster ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard ["arena", "mtgo", "sample"].contains(where: { key.contains($0) }) == false else { continue }
            let index = Double(products.count)
            products.append(PullOddsProduct(
                id: "\(set.code.lowercased())/\(key)",
                name: productName(config, key: key, setName: set.name),
                setName: set.name ?? set.code
            ))
            for (uuid, chance) in chances(of: config) {
                guard let scryfall = scryfallByUUID[uuid] else { continue }
                odds[scryfall, default: []].append([index, rounded(chance.any), rounded(chance.foil), rounded(chance.nonFoil)])
            }
        }
    }

    let out = OddsConfig.outputDir
    try fm.createDirectory(at: out, withIntermediateDirectories: true)

    // MTGJSON uuid to Scryfall id for prices.swift, which reads AllPrices, keyed by uuid alone. Not
    // published: it is only a step's input.
    try fm.createDirectory(at: OddsConfig.idsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try scryfallByUUID.map { "\($0.key)\t\($0.value)" }.joined(separator: "\n")
        .write(to: OddsConfig.idsFile, atomically: true, encoding: .utf8)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let oddsData = try encoder.encode(PullOddsFile(format: 1, mtgjsonVersion: version, products: products, odds: odds))
    try oddsData.write(to: out.appendingPathComponent("pull-odds.json"))
    let meta = PullOddsMetaFile(format: 1, mtgjsonVersion: version, bytes: oddsData.count, printings: odds.count, products: products.count)
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(meta).write(to: out.appendingPathComponent("pull-odds-meta.json"))
    print("📊 Pull odds: \(odds.count) printings in \(products.count) products, \(oddsData.count / 1_048_576) MB")

    // Booster files for the pack simulator: MTGJSON's booster object as it is, and a stub for every
    // card its sheets name, whichever set the card is filed under.
    let boostersDir = out.appendingPathComponent("boosters", isDirectory: true)
    try fm.createDirectory(at: boostersDir, withIntermediateDirectories: true)
    var written = 0
    for (set, booster) in sets {
        var referenced = Set<String>()
        for case let config as [String: Any] in booster.values {
            for case let sheet as [String: Any] in (config["sheets"] as? [String: Any] ?? [:]).values {
                referenced.formUnion((sheet["cards"] as? [String: Any] ?? [:]).keys)
            }
        }
        let cards = referenced.sorted().compactMap { stubs[$0] }
        var data: [String: Any] = ["code": set.code, "booster": booster, "cards": cards]
        if let name = set.name { data["name"] = name }
        let file = try JSONSerialization.data(withJSONObject: ["meta": ["version": version], "data": data], options: [.sortedKeys])
        try file.write(to: boostersDir.appendingPathComponent("\(set.code.uppercased()).json"))
        written += 1
    }
    print("📦 \(written) booster files")
    print("✅ Pack data in \(Int(Date().timeIntervalSince(start))) s")
}

try await main()
