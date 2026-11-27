import AppKit
import SwiftUI

@main
enum EntryPoint {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--list") {
            for port in ReaderPort.discover() { print("\(port.id)\t\(port.product)\t\(port.driver)") }
            return
        }
        if let action = CommandLine.arguments.dropFirst().first, ["--probe", "--scan", "--read-id"].contains(action) {
            guard let port = ReaderPort.discover().first else { print("找不到 WCH 串口设备。"); exit(2) }
            let speeds = CommandLine.arguments.dropFirst(2).compactMap(Int.init)
            guard speeds.allSatisfy(PN532.baudRates.contains) else { print("波特率不受支持。"); exit(2) }
            for baud in speeds.isEmpty ? [115200] : speeds {
                do {
                    if action == "--read-id" {
                        let reader = try PCR532LowFrequency(port: port, baud: baud)
                        if let card = try reader.readID() {
                            print("\(baud) · 125 kHz · \(card.bytes.hex) · \(card.number)")
                        } else { print("\(baud) · 低频模块已响应，未检测到 125 kHz ID 卡。") }
                        return
                    }
                    let reader = try PN532(port: port, baud: baud)
                    print("\(baud) · \(try reader.identify())")
                    if action == "--scan" {
                        if let tag = try reader.scan() {
                            print("UID \(tag.uid.hex) · ATQA \(tag.atqa.hex) · SAK \([tag.sak].hex)")
                            if let data = try reader.readNTAG(from: tag) {
                                print(data.model)
                                for record in try NDEF.decode(data.message ?? []) { print("\(record.type)\t\(record.value)") }
                            }
                        } else { print("未检测到 NFC-A 标签。") }
                    }
                    return
                } catch {
                    print("\(baud) · \(error.localizedDescription)")
                }
            }
            exit(1)
        }
        CardReaderMac.main()
    }
}

struct CardReaderMac: App {
    var body: some Scene {
        Window("射频卡读写器", id: "reader") {
            WorkspaceView()
                .frame(minWidth: 600, minHeight: 460)
        }
        .defaultSize(width: 730, height: 530)
    }
}

private struct WorkspaceView: View {
    var body: some View {
        TabView {
            DeviceView().tabItem { Label("读写器", systemImage: "wave.3.right.circle") }
            NDEFView().tabItem { Label("NDEF 数据", systemImage: "doc.text") }
        }
        .padding(16)
    }
}

private struct DeviceView: View {
    private enum Operation { case identify, nfc, lowFrequency }

    @State private var ports: [ReaderPort] = []
    @State private var portID: String?
    @State private var baud = 115200
    @State private var working = false
    @State private var summary: String?
    @State private var errorMessage: String?
    @State private var card: NFCATag?
    @State private var idCard: LowFrequencyID?
    @State private var records: [NDEFRecord] = []
    @State private var note: String?
    @State private var writable = false
    @State private var showWriteSheet = false
    @State private var writeText = ""
    @State private var writeURI = false
    private var selectedPort: ReaderPort? { ports.first { $0.id == portID } }

