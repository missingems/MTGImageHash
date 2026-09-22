// Builds Mooligan's price history from MTGJSON's AllPrices, once a day on CI, so the app downloads
// every card's history in one file and then only each new day's prices, instead of asking
// MTGGraphQL card by card.
//
// Published beside the card image database (OUTPUT_DIR):
//   prices-meta.json          {format, mtgjsonVersion, firstDay, lastDay, cards, full, days}: what the
//                             app checks each day
//   prices/history.bin.gz     every card's prices over the days MTGJSON keeps (about 90)
//   prices/<YYYY-MM-DD>.bin.gz what changed on one day, for each of the last 14 days MTGJSON has: a
//                             phone that has the history up to some day downloads only the days after
//                             it
//
// Only what the card page shows is kept: TCGplayer's retail price per finish, day by day, for the
// chart, and Card Kingdom's latest retail and buylist price per finish, for the buylist ratio. Cards
// are keyed by Scryfall id, joined through IDS_FILE, which odds.swift writes.
//
// The history, little-endian:
//   "MTGH", format u8 = 1, firstDay u32, lastDay u32 (days since 1970-01-01), cardCount u32
//   per card: Scryfall id (16 bytes), historyMask u8 (bit 0 normal, 1 foil, 2 etched),
//             latestMask u8 (bits 0–2 retail normal/foil/etched, 3–5 buylist normal/foil/etched)
//     per history bit: varint count, then per point varint days since the previous point (the first
//                      since firstDay) and zigzag varint cents since the previous point (the first
//                      since zero)
//     per latest bit:  varint days before lastDay, varint cents
//
// A day's file, little-endian, lists only cards whose prices changed that day:
//   "MTGD", format u8 = 1, day u32, previousDay u32 (the day before it that MTGJSON has), cardCount u32
//   per card: Scryfall id (16 bytes), priceMask u8 (a new price that day, bits as historyMask),
//             goneMask u8 (a price the day before and none that day), latestMask u8
//     per price bit: varint cents; per latest bit: varint cents
// Every other series with a price on previousDay has the same price on day, so a phone that has
// the history up to previousDay appends it: most prices do not move from one day to the next, and
// listing them all made each day's file a quarter of the whole history's size.

import Compression
import Foundation

enum PricesConfig {
    static let env = ProcessInfo.processInfo.environment
    static let outputDir = URL(fileURLWithPath: env["OUTPUT_DIR"] ?? "site", isDirectory: true)
    static let idsFile = URL(fileURLWithPath: env["IDS_FILE"] ?? "work/scryfall-ids.tsv")
    /// A local AllPrices.json.xz to use instead of downloading it, for local runs.
    static let localPrices = env["ALLPRICES_FILE"].map { URL(fileURLWithPath: $0) }
}

func fail(_ message: String) -> Never {
    print("❌ \(message)")
    exit(1)
}

// MARK: - Days

/// Days since 1970-01-01 for "YYYY-MM-DD" (Howard Hinnant's days_from_civil).
func dayNumber(_ text: some StringProtocol) -> Int? {
    let parts = text.split(separator: "-")
    guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
    let year = m <= 2 ? y - 1 : y
    let era = year / 400
    let yearOfEra = year - era * 400
    let dayOfYear = (153 * ((m + 9) % 12) + 2) / 5 + d - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    return era * 146_097 + dayOfEra - 719_468
}

func dayText(_ day: Int) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: Date(timeIntervalSince1970: Double(day) * 86_400))
}

// MARK: - One card's prices

struct Point {
    let day: Int
    let cents: Int
}

let finishes = ["normal", "foil", "etched"]

struct CardPrices {
    /// TCGplayer retail, per finish in `finishes` order, oldest first.
    var history: [[Point]] = [[], [], []]
    /// Card Kingdom retail then buylist, per finish, oldest first. Only the latest is published in the
    /// history; the rest say which days' files carry a change.
    var cardKingdom: [[Point]] = Array(repeating: [], count: 6)

    var latest: [Point?] { cardKingdom.map(\.last) }

