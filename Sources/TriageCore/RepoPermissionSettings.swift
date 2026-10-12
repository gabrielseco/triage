import Foundation

/// Adds allow rules to a repository's `.claude/settings.local.json` so the plain CLI honours them too.
///
/// The file is the user's: everything already in it is kept, in the order it had. A file that isn't a
/// JSON object with the expected shape is left untouched and reported.
public enum RepoPermissionSettings {
    public static func add(rules: [String], toProjectAt path: String) throws {
        let directory = URL(fileURLWithPath: path).appendingPathComponent(".claude")
        let file = directory.appendingPathComponent("settings.local.json")
        var root = OrderedJSON.object([])
        if FileManager.default.fileExists(atPath: file.path) {
            let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                try write(merged(rules, into: root), to: file, directory: directory)
                return
            }
            guard let parsed = OrderedJSON.parse(text), case .object = parsed else {
                throw WorkbenchError("\(file.path) is not a JSON object, so it was left unchanged.")
            }
            root = parsed
        }
        let updated = try merged(rules, into: root)
        if updated != root || !FileManager.default.fileExists(atPath: file.path) {
            try write(updated, to: file, directory: directory)
        }
    }

    private static func merged(_ rules: [String], into root: OrderedJSON) throws -> OrderedJSON {
        guard case .object(var members) = root else { return root }
        var permissions: [OrderedJSON.Member] = []
        if let index = members.firstIndex(where: { $0.key == "permissions" }) {
            guard case .object(let existing) = members[index].value else {
                throw WorkbenchError("\"permissions\" in settings.local.json is not an object; left unchanged.")
            }
            permissions = existing
        }
        var allow: [OrderedJSON] = []
        if let index = permissions.firstIndex(where: { $0.key == "allow" }) {
            guard case .array(let existing) = permissions[index].value else {
                throw WorkbenchError("\"permissions.allow\" in settings.local.json is not a list; left unchanged.")
            }
            allow = existing
        }
        for rule in rules where !allow.contains(.string(rule)) { allow.append(.string(rule)) }
        permissions = replacing("allow", with: .array(allow), in: permissions)
        members = replacing("permissions", with: .object(permissions), in: members)
        return .object(members)
    }

    private typealias Members = [OrderedJSON.Member]

    private static func replacing(_ key: String, with value: OrderedJSON, in members: Members) -> Members {
        var copy = members
        if let index = copy.firstIndex(where: { $0.key == key }) {
            copy[index] = .init(key: key, value: value)
        } else {
            copy.append(.init(key: key, value: value))
        }
        return copy
    }

    private static func write(_ value: OrderedJSON, to file: URL, directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data((value.serialized() + "\n").utf8).write(to: file, options: .atomic)
    }
}

