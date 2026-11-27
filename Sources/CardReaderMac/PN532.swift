import Foundation

struct NFCATag {
    let target: UInt8
    let uid: [UInt8]
    let atqa: [UInt8]
    let sak: UInt8
}

struct NTAGData {
    let model: String
    let header: [UInt8]
    let memory: [UInt8]

    var message: [UInt8]? { get throws { try NDEF.unwrapType2(memory) } }

    var emptyMessageOffset: Int? {
        guard model == "NTAG213", header[10...15] == [0, 0, 0xE1, 0x10, 0x12, 0] else { return nil }
        if memory.starts(with: [0x01, 0x03, 0xA0, 0x0C, 0x34, 0x03, 0, 0xFE]) { return 5 }
        if memory.starts(with: [0x03, 0, 0xFE]) { return 0 }
        return nil
    }
}

final class PN532 {
    private let serial: SerialPort
    private var scanned = false
    static let ack: [UInt8] = [0, 0, 0xFF, 0, 0xFF, 0]
    static let baudRates = [115200, 57600, 230400, 460800, 921600]

    init(port: ReaderPort, baud: Int) throws {
        serial = try SerialPort(path: port.id, baud: baud)
    }

    deinit {
        if scanned { _ = try? exchange(0x32, [0x01, 0x00], timeout: 0.25) }
    }

    func identify() throws -> String {
        try wake()
        let bytes: [UInt8]
        do {
            bytes = try exchange(0x02)
        } catch {
            // The PN532 in LowVbat mode first requires SAM normal mode.
            try wake()
            _ = try exchange(0x14, [0x01])
            bytes = try exchange(0x02)
        }
        guard bytes.count == 4, bytes[0] == 0x32 else {
            throw ReaderError(detail: "收到响应，但设备没有报告 PN532 兼容的固件标识。")
        }
        return "PN532 兼容 · 固件 \(bytes[1]).\(bytes[2]) · 支持位 \([bytes[3]].hex)"
    }

    private func wake() throws {
        try serial.send([0x55, 0x55] + Array(repeating: 0, count: 14), before: deadline(0.4))
        Thread.sleep(forTimeInterval: 0.035)
    }

    func scan() throws -> NFCATag? {
        _ = try exchange(0x14, [0x01, 0x14, 0x00])
        _ = try exchange(0x32, [0x05, 0xFF, 0x01, 0x02])
        scanned = true
        let data = try exchange(0x4A, [0x02, 0x00], timeout: 2)
        if data == [0] { return nil }
        if data.first == 2 { throw ReaderError(detail: "检测到多张标签。请只放一张。") }
        guard data.count >= 6, data[0] == 1, data[1] == 1,
              [4, 7, 10].contains(Int(data[5])), data.count >= 6 + Int(data[5]) else {
            throw ReaderError(detail: "刷卡响应不完整或格式异常。")
        }
        return NFCATag(target: data[1], uid: Array(data[6..<(6 + Int(data[5]))]),
                       atqa: Array(data[2...3]), sak: data[4])
    }

    func readNTAG(from tag: NFCATag) throws -> NTAGData? {
        guard tag.uid.count == 7, tag.sak == 0 else { return nil }
        // Use ISO14443-A exchange here because 0x60 also has a MIFARE Classic meaning.
        var version = try checkedTagResponse(exchange(0x42, [0x60]))
        if version.count == 10 {
            let crc = version.prefix(8).reduce(UInt16(0x6363)) { partial, byte in
                var value = (partial & 0xFF) ^ UInt16(byte)
                value = (value ^ (value << 4)) & 0xFF
                return (partial >> 8) ^ (value << 8) ^ (value << 3) ^ (value >> 4)
            }
            guard version[8] == UInt8(crc & 0xFF), version[9] == UInt8(crc >> 8) else {
                throw ReaderError(detail: "标签版本响应的 CRC 校验失败。")
            }
            version.removeLast(2)
        }
        let models = [0x0F: ("NTAG213", 144), 0x11: ("NTAG215", 504), 0x13: ("NTAG216", 888)]
        guard version.count == 8, version.prefix(6) == [0x00, 0x04, 0x04, 0x02, 0x01, 0x00],
              version[7] == 0x03, let (model, capacity) = models[Int(version[6])] else {
            throw ReaderError(detail: "标签未报告 NTAG213、NTAG215 或 NTAG216。")
        }
        let header = try tagCommand(tag, [0x30, 0x00])
        guard header.count == 16, header[12] == 0xE1, header[13] >> 4 == 1,
              header[15] >> 4 == 0 else {
            throw ReaderError(detail: "标签没有可公开读取的 NFC Forum Type 2 数据区。")
        }
        let length = Int(header[14]) * 8
        guard length > 0, length <= capacity else { throw ReaderError(detail: "标签报告的 NDEF 容量无效。") }
        return NTAGData(model: model, header: header, memory: try readUserMemory(tag, length: length))
    }