    var isEmpty: Bool { history.allSatisfy(\.isEmpty) && cardKingdom.allSatisfy(\.isEmpty) }
}

func points(_ object: Any?) -> [Point] {
    guard let byDate = object as? [String: Any] else { return [] }
    return byDate.compactMap { date, value -> Point? in
        guard let day = dayNumber(date), let price = (value as? NSNumber)?.doubleValue, price > 0 else { return nil }
        return Point(day: day, cents: Int((price * 100).rounded()))
    }
    .sorted { $0.day < $1.day }
}

func cardPrices(_ entry: [String: Any]) -> CardPrices {
    let paper = entry["paper"] as? [String: Any]
    let tcgplayer = (paper?["tcgplayer"] as? [String: Any])?["retail"] as? [String: Any]
    let cardKingdom = paper?["cardkingdom"] as? [String: Any]
    let ckRetail = cardKingdom?["retail"] as? [String: Any]
    let ckBuylist = cardKingdom?["buylist"] as? [String: Any]

    var prices = CardPrices()
    for (index, finish) in finishes.enumerated() {
        prices.history[index] = points(tcgplayer?[finish])
        prices.cardKingdom[index] = points(ckRetail?[finish])
        prices.cardKingdom[index + 3] = points(ckBuylist?[finish])
    }
    return prices
}

// MARK: - Streaming AllPrices

/// Hands over each `"<uuid>": {…}` of AllPrices' `data` object as it streams past, so the 1.2 GB file
/// is never held whole. Tracks strings, escapes and nesting byte by byte: an entry is an object
/// opened two levels in, and `meta` holds no objects.
struct EntryScanner {
    private var depth = 0
    private var inString = false
    private var escaped = false
    private var readingKey = false
    private var capturing = false
    private var key: [UInt8] = []
    private var entry: [UInt8] = []

    mutating func feed(_ bytes: UnsafeRawBufferPointer, _ handle: (String, [UInt8]) -> Void) {
        for byte in bytes {
            if capturing { entry.append(byte) }
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                    readingKey = false
                } else if readingKey {
                    key.append(byte)
                }
                continue
            }
            switch byte {
            case 0x22:
                inString = true
                if depth == 2, capturing == false {
                    readingKey = true
                    key.removeAll(keepingCapacity: true)
                }
            case 0x7B, 0x5B:
                depth += 1
                if depth == 3, byte == 0x7B, capturing == false {
                    capturing = true
                    entry.removeAll(keepingCapacity: true)
                    entry.append(byte)
                }
            case 0x7D, 0x5D:
                depth -= 1
                if capturing, depth == 2 {
                    capturing = false
                    handle(String(decoding: key, as: UTF8.self), entry)
                }
            default:
                break
            }
        }
    }
}

