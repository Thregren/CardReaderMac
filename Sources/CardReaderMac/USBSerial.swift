import Darwin
import Foundation
import IOKit

struct ReaderPort: Identifiable, Equatable {
    let id: String
    let product: String
    let driver: String
    let release: Int?

    static func discover() -> [Self] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOSerialBSDClient"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var ports: [Self] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func property<T>(_ key: String) -> T? {
                IORegistryEntrySearchCFProperty(
                    service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                    IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
                ) as? T
            }
            guard (property("idVendor") as Int?) == 0x1A86,
                  (property("idProduct") as Int?) == 0x7523,
                  let path: String = property("IOCalloutDevice") else { continue }
            var parent: io_registry_entry_t = 0
            var driver = "系统串口驱动"
            if IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS {
                defer { IOObjectRelease(parent) }
                if let bundle = IORegistryEntryCreateCFProperty(parent, "CFBundleIdentifier" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
                    driver = bundle
                }
            }
            ports.append(Self(id: path, product: property("USB Product Name") ?? "WCH USB Serial",
                              driver: driver, release: property("bcdDevice")))
        }
        return ports.sorted { $0.id < $1.id }
    }
}

struct ReaderError: LocalizedError {
    let detail: String
    var errorDescription: String? { detail }

    static func system(_ operation: String) -> Self {
        let code = errno
        return Self(detail: "\(operation)失败（\(String(cString: strerror(code)))）")
    }
}

struct SerialTimeout: LocalizedError {
    var errorDescription: String? { "设备响应超时。" }
}

final class SerialPort {
    private let fd: Int32
    private var original = termios()
    private var modemLinesToRestore: Int32 = 0

    init(path: String, baud: Int) throws {
        fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ReaderError.system("打开串口") }
        do {
            guard ioctl(fd, TIOCEXCL) == 0, tcgetattr(fd, &original) == 0 else {
                throw ReaderError.system("取得串口配置")
            }
            var config = original
            cfmakeraw(&config)
            config.c_cflag |= tcflag_t(CLOCAL | CREAD)
            config.c_cflag &= ~tcflag_t(HUPCL | CRTSCTS | CDTR_IFLOW | CDSR_OFLOW | CCAR_OFLOW)
            guard cfsetspeed(&config, speed_t(baud)) == 0,
                  tcsetattr(fd, TCSANOW, &config) == 0 else { throw ReaderError.system("设置串口") }
            if tcflush(fd, TCIFLUSH) != 0 {
                let error = ReaderError.system("清理串口输入")
                tcsetattr(fd, TCSANOW, &original)
                throw error
            }
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    deinit {
        if modemLinesToRestore != 0 {
            _ = ioctl(fd, TIOCMBIS, &modemLinesToRestore)
        }
        tcsetattr(fd, TCSANOW, &original)
        Darwin.close(fd)
    }

    func deassertModemLines() throws {
        var activeLines: Int32 = 0
        guard ioctl(fd, TIOCMGET, &activeLines) == 0 else {
            if errno == ENOTTY { return }
            throw ReaderError.system("读取串口控制线状态")
        }
        var mask = TIOCM_DTR | TIOCM_RTS
        let assertedLines = activeLines & mask
        guard assertedLines != 0 else { return }
        guard ioctl(fd, TIOCMBIC, &mask) == 0 else {
            throw ReaderError.system("关闭串口 DTR 和 RTS")
        }
        modemLinesToRestore = assertedLines
    }

    func discardInput() throws {
        guard tcflush(fd, TCIFLUSH) == 0 else { throw ReaderError.system("清理串口输入") }
    }

    func send(_ bytes: [UInt8], before deadline: TimeInterval) throws {
        try bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                try wait(for: Int16(POLLOUT), before: deadline)
                let count = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                if count > 0 { offset += count }
                else if count == 0 || (errno != EINTR && errno != EAGAIN) { throw ReaderError.system("发送串口数据") }
            }
        }
    }

    func receive(_ count: Int, before deadline: TimeInterval) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        try bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < count {
                try wait(for: Int16(POLLIN), before: deadline)
                let received = Darwin.read(fd, base.advanced(by: offset), count - offset)
                if received > 0 { offset += received }
                else if received == 0 { throw ReaderError(detail: "串口已断开。") }
                else if errno != EINTR && errno != EAGAIN { throw ReaderError.system("读取串口") }
            }
        }
        return bytes
    }

    private func wait(for event: Int16, before deadline: TimeInterval) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw SerialTimeout() }
            var descriptor = pollfd(fd: fd, events: event, revents: 0)
            let result = poll(&descriptor, 1, Int32((remaining * 1000).rounded(.up)))
            if result < 0 && errno == EINTR { continue }
            if result < 0 { throw ReaderError.system("等待串口") }
            if result == 0 { throw SerialTimeout() }
            if descriptor.revents & event != 0 { return }
            throw ReaderError(detail: "串口已断开或无法通信。")
        }
    }
}