    func writeNDEF(_ message: [UInt8], expectedUID: [UInt8]) throws -> NFCATag {
        guard let tag = try scan(), tag.uid == expectedUID else {
            throw ReaderError(detail: "请将刚才识别的同一张空白标签放回感应区。")
        }
        guard let ntag = try readNTAG(from: tag), ntag.model == "NTAG213" else {
            throw ReaderError(detail: "写入仅支持 NTAG213。")
        }
        if try ntag.message == message { return tag }
        guard let offset = ntag.emptyMessageOffset else {
            throw ReaderError(detail: "标签已有内容、被锁定或格式不适合空白写入。")
        }
        let config = try tagCommand(tag, [0x30, 0x28])
        guard config.count == 16, config.prefix(3) == [0, 0, 0],
              config[4] & 0xC0 == 0, config[7] == 0xFF else {
            throw ReaderError(detail: "标签使用了动态锁、镜像或访问保护。")
        }
        guard !message.isEmpty, message.count + offset + 3 <= ntag.memory.count else {
            throw ReaderError(detail: "内容超过这张标签的 NDEF 容量。")
        }
        var updated = ntag.memory
        let tlv: [UInt8] = [0x03, UInt8(message.count)] + message + [0xFE]
        updated.replaceSubrange(offset..<(offset + tlv.count), with: tlv)
        let firstPage = offset / 4
        let lastPage = (offset + tlv.count - 1) / 4

        // Commit the length byte last so earlier interrupted writes still read as empty.
        for page in (firstPage...lastPage).reversed() {
            let bytes = (4 * page)..<(4 * page + 4)
            if ntag.memory[bytes] != updated[bytes] {
                let confirmation = try tagCommand(tag, [0xA2, UInt8(4 + page)] + updated[bytes])
                guard confirmation.isEmpty || confirmation == [0x0A] else {
                    throw ReaderError(detail: "标签未确认写入。请重新读取检查。")
                }
            }
        }
        let verified = try readUserMemory(tag, length: ntag.memory.count)
        guard verified == updated, try NDEF.unwrapType2(verified) == message else {
            throw ReaderError(detail: "回读校验失败。请重新读取标签检查。")
        }
        return tag
    }

    private func readUserMemory(_ tag: NFCATag, length: Int) throws -> [UInt8] {
        var memory: [UInt8] = []
        while memory.count < length {
            // Keep the last four-page read within the advertised data area.
            let offset = min(memory.count, length - min(16, length))
            let block = try tagCommand(tag, [0x30, UInt8(4 + offset / 4)])
            guard block.count == 16 else { throw ReaderError(detail: "标签返回了不完整的数据页。") }
            memory += block.dropFirst(memory.count - offset).prefix(length - memory.count)
        }
        return memory
    }

    private func tagCommand(_ tag: NFCATag, _ data: [UInt8]) throws -> [UInt8] {
        try checkedTagResponse(exchange(0x40, [tag.target] + data))
    }

    private func checkedTagResponse(_ reply: [UInt8]) throws -> [UInt8] {
        guard let status = reply.first else { throw ReaderError(detail: "标签响应缺少状态码。") }
        guard status == 0 else { throw ReaderError(detail: "标签拒绝操作或已移开（状态 \([status].hex)）。") }
        return Array(reply.dropFirst())
    }

    private func deadline(_ seconds: TimeInterval) -> TimeInterval {
        ProcessInfo.processInfo.systemUptime + seconds
    }

    private func exchange(_ command: UInt8, _ args: [UInt8] = [], timeout: TimeInterval = 0.65) throws -> [UInt8] {
        let payload: [UInt8] = [0xD4, command] + args
        let length = UInt8(payload.count)
        let frame: [UInt8] = [0, 0, 0xFF, length, 0 &- length] + payload + [0 &- payload.reduce(0, &+), 0]
        let end = deadline(timeout)
        try serial.send(frame, before: end)
        do {
            guard try nextFrame(before: end) == nil else { throw ReaderError(detail: "PN532 响应缺少 ACK。") }
            guard let response = try nextFrame(before: end), response.count >= 2,
                  response.prefix(2) == [0xD5, command &+ 1] else {
                throw ReaderError(detail: "收到不匹配的 PN532 响应。")
            }
            return Array(response.dropFirst(2))
        } catch {
            try? serial.send(Self.ack, before: deadline(0.10))
            throw error
        }
    }

    private func nextFrame(before end: TimeInterval) throws -> [UInt8]? {
        var marker: UInt32 = 0xFFFFFF
        while marker != 0x0000FF {
            let byte = try serial.receive(1, before: end)[0]
            marker = ((marker << 8) | UInt32(byte)) & 0xFFFFFF
        }
        let header = try serial.receive(2, before: end)
        if header == [0, 0xFF] {
            guard try serial.receive(1, before: end) == [0] else { throw ReaderError(detail: "PN532 ACK 损坏。") }
            return nil
        }
        guard header[0] > 0, header[0] &+ header[1] == 0 else {
            throw ReaderError(detail: "PN532 返回了不支持的帧格式或长度校验错误。")
        }
        let bytes = try serial.receive(Int(header[0]) + 2, before: end)
        guard bytes.last == 0, bytes.dropLast().reduce(0, &+) == 0 else {
            throw ReaderError(detail: "PN532 响应的数据校验失败。")
        }
        return Array(bytes.dropLast(2))
    }
}