/// The version from AllPrices' `meta`, which comes first.
func metaVersion(_ head: [UInt8]) -> String? {
    let text = String(decoding: head.prefix(512), as: UTF8.self)
    guard let range = text.range(of: #""version":"([^"]+)""#, options: .regularExpression) else { return nil }
    return String(text[range].dropFirst(11).dropLast())
}

// MARK: - Writing

struct Writer {
    var bytes: [UInt8] = []

    mutating func u8(_ value: Int) { bytes.append(UInt8(value)) }

    mutating func u32(_ value: Int) {
        let v = UInt32(value)
        bytes += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)]
    }

    mutating func varint(_ value: Int) {
        var v = UInt64(value)
        while v >= 0x80 {
            bytes.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        bytes.append(UInt8(v))
    }

    mutating func zigzag(_ value: Int) {
        varint(value >= 0 ? value << 1 : (-value << 1) - 1)
    }

    mutating func uuid(_ text: String) {
        let u = UUID(uuidString: text)!.uuid
        bytes += [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
    }
}

func encode(_ cards: [(id: String, prices: CardPrices)], firstDay: Int, lastDay: Int) -> [UInt8] {
    var writer = Writer()
    writer.bytes += Array("MTGH".utf8)
    writer.u8(1)
    writer.u32(firstDay)
    writer.u32(lastDay)
    writer.u32(cards.count)
    for (id, prices) in cards {
        writer.uuid(id)
        var historyMask = 0
        for (index, series) in prices.history.enumerated() where series.isEmpty == false { historyMask |= 1 << index }
        var latestMask = 0
        for (index, point) in prices.latest.enumerated() where point != nil { latestMask |= 1 << index }
        writer.u8(historyMask)
        writer.u8(latestMask)
        for series in prices.history where series.isEmpty == false {
            writer.varint(series.count)
            var day = firstDay
            var cents = 0
            for point in series {
                writer.varint(point.day - day)
                writer.zigzag(point.cents - cents)
                day = point.day
                cents = point.cents
            }
        }
        for point in prices.latest {
            guard let point else { continue }
            writer.varint(lastDay - point.day)
            writer.varint(point.cents)
        }
    }
    return writer.bytes
}

func encodeDay(_ cards: [(id: String, prices: CardPrices)], day: Int, previousDay: Int) -> (bytes: [UInt8], cards: Int) {
    var writer = Writer()
    writer.bytes += Array("MTGD".utf8)
    writer.u8(1)
    writer.u32(day)
    writer.u32(previousDay)
    let countAt = writer.bytes.count
    writer.u32(0)
    var count = 0
    for (id, prices) in cards {
        var priceMask = 0
        var goneMask = 0
        var prices = prices
        for (index, series) in prices.history.enumerated() {
            let today = series.last { $0.day == day }
            let before = series.last { $0.day == previousDay }
            if let today, today.cents != before?.cents { priceMask |= 1 << index }
            if today == nil, before != nil { goneMask |= 1 << index }
            prices.history[index] = today.map { [$0] } ?? []
        }
        // Card Kingdom's price where it moved that day: dated afresh every day, it would otherwise put
        // nearly every card in every day's file.
        var latestCents: [Int?] = Array(repeating: nil, count: 6)
        for (index, series) in prices.cardKingdom.enumerated() {
            guard let today = series.last(where: { $0.day == day }) else { continue }
            if series.last(where: { $0.day <= previousDay })?.cents != today.cents { latestCents[index] = today.cents }
        }
        var latestMask = 0
        for (index, cents) in latestCents.enumerated() where cents != nil { latestMask |= 1 << index }
        guard priceMask | goneMask | latestMask != 0 else { continue }
        count += 1
        writer.uuid(id)
        writer.u8(priceMask)
        writer.u8(goneMask)
        writer.u8(latestMask)
        for (index, series) in prices.history.enumerated() where priceMask & (1 << index) != 0 {
            writer.varint(series[0].cents)
        }
        for cents in latestCents {
            guard let cents else { continue }
            writer.varint(cents)
        }
    }
    let v = UInt32(count)
    writer.bytes.replaceSubrange(countAt..<countAt + 4, with: [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)])
    return (writer.bytes, count)
}

