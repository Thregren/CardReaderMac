# CardReaderMac

适用于 Apple Silicon 的 SwiftUI 射频卡读写工具。通过 macOS 自带的 USB 串口驱动连接 PN532 兼容读写器，无需安装 Windows 驱动。应用识别 USB VID:PID 为 `1A86:7523` 的 WCH 串口设备。

## 下载与使用

需要 Apple Silicon Mac 和 macOS 14 或更高版本。从 [GitHub Releases](https://github.com/Thregren/CardReaderMac/releases/latest) 下载 `CardReaderMac.zip`，解压后打开 `CardReaderMac.app`。

1. 插入读写器，在「读写器」页选择对应串口。默认波特率为 115200 bps。
2. 点「检测读写器」。已测试的 V555 在此处报告 PN532 兼容固件 1.6。
3. 将标签放在感应区，点「读取 NFC-A 标签」。适用标签的公开 NDEF 记录会一起显示。
4. 识别出空白 NTAG213 后，可点「写入空白 NTAG213…」，写入文本或 HTTP(S) 网址。保持同一张标签在感应区，应用在写入后会回读校验。
5. 对支持 PCR532 低频串口扩展的读写器，可点「读取 125 kHz ID 卡」。模块响应后，应用会显示卡号的十六进制和十进制格式。

发布包采用临时签名（ad hoc），尚未经过 Apple 公证。macOS 若阻止打开，请参考 [Apple 的说明](https://support.apple.com/zh-cn/102445)，也可以在本机从源码构建。

## 功能与验证状态

| 功能 | 当前支持与验证 |
| --- | --- |
| USB 串口与固件查询 | V555 实机通过，能读取固件版本和 GPIO 状态。 |
| 13.56 MHz NFC-A | 读取标签公开的 UID、ATQA、SAK，包括能响应 NFC-A 寻卡的 MIFARE Classic 与 CUID 类卡。V555 实机的寻卡命令已得到响应，测试时未检测到标签。 |
| NDEF | 读取 NTAG213、NTAG215、NTAG216 的公开 NDEF，支持离线解析 NDEF 消息与 Type 2 TLV。空白 NTAG213 的文本及网址写入、回读和异常处理已在模拟串口上验证，实体标签写入待验证。 |
| 125 kHz ID | 实现 PCR532 扩展协议的卡号读取。V555 实机的低频握手在 5 秒内收到 0 字节，USB 联机读卡尚未验证。 |

「NDEF 数据」页可离线生成文本或 URI 记录的十六进制，也可解析已有数据。应用只写入已识别为空白的 NTAG213 NDEF 数据区。CUID 和 MIFARE Classic 的操作范围是读取公开识别字段。

USB 接口、Windows 上位机分析和 V555 复测记录见 [硬件兼容性与协议验证](docs/hardware.md)。

## 从源码构建

安装 Xcode 或 Command Line Tools，在仓库根目录执行：

```sh
./build-app.sh
```

构建脚本生成 ARM64 应用包 `dist/CardReaderMac.zip`。也可以用 Xcode 打开 `Package.swift`。

以下命令在解压目录运行，可分别列出 USB 串口、查询固件、扫描 NFC-A 标签和读取 125 kHz 卡号。

```sh
./CardReaderMac.app/Contents/MacOS/CardReaderMac --list
./CardReaderMac.app/Contents/MacOS/CardReaderMac --probe
./CardReaderMac.app/Contents/MacOS/CardReaderMac --scan
./CardReaderMac.app/Contents/MacOS/CardReaderMac --read-id
```
