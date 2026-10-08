// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public struct NativeMailAttachment: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable { case available, uploaded, uploading, pending, offline, failed }
    public let id: UInt64
    public let name: String
    public let size: UInt64
    public let mime: String
    public let state: State
    public init(id: UInt64, name: String, size: UInt64, mime: String = "application/octet-stream", state: State = .available) {
        self.id = id; self.name = name; self.size = size; self.mime = mime; self.state = state
    }
    public func validate() throws {
        guard id > 0, id != UInt64.max, name == MailAttachmentPolicy.filename(name), name.utf8.count <= 240,
              mime.utf8.count <= 255, !mime.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw ProtonXError.invalidResponse }
    }
    public var ready: Bool { state == .available || state == .uploaded }
}
public struct NativeMailTransfer: Codable, Sendable {
    public let token: UInt64
    public let size: Int
    public let offset: Int
    public let data: String?
    public let done: Bool?
    public init(token: UInt64, size: Int, offset: Int, data: String? = nil, done: Bool? = nil) { self.token = token; self.size = size; self.offset = offset; self.data = data; self.done = done }
    public func validate() throws {
        guard token > 0, (0...MailAttachmentPolicy.maxBytes).contains(size), (0...size).contains(offset),
              data == nil || MailAttachmentPolicy.decode(data!) != nil else { throw ProtonXError.invalidResponse }
    }
}
public enum MailAttachmentPolicy {
    public static let maxBytes = 25_000_000
    public static let chunkBytes = 24 * 1024
    public static func filename(_ value: String) -> String {
        let filtered = String(value.unicodeScalars.filter { scalar in
            scalar.properties.generalCategory != .control && !"/\\:".unicodeScalars.contains(scalar)
                && !(0x202a...0x202e).contains(scalar.value) && !(0x2066...0x2069).contains(scalar.value)
        }.prefix(200)).trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !filtered.isEmpty else { return "attachment" }
        var result = ""
        for scalar in filtered.unicodeScalars { guard result.utf8.count + scalar.utf8.count <= 240 else { break }; result.unicodeScalars.append(scalar) }
        return result
    }
    public static func encode(_ data: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var result = [UInt8](); result.reserveCapacity(data.count * 2)
        for byte in data { result.append(digits[Int(byte >> 4)]); result.append(digits[Int(byte & 15)]) }
        return String(decoding: result, as: UTF8.self)
    }
    public static func decode(_ string: String) -> Data? {
        guard string.utf8.count <= chunkBytes * 2, string.utf8.count.isMultiple(of: 2) else { return nil }
        let values = Array(string.utf8); var result = Data(); result.reserveCapacity(values.count / 2)
        func digit(_ b: UInt8) -> UInt8? { if (48...57).contains(b) { return b - 48 }; if (97...102).contains(b) { return b - 87 }; return nil }
        for i in stride(from: 0, to: values.count, by: 2) { guard let a = digit(values[i]), let b = digit(values[i+1]) else { return nil }; result.append(a * 16 + b) }
        return result
    }
    public static func validateList(_ attachments: [NativeMailAttachment]) throws {
        guard attachments.count <= 256, Set(attachments.map(\.id)).count == attachments.count else { throw ProtonXError.invalidResponse }
        try attachments.forEach { try $0.validate() }
    }
}