/// JSON that keeps object member order and number spelling, for files a person also edits.
indirect enum OrderedJSON: Equatable {
    struct Member: Equatable {
        let key: String
        let value: OrderedJSON
    }
    case object([Member]), array([OrderedJSON]), string(String), number(String), bool(Bool), null

    static func parse(_ text: String) -> OrderedJSON? {
        var parser = Parser(characters: Array(text.unicodeScalars))
        guard let value = parser.value() else { return nil }
        parser.skipWhitespace()
        return parser.index == parser.characters.count ? value : nil
    }

    func serialized(indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent + 1)
        let closing = String(repeating: "  ", count: indent)
        switch self {
        case .object(let members):
            if members.isEmpty { return "{}" }
            let lines = members.map { "\(pad)\(Self.quote($0.key)): \($0.value.serialized(indent: indent + 1))" }
            return "{\n" + lines.joined(separator: ",\n") + "\n\(closing)}"
        case .array(let values):
            if values.isEmpty { return "[]" }
            let lines = values.map { pad + $0.serialized(indent: indent + 1) }
            return "[\n" + lines.joined(separator: ",\n") + "\n\(closing)]"
        case .string(let value): return Self.quote(value)
        case .number(let value): return value
        case .bool(let value): return value ? "true" : "false"
        case .null: return "null"
        }
    }

    private static func quote(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }

    private struct Parser {
        let characters: [Unicode.Scalar]
        var index = 0

        mutating func skipWhitespace() {
            while index < characters.count, " \t\n\r".unicodeScalars.contains(characters[index]) { index += 1 }
        }

        mutating func value() -> OrderedJSON? {
            skipWhitespace()
            guard index < characters.count else { return nil }
            switch characters[index] {
            case "{": return object()
            case "[": return array()
            case "\"": return string().map(OrderedJSON.string)
            case "t": return literal("true", .bool(true))
            case "f": return literal("false", .bool(false))
            case "n": return literal("null", .null)
            default: return number()
            }
        }

        private mutating func literal(_ word: String, _ value: OrderedJSON) -> OrderedJSON? {
            let scalars = Array(word.unicodeScalars)
            guard index + scalars.count <= characters.count,
                Array(characters[index..<index + scalars.count]) == scalars
            else { return nil }
            index += scalars.count
            return value
        }

        private mutating func number() -> OrderedJSON? {
            let start = index
            while index < characters.count, "+-0123456789.eE".unicodeScalars.contains(characters[index]) {
                index += 1
            }
            guard index > start else { return nil }
            let text = String(String.UnicodeScalarView(characters[start..<index]))
            return Double(text) == nil ? nil : .number(text)
        }

        private mutating func string() -> String? {
            guard characters[index] == "\"" else { return nil }
            index += 1
            var result = String.UnicodeScalarView()
            while index < characters.count {
                let scalar = characters[index]
                index += 1
                switch scalar {
                case "\"": return String(result)
                case "\\":
                    guard index < characters.count, let unescaped = escape() else { return nil }
                    result.append(contentsOf: unescaped)
                default:
                    guard scalar.value >= 0x20 else { return nil }
                    result.append(scalar)
                }
            }
            return nil
        }

        private mutating func escape() -> [Unicode.Scalar]? {
            let kind = characters[index]
            index += 1
            let simple: [Unicode.Scalar: Unicode.Scalar] = [
                "\"": "\"", "\\": "\\", "/": "/", "b": "\u{8}", "f": "\u{c}", "n": "\n", "r": "\r", "t": "\t",
            ]
            if let scalar = simple[kind] { return [scalar] }
            return kind == "u" ? unicodeEscape() : nil
        }

        private mutating func unicodeEscape() -> [Unicode.Scalar]? {
            guard let first = hex4() else { return nil }
            guard (0xD800..<0xDC00).contains(first) else { return Unicode.Scalar(first).map { [$0] } }
            guard index + 1 < characters.count, characters[index] == "\\", characters[index + 1] == "u" else {
                return nil
            }
            index += 2
            guard let second = hex4(), (0xDC00..<0xE000).contains(second),
                let scalar = Unicode.Scalar(0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00))
            else { return nil }
            return [scalar]
        }

        private mutating func hex4() -> UInt32? {
            guard index + 4 <= characters.count else { return nil }
            let text = String(String.UnicodeScalarView(characters[index..<index + 4]))
            index += 4
            return UInt32(text, radix: 16)
        }

        private mutating func array() -> OrderedJSON? {
            index += 1
            var values: [OrderedJSON] = []
            skipWhitespace()
            if index < characters.count, characters[index] == "]" {
                index += 1
                return .array([])
            }
            while true {
                guard let element = value() else { return nil }
                values.append(element)
                skipWhitespace()
                guard index < characters.count else { return nil }
                let next = characters[index]
                index += 1
                if next == "]" { return .array(values) }
                if next != "," { return nil }
            }
        }

        private mutating func object() -> OrderedJSON? {
            index += 1
            var members: [Member] = []
            skipWhitespace()
            if index < characters.count, characters[index] == "}" {
                index += 1
                return .object([])
            }
            while true {
                skipWhitespace()
                guard index < characters.count, let key = string() else { return nil }
                skipWhitespace()
                guard index < characters.count, characters[index] == ":" else { return nil }
                index += 1
                guard let element = value() else { return nil }
                members.append(.init(key: key, value: element))
                skipWhitespace()
                guard index < characters.count else { return nil }
                let next = characters[index]
                index += 1
                if next == "}" { return .object(members) }
                if next != "," { return nil }
            }
        }
    }
}
