import Foundation

public struct MailConfiguration: Codable, Sendable {
    public var username: String
    public var password: String
    public var imapPort: Int
    public var smtpPort: Int
    public var directTLS: Bool
    public var certificatePEM: String
    public init(username: String = "", password: String = "", imapPort: Int = 1143, smtpPort: Int = 1025, directTLS: Bool = false, certificatePEM: String = "") {
        self.username = username; self.password = password; self.imapPort = imapPort; self.smtpPort = smtpPort; self.directTLS = directTLS; self.certificatePEM = certificatePEM
    }
    public func validate() throws {
        guard MailDraft.validAddress(username), !password.isEmpty else { throw ProtonXError.invalidInput("Enter the email address and password shown in Proton Bridge.") }
        guard (1024...65535).contains(imapPort), (1024...65535).contains(smtpPort) else { throw ProtonXError.invalidInput("Bridge ports must be between 1024 and 65535.") }
        guard certificatePEM.contains("-----BEGIN CERTIFICATE-----"), certificatePEM.utf8.count < 65536 else { throw ProtonXError.invalidInput("Import the public TLS certificate exported by Proton Bridge.") }
    }
    public func url(smtp: Bool = false, mailbox: String? = nil, uid: UInt64? = nil, headerOnly: Bool = false) throws -> String {
        try validate()
        let scheme = smtp ? (directTLS ? "smtps" : "smtp") : (directTLS ? "imaps" : "imap")
        var url = "\(scheme)://127.0.0.1:\(smtp ? smtpPort : imapPort)/"
        if let mailbox {
            guard !mailbox.isEmpty, mailbox.utf8.count < 512, !mailbox.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw ProtonXError.invalidInput("Unsupported mailbox name.") }
            var allowed = CharacterSet.urlPathAllowed; allowed.remove(charactersIn: "/;?%#")
            guard let encoded = mailbox.addingPercentEncoding(withAllowedCharacters: allowed) else { throw ProtonXError.invalidInput("Unsupported mailbox name.") }
            url += encoded
        }
        if let uid { guard uid > 0 else { throw ProtonXError.invalidResponse }; url += "/;UID=\(uid)"; if headerOnly { url += "/;SECTION=HEADER" } }
        return url
    }
}

public struct MailMessage: Identifiable, Sendable {
    public let uid: UInt64
    public let subject: String
    public let sender: String
    public let recipient: String
    public let date: String
    public let body: String
    public let attachmentCount: Int
    public let htmlOnly: Bool
    public var id: UInt64 { uid }
    public init(uid: UInt64, subject: String, sender: String, recipient: String, date: String, body: String, attachmentCount: Int = 0, htmlOnly: Bool = false) {
        self.uid = uid; self.subject = subject; self.sender = sender; self.recipient = recipient; self.date = date; self.body = body; self.attachmentCount = attachmentCount; self.htmlOnly = htmlOnly
    }
}

public struct MailDraft: Sendable {
    public var to: String = ""
    public var subject: String = ""
    public var body: String = ""
    public init() {}
    public static func validAddress(_ value: String) -> Bool {
        guard value.utf8.count < 255, !value.contains(where: { $0.isWhitespace }), !value.contains(where: { "\r\n<>\"(),;:".contains($0) }) else { return false }
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !parts[1].hasPrefix(".") && !parts[1].hasSuffix(".")
    }
    public func encoded(from sender: String) throws -> Data {
        guard Self.validAddress(to), Self.validAddress(sender), !subject.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw ProtonXError.invalidInput("Use one valid recipient address and a subject without line breaks.") }
        guard body.utf8.count < 1024 * 1024, subject.utf8.count < 998 else { throw ProtonXError.invalidInput("This version supports messages below 1 MB.") }
        let subjectData = Data(subject.utf8).base64EncodedString()
        let encodedBody = Data(body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n").utf8).base64EncodedString()
        let lines = stride(from: 0, to: encodedBody.count, by: 76).map { index in
            let begin = encodedBody.index(encodedBody.startIndex, offsetBy: index)
            let end = encodedBody.index(begin, offsetBy: min(76, encodedBody.count - index))
            return String(encodedBody[begin..<end])
        }.joined(separator: "\r\n")
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let raw = "From: \(sender)\r\nTo: \(to)\r\nSubject: =?UTF-8?B?\(subjectData)?=\r\nDate: \(formatter.string(from: Date()))\r\nMessage-ID: <\(UUID().uuidString)@protonx.local>\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n\(lines)\r\n"
        return Data(raw.utf8)
    }
}