    var body: some View {
        Form {
            Section("USB 串口") {
                HStack {
                    Picker("设备", selection: $portID) {
                        if ports.isEmpty { Text("未发现 WCH 串口").tag(nil as String?) }
                        ForEach(ports) { port in Text(port.id).tag(Optional(port.id)) }
                    }
                    .disabled(working)
                    Button("刷新", systemImage: "arrow.clockwise", action: refresh)
                        .labelStyle(.iconOnly)
                        .help("刷新设备列表")
                }
                if let port = selectedPort {
                    LabeledContent("USB 标识", value: "1A86:7523 · \(port.product)")
                    LabeledContent("系统驱动", value: port.driver)
                    if let release = port.release {
                        LabeledContent("USB 设备版本", value: String(format: "0x%04X", release))
                    }
                }
                Picker("波特率", selection: $baud) {
                    ForEach(PN532.baudRates, id: \.self) { speed in
                        Text("\(speed.formatted(.number.grouping(.never))) bps").tag(speed)
                    }
                }
                .disabled(working)
                HStack {
                    Button("检测读写器") { run(.identify) }
                    Button("读取 NFC-A 标签") { run(.nfc) }
                        .buttonStyle(.borderedProminent)
                    Button("读取 125 kHz ID 卡") { run(.lowFrequency) }
                    if working { ProgressView().controlSize(.small).accessibilityLabel("正在与读写器通信") }
                }
                .disabled(selectedPort == nil || working)
            }

            Section("检测结果") {
                if let summary { LabeledContent("读写器", value: summary) }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                }
                if let card {
                    LabeledContent("UID", value: card.uid.hex)
                    LabeledContent("ATQA · SAK", value: "\(card.atqa.hex) · \([card.sak].hex)")
                }
                if let idCard {
                    LabeledContent("ID 卡号（十六进制）", value: idCard.bytes.hex)
                    LabeledContent("ID 卡号（十进制）", value: String(idCard.number))
                }
                if let note { Text(note).foregroundStyle(.secondary) }
                if summary == nil, errorMessage == nil, !working {
                    Text("读取前，请将一张标签放在感应区，再选择对应的读取操作。")
                        .foregroundStyle(.secondary)
                }
                ForEach(records) { record in
                    LabeledContent(record.type, value: record.value)
                }
                if writable {
                    Button("写入空白 NTAG213…") {
                        writeText = ""
                        writeURI = false
                        showWriteSheet = true
                    }
                    .disabled(working)
                }
            }
            .textSelection(.enabled)
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .onChange(of: portID) { clearResult() }
        .onChange(of: baud) { clearResult() }
        .sheet(isPresented: $showWriteSheet) { writeSheet }
    }