func gzip(_ bytes: [UInt8], to url: URL) throws -> Int {
    let raw = url.deletingPathExtension()
    try Data(bytes).write(to: raw)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
    process.arguments = ["-9", "-n", "-f", raw.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { fail("gzip \(raw.lastPathComponent) failed") }
    return (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
}

// MARK: - Manifest

struct PricesFile: Encodable {
    let day: String?
    let previousDay: String?
    let path: String
    let bytes: Int
}

struct PricesMeta: Encodable {
    let format: Int
    let mtgjsonVersion: String
    let firstDay: String
    let lastDay: String
    let cards: Int
    let full: PricesFile
    let days: [PricesFile]
}

// MARK: - Main

func main() async throws {
    let start = Date()
    let fm = FileManager.default

    var scryfallByUUID: [String: String] = [:]
    guard let ids = try? String(contentsOf: PricesConfig.idsFile, encoding: .utf8) else {
        fail("No Scryfall ids at \(PricesConfig.idsFile.path)")
    }
    for line in ids.split(separator: "\n") {
        let columns = line.split(separator: "\t")
        guard columns.count == 2 else { continue }
        scryfallByUUID[String(columns[0])] = String(columns[1])
    }
    print("🔗 \(scryfallByUUID.count) Scryfall ids")

    let source: URL
    if let local = PricesConfig.localPrices {
        source = local
    } else {
        print("📥 Downloading AllPrices.json.xz")
        let (download, _) = try await URLSession.shared.download(from: URL(string: "https://mtgjson.com/api/v5/AllPrices.json.xz")!)
        source = download
    }

    guard let handle = try? FileHandle(forReadingFrom: source) else { fail("Cannot read \(source.path)") }
    let filter = try InputFilter(.decompress, using: .lzma, bufferCapacity: 1 << 20) { length in
        try handle.read(upToCount: length)
    }

    var scanner = EntryScanner()
    var head: [UInt8] = []
    var cards: [String: CardPrices] = [:]
    var entries = 0
    var unmatched = 0
    while let chunk = try filter.readData(ofLength: 4 << 20), chunk.isEmpty == false {
        if head.count < 512 { head += chunk.prefix(512 - head.count) }
        chunk.withUnsafeBytes { bytes in
            scanner.feed(bytes) { uuid, entry in
                entries += 1
                guard let id = scryfallByUUID[uuid] else {
                    unmatched += 1
                    return
                }
                guard cards[id] == nil else { return }
                // Each entry's objects freed as it is read: left to the end, they peaked at 5.7 GB.
                autoreleasepool {
                    guard let object = try? JSONSerialization.jsonObject(with: Data(entry)) as? [String: Any] else { return }
                    let prices = cardPrices(object)
                    if prices.isEmpty == false { cards[id] = prices }
                }
            }
        }
    }
    guard let version = metaVersion(head) else { fail("No version in AllPrices") }
    print("💵 MTGJSON \(version): \(entries) entries, \(cards.count) cards with prices, \(unmatched) without a Scryfall id")

    let sorted = cards.map { (id: $0.key, prices: $0.value) }.sorted { $0.id < $1.id }
    let allDays = sorted.flatMap { card in card.prices.history.flatMap { $0.map(\.day) } + card.prices.latest.compactMap { $0?.day } }
    guard let firstDay = allDays.min(), let lastDay = allDays.max() else { fail("No prices") }

    let out = PricesConfig.outputDir
    let pricesDir = out.appendingPathComponent("prices", isDirectory: true)
    try? fm.removeItem(at: pricesDir)
    try fm.createDirectory(at: pricesDir, withIntermediateDirectories: true)

    let fullBytes = try gzip(encode(sorted, firstDay: firstDay, lastDay: lastDay), to: pricesDir.appendingPathComponent("history.bin.gz"))
    print("📈 History \(dayText(firstDay)) to \(dayText(lastDay)): \(fullBytes / 1024) KB")

    // The last 14 days MTGJSON has prices for, each against the one before it. A day it skipped has
    // no file: the next day's is against the day before the gap.
    let pricedDays = Set(allDays).sorted()
    var days: [PricesFile] = []
    for (previousDay, day) in zip(pricedDays, pricedDays.dropFirst()).suffix(14) {
        let (bytes, count) = encodeDay(sorted, day: day, previousDay: previousDay)
        let name = "\(dayText(day)).bin.gz"
        let size = try gzip(bytes, to: pricesDir.appendingPathComponent(name))
        days.append(PricesFile(day: dayText(day), previousDay: dayText(previousDay), path: "prices/\(name)", bytes: size))
        print("   \(dayText(day)): \(count) cards changed, \(size / 1024) KB")
    }

    let meta = PricesMeta(
        format: 1,
        mtgjsonVersion: version,
        firstDay: dayText(firstDay),
        lastDay: dayText(lastDay),
        cards: sorted.count,
        full: PricesFile(day: nil, previousDay: nil, path: "prices/history.bin.gz", bytes: fullBytes),
        days: days
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(meta).write(to: out.appendingPathComponent("prices-meta.json"))
    print("✅ Prices in \(Int(Date().timeIntervalSince(start))) s")
}

try await main()
