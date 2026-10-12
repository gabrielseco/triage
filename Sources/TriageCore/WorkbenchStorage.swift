import Foundation

public actor WorkbenchStorage {
    private let directory: URL
    public init(directory: URL) { self.directory = directory }

    public func load() throws -> WorkbenchCatalog {
        let file = directory.appendingPathComponent("catalog.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return WorkbenchCatalog() }
        return try JSONDecoder().decode(WorkbenchCatalog.self, from: Data(contentsOf: file)).recovered()
    }

    public func save(_ catalog: WorkbenchCatalog) throws {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("catalog.json")
        try JSONEncoder().encode(catalog).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    public static func raw(at directory: URL, id: UUID) throws -> String {
        let file = directory.appendingPathComponent(id.uuidString + ".jsonl")
        guard FileManager.default.fileExists(atPath: file.path) else { return "" }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: size > 256_000 ? size - 256_000 : 0)
        return String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
    }
}