    private var writeSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("写入空白 NTAG213").font(.headline)
            if let card { LabeledContent("目标标签 UID", value: card.uid.hex) }
            Picker("内容类型", selection: $writeURI) {
                Text("文本").tag(false)
                Text("网址").tag(true)
            }
            .pickerStyle(.segmented)
            TextField(writeURI ? "https://example.com" : "要写入的文本", text: $writeText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...5)
            Text("写入期间请将同一张标签留在感应区。")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { showWriteSheet = false }
                Button("写入并校验") {
                    showWriteSheet = false
                    writeTag()
                }
                .buttonStyle(.borderedProminent)
                .disabled(writeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 420)
    }

    private func clearResult() {
        summary = nil
        errorMessage = nil
        card = nil
        idCard = nil
        records = []
        note = nil
        writable = false
    }

    private func refresh() {
        guard !working else { return }
        ports = ReaderPort.discover()
        if selectedPort == nil { portID = ports.first?.id }
    }

    private func run(_ operation: Operation) {
        guard let selectedPort, !working else { return }
        clearResult()
        working = true
        let speed = baud
        Task {
            defer { working = false }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    if operation == .lowFrequency {
                        let reader = try PCR532LowFrequency(port: selectedPort, baud: speed)
                        let card = try reader.readID()
                        return ScanResult(firmware: "PCR532 · 125 kHz 模块已响应", idTag: card,
                                          note: card == nil ? "未检测到 125 kHz ID 卡。" : nil)
                    }
                    let reader = try PN532(port: selectedPort, baud: speed)
                    let firmware = try reader.identify()
                    guard operation == .nfc else { return ScanResult(firmware: firmware) }
                    do {
                        guard let tag = try reader.scan() else {
                            return ScanResult(firmware: firmware, note: "未检测到 NFC-A 标签。")
                        }
                        do {
                            let data = try reader.readNTAG(from: tag)
                            let records = try NDEF.decode(data?.message ?? [])
                            let name = data.map { "\($0.model) · " } ?? ""
                            return ScanResult(firmware: firmware, tag: tag, records: records,
                                              note: records.isEmpty ? name + "未发现公开 NDEF 记录。" : data?.model,
                                              writable: data?.emptyMessageOffset != nil)
                        } catch {
                            return ScanResult(firmware: firmware, tag: tag, note: error.localizedDescription)
                        }
                    } catch {
                        return ScanResult(firmware: firmware, note: error.localizedDescription)
                    }
                }.value
                guard portID == selectedPort.id, baud == speed else { return }
                summary = result.firmware
                card = result.tag
                idCard = result.idTag
                records = result.records
                note = result.note
                writable = result.writable
            } catch {
                guard portID == selectedPort.id, baud == speed else { return }
                errorMessage = "\(speed) bps · \(error.localizedDescription)"
            }
        }
    }

    private func writeTag() {
        guard let port = selectedPort, let card, !working else { return }
        let message: [UInt8]
        do {
            if writeURI {
                let value = writeText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let uri = URLComponents(string: value), ["https", "http"].contains(uri.scheme?.lowercased() ?? ""),
                      let host = uri.host, !host.isEmpty else {
                    throw ReaderError(detail: "请输入有效的 HTTP 或 HTTPS 网址。")
                }
                message = try NDEF.encode(value, uri: true)
            } else {
                message = try NDEF.encode(writeText, uri: false)
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let speed = baud
        errorMessage = nil
        working = true
        Task {
            defer { working = false }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let reader = try PN532(port: port, baud: speed)
                    let firmware = try reader.identify()
                    let tag = try reader.writeNDEF(message, expectedUID: card.uid)
                    return ScanResult(firmware: firmware, tag: tag, records: try NDEF.decode(message),
                                      note: "NTAG213 · 写入完成，回读校验通过。")
                }.value
                summary = result.firmware
                self.card = result.tag
                records = result.records
                note = result.note
                writable = false
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

private struct ScanResult {
    let firmware: String
    var tag: NFCATag? = nil
    var idTag: LowFrequencyID? = nil
    var records: [NDEFRecord] = []
    var note: String? = nil
    var writable = false
}

private struct NDEFView: View {
    private enum Mode: String, CaseIterable { case decode = "解析十六进制", text = "生成文本", uri = "生成 URI" }
    @State private var mode: Mode = .decode
    @State private var input = ""
    @State private var output: [NDEFRecord] = []
    @State private var hex: String?
    @State private var errorMessage: String?
    @State private var type2 = false

    var body: some View {
        Form {
            Section("NFC Forum 消息") {
                Picker("操作", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                if mode == .decode { Toggle("Type 2 标签的 TLV 数据", isOn: $type2) }
                TextEditor(text: $input)
                    .font(.system(.body, design: mode == .decode ? .monospaced : .default))
                    .frame(minHeight: 95)
                    .accessibilityLabel(mode == .decode ? "十六进制数据" : "NDEF 内容")
                HStack {
                    Button(mode == .decode ? "解析" : "生成十六进制", action: process)
                        .buttonStyle(.borderedProminent)
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if mode == .decode {
                        Button("载入示例") {
                            input = type2 ? "03 0C D1 01 08 54 02 7A 68 48 65 6C 6C 6F FE" : "D1 01 08 54 02 7A 68 48 65 6C 6C 6F"
                        }
                    }
                }
            }
            if errorMessage != nil || hex != nil || !output.isEmpty {
                Section("结果") {
                    if let errorMessage { Label(errorMessage, systemImage: "exclamationmark.circle") }
                    ForEach(output) { LabeledContent($0.type, value: $0.value) }
                    if let hex {
                        Text(hex).font(.system(.body, design: .monospaced))
                        Button("复制十六进制") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(hex, forType: .string)
                        }
                    }
                }
                .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .onChange(of: mode) {
            input = ""
            reset()
        }
        .onChange(of: input) { reset() }
        .onChange(of: type2) { reset() }
    }

    private func reset() {
        output = []
        hex = nil
        errorMessage = nil
    }

    private func process() {
        reset()
        do {
            if mode == .decode {
                let bytes = try NDEF.parseHex(input)
                let message = type2 ? (try NDEF.unwrapType2(bytes) ?? []) : bytes
                output = try NDEF.decode(message)
                if output.isEmpty { output = [NDEFRecord(id: 0, type: "NDEF", value: "没有记录")] }
            } else {
                hex = try NDEF.encode(input, uri: mode == .uri).hex
            }
        } catch { errorMessage = error.localizedDescription }
    }
}
