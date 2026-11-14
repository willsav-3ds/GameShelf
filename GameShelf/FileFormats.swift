import Foundation

/// Reader for the flat INI files DuckStation and PCSX2 write. Keys may repeat.
struct INIFile {
    private var values: [String: [String]] = [:]

    init?(url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var section = ""
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast())
            } else if let separator = line.firstIndex(of: "=") {
                let key = line[..<separator].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
                values["\(section)/\(key)", default: []].append(value)
            }
        }
    }

    func all(_ section: String, _ key: String) -> [String] {
        values["\(section)/\(key)"] ?? []
    }
}

struct PlaytimeEntry: Sendable {
    var seconds: TimeInterval
    var lastPlayed: Date?
}

/// DuckStation and PCSX2 share `playtime.dat`: one "SERIAL  seconds  unix-time" row per game.
enum PlaytimeFile {
    static func read(_ url: URL) -> [String: PlaytimeEntry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var entries: [String: PlaytimeEntry] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 3,
                  let seconds = TimeInterval(fields[fields.count - 2]),
                  let lastPlayed = TimeInterval(fields[fields.count - 1]) else { continue }
            let serial = fields.dropLast(2).joined(separator: " ")
            entries[serial] = PlaytimeEntry(
                seconds: seconds,
                lastPlayed: lastPlayed > 0 ? Date(timeIntervalSince1970: lastPlayed) : nil
            )
        }
        return entries
    }
}

/// Valve KeyValues text, used by Steam's appmanifest and localconfig files.
indirect enum VDF {
    case string(String)
    case object([String: VDF])

    subscript(key: String) -> VDF? {
        guard case .object(let children) = self else { return nil }
        return children[key.lowercased()]
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var children: [String: VDF] {
        if case .object(let children) = self { return children }
        return [:]
    }

    static func read(_ url: URL) -> VDF? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var parser = Parser(bytes: Array(data))
        return .object(parser.parseObject())
    }

    private struct Parser {
        let bytes: [UInt8]
        var position = 0

        mutating func parseObject() -> [String: VDF] {
            var result: [String: VDF] = [:]
            while let token = nextToken() {
                guard case .text(let key) = token else {
                    if case .close = token { break }
                    continue
                }
                guard let value = nextToken() else { break }
                switch value {
                case .text(let text): result[key.lowercased()] = .string(text)
                case .open: result[key.lowercased()] = .object(parseObject())
                case .close: return result
                }
            }
            return result
        }

        private enum Token {
            case text(String), open, close
        }

        private mutating func nextToken() -> Token? {
            while position < bytes.count {
                let byte = bytes[position]
                switch byte {
                case UInt8(ascii: "{"):
                    position += 1
                    return .open
                case UInt8(ascii: "}"):
                    position += 1
                    return .close
                case UInt8(ascii: "\""):
                    position += 1
                    return .text(readQuoted())
                case UInt8(ascii: "/") where position + 1 < bytes.count && bytes[position + 1] == byte:
                    while position < bytes.count && bytes[position] != UInt8(ascii: "\n") { position += 1 }
                default:
                    position += 1
                }
            }
            return nil
        }

        private mutating func readQuoted() -> String {
            var output: [UInt8] = []
            while position < bytes.count {
                let byte = bytes[position]
                position += 1
                if byte == UInt8(ascii: "\"") { break }
                if byte == UInt8(ascii: "\\"), position < bytes.count {
                    output.append(bytes[position])
                    position += 1
                } else {
                    output.append(byte)
                }
            }
            return String(decoding: output, as: UTF8.self)
        }
    }
}

/// Finds a disc's serial (the key playtime is stored under) by reading SYSTEM.CNF from
/// the ISO9660 filesystem. Compressed formats such as CHD return nil.
enum DiscSerial {
    static func read(_ url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "cue": return readCue(url)
        case "iso": return readImage(url, sectorSize: 2048, dataOffset: 0)
        case "bin", "img": return readImage(url, sectorSize: 2352, dataOffset: 24)
        default: return nil
        }
    }

    static func cueTracks(_ cue: URL) -> [URL] {
        guard let text = readCueText(cue) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let match = line.firstMatch(of: /^\s*FILE\s+"(.+)"/.ignoresCase()) else { return nil }
            return cue.deletingLastPathComponent().appendingPathComponent(String(match.1))
        }
    }

    /// Older .cue files aren't always UTF-8.
    private static func readCueText(_ cue: URL) -> String? {
        (try? String(contentsOf: cue, encoding: .utf8)) ?? (try? String(contentsOf: cue, encoding: .isoLatin1))
    }

    private static func readCue(_ cue: URL) -> String? {
        guard let track = cueTracks(cue).first, let text = readCueText(cue) else { return nil }
        let mode = text.firstMatch(of: /TRACK\s+[0-9]+\s+(MODE[12])\/([0-9]+)/.ignoresCase())
        switch (mode?.1.uppercased(), mode?.2) {
        case ("MODE1", "2048"), ("MODE2", "2048"): return readImage(track, sectorSize: 2048, dataOffset: 0)
        case ("MODE1", _): return readImage(track, sectorSize: 2352, dataOffset: 16)
        default: return readImage(track, sectorSize: 2352, dataOffset: 24)
        }
    }

    private static func readImage(_ url: URL, sectorSize: UInt64, dataOffset: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        func read(lba: UInt64, length: Int) -> [UInt8]? {
            var output: [UInt8] = []
            var sector = lba
            while output.count < length {
                guard (try? handle.seek(toOffset: sector * sectorSize + dataOffset)) != nil,
                      let chunk = try? handle.read(upToCount: 2048), !chunk.isEmpty else { return nil }
                output.append(contentsOf: chunk)
                sector += 1
            }
            return Array(output.prefix(length))
        }
        func littleEndian32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << UInt32($1 * 8) }
        }

        guard let volume = read(lba: 16, length: 2048),
              volume[1...5].elementsEqual("CD001".utf8) else { return nil }
        let rootLBA = UInt64(littleEndian32(volume, 156 + 2))
        let rootSize = min(Int(littleEndian32(volume, 156 + 10)), 1 << 20)
        guard let root = read(lba: rootLBA, length: rootSize) else { return nil }

        var offset = 0
        while offset + 33 < root.count {
            let recordLength = Int(root[offset])
            if recordLength == 0 {
                // Records never straddle a logical sector; skip to the next one.
                offset = (offset / 2048 + 1) * 2048
                continue
            }
            let nameLength = Int(root[offset + 32])
            guard offset + 33 + nameLength <= root.count else { break }
            let name = String(decoding: root[(offset + 33)..<(offset + 33 + nameLength)], as: UTF8.self)
            if name.uppercased().hasPrefix("SYSTEM.CNF") {
                let lba = UInt64(littleEndian32(root, offset + 2))
                let size = min(Int(littleEndian32(root, offset + 10)), 4096)
                guard let config = read(lba: lba, length: size) else { return nil }
                return parseBootLine(String(decoding: config, as: UTF8.self))
            }
            offset += recordLength
        }
        return nil
    }

    /// "BOOT2 = cdrom0:\SLUS_206.22;1" returns "SLUS-20622".
    static func parseBootLine(_ config: String) -> String? {
        guard let match = config.firstMatch(of: /BOOT2?\s*=\s*cdrom[0-9]?:\\*([A-Za-z]{4})[_-]([0-9]{3})\.?([0-9]{2})/.ignoresCase()) else {
            return nil
        }
        return "\(match.1.uppercased())-\(match.2)\(match.3)"
    }
}
