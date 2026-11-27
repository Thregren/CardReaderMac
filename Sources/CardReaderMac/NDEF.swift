import Foundation

extension Array where Element == UInt8 {
    var hex: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}

struct NDEFRecord: Identifiable {
    let id: Int
    let type: String
    let value: String
}

enum NDEF {
    private static let uriPrefixes = [
        "", "http://www.", "https://www.", "http://", "https://", "tel:", "mailto:", "ftp://anonymous:anonymous@",
        "ftp://ftp.", "ftps://", "sftp://", "smb://", "nfs://", "ftp://", "dav://", "news:", "telnet://", "imap:",
        "rtsp://", "urn:", "pop:", "sip:", "sips:", "tftp:", "btspp://", "btl2cap://", "btgoep://", "tcpobex://",
        "irdaobex://", "file://", "urn:epc:id:", "urn:epc:tag:", "urn:epc:pat:", "urn:epc:raw:", "urn:epc:", "urn:nfc:"
    ]

    static func parseHex(_ input: String) throws -> [UInt8] {
        let digits = input.utf8.filter { ![9, 10, 13, 32].contains($0) }
        guard !digits.isEmpty, digits.count <= 131_072, digits.count.isMultiple(of: 2) else {
            throw ReaderError(detail: "请输入完整的十六进制字节（最多 64 KiB）。")
        }
        return try stride(from: 0, to: digits.count, by: 2).map { offset in
            let pair = digits[offset..<(offset + 2)]
            guard pair.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                  let byte = UInt8(String(decoding: pair, as: UTF8.self), radix: 16) else {
                throw ReaderError(detail: "十六进制内容只能包含 0–9、A–F 和空白。")
            }
            return byte
        }
    }

    static func decode(_ bytes: [UInt8]) throws -> [NDEFRecord] {
        if bytes.isEmpty { return [] }
        var reader = ByteReader(bytes: bytes)
        var records: [NDEFRecord] = []
        while !reader.atEnd {
            let header = try reader.byte()
            let first = header & 0x80 != 0
            let last = header & 0x40 != 0
            let chunk = header & 0x20 != 0
            let short = header & 0x10 != 0
            let hasID = header & 0x08 != 0
            let tnf = header & 0x07
            guard first == records.isEmpty, !chunk, tnf < 6 else {
                throw ReaderError(detail: "NDEF 记录头无效，或消息使用了分块记录。")
            }
            let typeLength = Int(try reader.byte())
            let payloadLength = try reader.integer(short ? 1 : 4)
            let idLength = hasID ? Int(try reader.byte()) : 0
            let type = try reader.take(typeLength)
            _ = try reader.take(idLength)
            let payload = try Array(reader.take(payloadLength))
            guard tnf != 0 || (typeLength == 0 && idLength == 0 && payloadLength == 0 && !hasID),
                  tnf != 5 || typeLength == 0,
                  last == reader.atEnd else { throw ReaderError(detail: "NDEF 记录长度或结束标记无效。") }
            let (label, value) = try describe(tnf: tnf, type: Array(type), payload: payload)
            records.append(NDEFRecord(id: records.count, type: label, value: value))
        }
        return records
    }

    static func unwrapType2(_ bytes: [UInt8]) throws -> [UInt8]? {
        var reader = ByteReader(bytes: bytes)
        while !reader.atEnd {
            switch try reader.byte() {
            case 0x00: continue
            case 0xFE: return nil
            case 0x03:
                let length = Int(try reader.byte())
                return try Array(reader.take(length == 255 ? reader.integer(2) : length))
            default:
                let length = Int(try reader.byte())
                _ = try reader.take(length == 255 ? reader.integer(2) : length)
            }
        }
        return nil
    }

    static func encode(_ content: String, uri: Bool) throws -> [UInt8] {
        guard !content.isEmpty, content.utf8.count <= 65_520 else {
            throw ReaderError(detail: "请输入内容，且 UTF-8 编码长度需小于 64 KiB。")
        }
        let type: UInt8
        let payload: [UInt8]
        if uri {
            guard let url = URLComponents(string: content), let scheme = url.scheme,
                  !scheme.isEmpty, !content.contains(where: \.isWhitespace) else {
                throw ReaderError(detail: "请输入完整 URI，例如 https://example.com。")
            }
            let prefix = uriPrefixes.indices.filter { content.hasPrefix(uriPrefixes[$0]) }.max {
                uriPrefixes[$0].count < uriPrefixes[$1].count
            } ?? 0
            type = 0x55
            payload = [UInt8(prefix)] + Array(content.dropFirst(uriPrefixes[prefix].count).utf8)
        } else {
            type = 0x54
            payload = [2, 0x7A, 0x68] + Array(content.utf8)
        }
        let length = payload.count
        let lengths: [UInt8] = length <= 255
            ? [0xD1, 1, UInt8(length)]
            : [0xC1, 1, 0, 0, UInt8(length >> 8), UInt8(length & 255)]
        return lengths + [type] + payload
    }

    private static func describe(tnf: UInt8, type: [UInt8], payload: [UInt8]) throws -> (String, String) {
        if tnf == 0 { return ("空记录", "") }
        if tnf == 1, type == [0x54] {
            guard let status = payload.first, status & 0x40 == 0 else {
                throw ReaderError(detail: "NDEF 文本的状态字节无效。")
            }
            let length = Int(status & 0x3F)
            guard payload.count >= length + 1,
                  let language = String(bytes: payload.dropFirst().prefix(length), encoding: .ascii),
                  let value = String(bytes: payload.dropFirst(length + 1), encoding: status & 0x80 == 0 ? .utf8 : .utf16) else {
                throw ReaderError(detail: "无法解码 NDEF 文本。")
            }
            return (language.isEmpty ? "文本" : "文本（\(language)）", value)
        }
        if tnf == 1, type == [0x55] {
            guard let prefix = payload.first, Int(prefix) < uriPrefixes.count,
                  let value = String(bytes: payload.dropFirst(), encoding: .utf8) else {
                throw ReaderError(detail: "无法解码 NDEF URI。")
            }
            return ("URI", uriPrefixes[Int(prefix)] + value)
        }
        let name = String(bytes: type, encoding: .ascii) ?? type.hex
        return (name.isEmpty ? "TNF \(tnf)" : name, payload.hex)
    }
}

private struct ByteReader {
    let bytes: [UInt8]
    var position = 0
    var atEnd: Bool { position == bytes.count }

    mutating func take(_ length: Int) throws -> ArraySlice<UInt8> {
        guard length <= bytes.count - position else { throw ReaderError(detail: "数据提前结束。") }
        defer { position += length }
        return bytes[position..<(position + length)]
    }

    mutating func byte() throws -> UInt8 {
        let index = position
        return try take(1)[index]
    }

    mutating func integer(_ length: Int) throws -> Int {
        try take(length).reduce(0) { ($0 << 8) | Int($1) }
    }
}