/// Bounded, plain-text MIME reader. HTML is never executed and remote images are never fetched.
public enum MailParser {
    public static func uids(_ data: Data) throws -> [UInt64] {
        guard let text = String(data: data, encoding: .utf8) else { throw ProtonXError.invalidResponse }
        var ids: [UInt64] = []
        for line in text.components(separatedBy: .newlines) where line.hasPrefix("* SEARCH") {
            ids += line.dropFirst(8).split(separator: " ").compactMap { UInt64($0) }
        }
        return Array(Set(ids.filter { $0 > 0 })).sorted()
    }
    public static func mailboxes(_ data: Data) throws -> [String] {
        guard let text = String(data: data, encoding: .utf8) else { throw ProtonXError.invalidResponse }
        let regex = try NSRegularExpression(pattern: #"^\* LIST \([^\r\n]*\) (?:NIL|"(?:[^"\\]|\\.)*") ("(?:[^"\\]|\\.)*"|[^\r\n]+)$"#, options: .anchorsMatchLines)
        let names = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            var value = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\"") && value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\") }
            return value
        }
        return Array(Set(names)).sorted { a, b in a == "INBOX" || (b != "INBOX" && a.localizedStandardCompare(b) == .orderedAscending) }
    }
    public static func message(_ data: Data, uid: UInt64) throws -> MailMessage {
        guard data.count <= 16 * 1024 * 1024 else { throw ProtonXError.outputTooLarge }
        let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let (headers, body) = split(raw)
        let result = part(headers: headers, body: body, depth: 0)
        return MailMessage(uid: uid, subject: decodedHeader(headers["subject"] ?? "(No subject)"),
                           sender: decodedHeader(headers["from"] ?? ""), recipient: decodedHeader(headers["to"] ?? ""),
                           date: headers["date"] ?? "", body: result.text ?? (result.html ? "This message contains HTML only. Open it in the official client to view its formatting." : "No supported text body."),
                           attachmentCount: result.attachments, htmlOnly: result.html && result.text == nil)
    }
    private static func split(_ raw: String) -> ([String: String], String) {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let separator = normalized.range(of: "\n\n")
        let head = separator.map { String(normalized[..<$0.lowerBound]) } ?? normalized
        let body = separator.map { String(normalized[$0.upperBound...]) } ?? ""
        var headers: [String: String] = [:], key: String?
        for line in head.components(separatedBy: "\n") {
            if (line.hasPrefix(" ") || line.hasPrefix("\t")), let key { headers[key, default: ""] += " " + line.trimmingCharacters(in: .whitespaces) }
            else if let colon = line.firstIndex(of: ":") {
                let name = line[..<colon].lowercased(); headers[name] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces); key = name
            }
        }
        return (headers, body)
    }
    private struct Part { var text: String?; var attachments: Int = 0; var html = false }
    private static func part(headers: [String: String], body: String, depth: Int) -> Part {
        guard depth < 12 else { return Part(text: nil) }
        let type = headers["content-type"] ?? "text/plain"
        if (headers["content-disposition"] ?? "").lowercased().hasPrefix("attachment") { return Part(text: nil, attachments: 1) }
        if type.lowercased().hasPrefix("multipart/"), let boundary = parameter("boundary", in: type), !boundary.isEmpty {
            var result = Part(text: nil)
            for chunk in body.components(separatedBy: "--" + boundary).dropFirst() {
                if chunk.hasPrefix("--") { break }
                let (subheaders, content) = split(chunk.trimmingCharacters(in: .newlines))
                let next = part(headers: subheaders, body: content, depth: depth + 1)
                if let text = next.text { result.text = [result.text, text].compactMap { $0 }.joined(separator: "\n\n") }
                result.attachments += next.attachments; result.html = result.html || next.html
            }
            return result
        }
        guard type.lowercased().hasPrefix("text/plain") else { return Part(text: nil, attachments: type.lowercased().hasPrefix("text/html") ? 0 : 1, html: type.lowercased().hasPrefix("text/html")) }
        let encoding = (headers["content-transfer-encoding"] ?? "").lowercased()
        let bytes: Data
        if encoding == "base64" { bytes = Data(base64Encoded: body, options: .ignoreUnknownCharacters) ?? Data() }
        else if encoding == "quoted-printable" { bytes = quotedPrintable(body) }
        else { bytes = Data(body.utf8) }
        let charset = parameter("charset", in: type)?.lowercased()
        let text = String(data: bytes, encoding: charset == "iso-8859-1" || charset == "windows-1252" ? .isoLatin1 : .utf8)
        return Part(text: text ?? "Unsupported text encoding.")
    }
    private static func parameter(_ name: String, in value: String) -> String? {
        let pattern = "(?i)(?:^|;)\\s*" + name + #"\s*=\s*(?:"([^"]*)"|([^;\s]*))"#
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        for i in 1...2 { if let range = Range(match.range(at: i), in: value) { return String(value[range]) } }; return nil
    }
    private static func quotedPrintable(_ text: String) -> Data {
        let bytes = Array(text.replacingOccurrences(of: "=\r\n", with: "").replacingOccurrences(of: "=\n", with: "").utf8)
        var result = Data(), i = 0
        while i < bytes.count {
            if bytes[i] == 61, i + 2 < bytes.count,
               let value = UInt8(String(bytes: bytes[(i+1)...(i+2)], encoding: .ascii) ?? "", radix: 16) { result.append(value); i += 3 }
            else { result.append(bytes[i]); i += 1 }
        }
        return result
    }
    private static func decodedHeader(_ value: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#) else { return value }
        var result = value
        for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
            guard let all = Range(match.range, in: result), let enc = Range(match.range(at: 2), in: value), let raw = Range(match.range(at: 3), in: value), let charsetRange = Range(match.range(at: 1), in: value) else { continue }
            let charset = value[charsetRange].lowercased()
            let data = value[enc].lowercased() == "b" ? Data(base64Encoded: String(value[raw])) : quotedPrintable(String(value[raw]).replacingOccurrences(of: "_", with: " "))
            if let data, let text = String(data: data, encoding: charset == "iso-8859-1" ? .isoLatin1 : .utf8) { result.replaceSubrange(all, with: text) }
        }
        return result
    }
}
