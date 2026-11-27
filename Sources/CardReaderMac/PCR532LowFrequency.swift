import Foundation

struct LowFrequencyID {
    let bytes: [UInt8]

    var number: UInt32 {
        bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}

struct PCR532LowFrequency {
    private let serial: SerialPort

    // These two vendor frames are sent verbatim. The trailing bytes differ from a PN532 command checksum.
    private static let identifyFrame: [UInt8] = [0, 0, 0xFF, 6, 0xFA, 0xD4, 0xA5, 0x5A, 0xA5, 0x5A, 0xA5, 0x5A, 0, 0]
    private static let readFrame: [UInt8] = [0, 0, 0xFF, 3, 0xFD, 0xD4, 0xAC, 0, 0, 0, 0]
    private static let responseStart = PN532.ack + [0, 0, 0xFF]
    private static let identificationPrefixes: [[UInt8]] = [
        [0x0A, 0xF6, 0xD5, 0xA6, 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55],
        [0x0A, 0xF6, 0xD5, 0xA6, 0xA5, 0x5A, 0xA5, 0x5A, 0xA5, 0x5A],
        [0x0B, 0xF5, 0xD5, 0xA6, 0x5A, 0xA5, 0x5A, 0xA5, 0x5A, 0xA5],
    ].map { responseStart + $0 }

    init(port: ReaderPort, baud: Int) throws {
        serial = try SerialPort(path: port.id, baud: baud)
        // Both Windows applications use the default SerialPort modem settings.
        try serial.deassertModemLines()
    }

    func readID() throws -> LowFrequencyID? {
        let handshake: [UInt8]
        let handshakeDeadline = ProcessInfo.processInfo.systemUptime + 5
        do {
            try serial.send(Self.identifyFrame, before: handshakeDeadline)
            handshake = try serial.receive(23, before: handshakeDeadline)
        } catch is SerialTimeout {
            throw ReaderError(detail: "串口已打开，5 秒内未收到完整的 125 kHz 握手响应。请确认设备支持 USB 联机读取 ID 卡。")
        }
        guard Self.identificationPrefixes.contains(where: { handshake.starts(with: $0) }) else {
            throw ReaderError(detail: "低频模块返回了无法识别的握手响应。")
        }
        try serial.discardInput()

        let reply: [UInt8]
        let readDeadline = ProcessInfo.processInfo.systemUptime + 5
        do {
            try serial.send(Self.readFrame, before: readDeadline)
            reply = try serial.receive(22, before: readDeadline)
        } catch is SerialTimeout {
            throw ReaderError(detail: "低频模块已通过握手，但读卡响应超时。")
        }
        guard reply.starts(with: Self.responseStart), reply[9] &+ reply[10] == 0,
              reply[11...12] == [0xD5, 0xAD] else {
            throw ReaderError(detail: "低频模块返回了无法识别的读卡响应。")
        }
        let card = LowFrequencyID(bytes: Array(reply[14...17]))
        switch reply[13] {
        case 0xAA:
            return card
        case 0x00:
            return card.number == 0 ? nil : card
        case 0xA0, 0xA1, 0xAB...0xAE:
            throw ReaderError(detail: "模块报告了其他频段的 ID 卡。此操作读取 125 kHz ID 卡。")
        default:
            throw ReaderError(detail: "低频模块返回了未知读卡状态（\([reply[13]].hex)）。")
        }
    }
}
