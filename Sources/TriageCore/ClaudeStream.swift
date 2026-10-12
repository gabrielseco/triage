import Foundation

public indirect enum StreamJSON: Codable, Equatable, Sendable {
    case object([String: StreamJSON]), array([StreamJSON]), string(String), number(Double), bool(Bool), null

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() {
            self = .null
        } else if let bool = try? value.decode(Bool.self) {
            self = .bool(bool)
        } else if let string = try? value.decode(String.self) {
            self = .string(string)
        } else if let object = try? value.decode([String: Self].self) {
            self = .object(object)
        } else if let array = try? value.decode([Self].self) {
            self = .array(array)
        } else {
            self = .number(try value.decode(Double.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let object): try value.encode(object)
        case .array(let array): try value.encode(array)
        case .string(let string): try value.encode(string)
        case .number(let number): try value.encode(number)
        case .bool(let bool): try value.encode(bool)
        case .null: try value.encodeNil()
        }
    }

    public subscript(_ key: String) -> Self { if case .object(let value) = self { value[key] ?? .null } else { .null } }
    public var text: String? { if case .string(let value) = self { value } else { nil } }
    public var values: [Self] { if case .array(let value) = self { value } else { [] } }
    public var flag: Bool { if case .bool(let value) = self { value } else { false } }
    public var formatted: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

public struct WorkbenchPermission: Equatable, Identifiable, Sendable {
    public let id: String
    public let tool: String
    public let input: StreamJSON
    public let description: String
}

public enum ClaudeStream {
    public static func user(_ prompt: String) throws -> Data {
        try encode(
            .object([
                "type": .string("user"), "message": .object(["role": .string("user"), "content": .string(prompt)]),
                "session_id": .string("default"), "parent_tool_use_id": .null,
            ]))
    }

    public static func control(_ subtype: String, id: String) throws -> Data {
        var request: [String: StreamJSON] = ["subtype": .string(subtype)]
        if subtype == "initialize" { request["hooks"] = .null }
        return try encode(
            .object([
                "type": .string("control_request"), "request_id": .string(id),
                "request": .object(request),
            ]))
    }

    public static func answer(_ permission: WorkbenchPermission, allow: Bool) throws -> Data {
        let decision: StreamJSON =
            allow
            ? .object(["behavior": .string("allow"), "updatedInput": permission.input])
            : .object(["behavior": .string("deny"), "message": .string("Denied by user")])
        return try encode(
            .object([
                "type": .string("control_response"),
                "response": .object([
                    "subtype": .string("success"), "request_id": .string(permission.id), "response": decision,
                ]),
            ]))
    }

    public static func unsupported(id: String) throws -> Data {
        try encode(
            .object([
                "type": .string("control_response"),
                "response": .object([
                    "subtype": .string("error"), "request_id": .string(id),
                    "error": .string("Unsupported control request"),
                ]),
            ]))
    }

    private static func encode(_ value: StreamJSON) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(10)
        return data
    }
}

public struct JSONLineBuffer: Sendable {
    private var data = Data()
    public init() {}

    public mutating func append(_ chunk: Data) throws -> [Data] {
        data.append(chunk)
        guard data.count <= 8 * 1024 * 1024 else { throw WorkbenchError("CLI output exceeded the frame limit.") }
        var lines: [Data] = []
        while let end = data.firstIndex(of: 10) {
            let line = Data(data[..<end])
            data.removeSubrange(...end)
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }

    public func finish() throws {
        guard data.isEmpty else { throw WorkbenchError("CLI ended with an incomplete output frame.") }
    }
}
