# 硬件兼容性与协议验证

## 硬件与软件证据

| 证据 | 观察 |
| --- | --- |
| 当前 Mac 的 IORegistry | USB 设备名 `USB Serial`，VID:PID 为 `1A86:7523`，设备版本字段 `0x0264`，USB 全速 12 Mb/s。该设备枚举出一个厂商自定义接口，由 `AppleUSBCHCOM` 绑定并创建 `/dev/cu.usbserial-210`。当前枚举中未见独立 USB HID 接口。 |
| RFIDFans 的中文版安装包 `pcr532.exe` | x86 NSIS。`CH341SER.INF` 将 `1A86:7523` 匹配为 CH340 串口设备。`PN532CardReader.exe` 为 x86 .NET Framework 4.6 程序，程序集版本 1.0.6.9。附带原生 `libnfc.dll`，配置为 `pn532_uart`、115200 bps。 |
| 英文版安装包 `Nfcking_eng.exe` | x86 NSIS。附带相同的 `CH341SER.INF`，串口配置同为 `pn532_uart`、115200 bps。 |
| Android 包 `pcr532.apk` | APK 压缩数据校验通过。附带 Android ARM64 ELF 库 `libnfc.so`，包含 `pn532_uart_driver` 和扩展 UART/MCU 接口。APK 中的 ELF 不能作为 macOS 库使用。 |
| 当前读写器的实时响应 | 115200 bps 下，固件查询返回 PN532 标识 `0x32`、版本 1.6、支持位 `0x07`。NFC-A 寻卡完成，当时没有检测到标签。 |

PCR532 为配套软件名称。当前设备有 `V555` 标记，外壳无按键。USB 枚举与固件返回值能确认串口桥家族和 PN532 兼容接口。`V555` 对应的板卡资料、射频芯片丝印和低频模块的联机方式尚未确认。CUID 和 MIFARE Classic 类卡在支持 NFC-A 防冲突时可以显示其公开识别字段，读出的字段无法区分所有 CUID 变体。当前应用的写入范围是空白 NTAG213 的公开 NDEF 数据区。

### Windows 上位机的低频读取

- 中文版窗口加载方法 `0x06000086` 和自动连接定时器 `0x060000D5` 都可进入探测方法 `0x0600008A`。它先调用 `0x06000088`，打开串口、发送 ASCII `SETTING=9` 加 CRLF 并关闭串口。探测随后重开串口，发送 24 字节的 PN532 唤醒及普通模式 `SAMConfiguration` 请求，成功后配置 `pn532_uart`。英文版的自动探测 `0x06000089` 直接发同一唤醒帧，两版的手动连接也各有发送 `SETTING=9` 的分支。`SETTING=9` 的发送方法不读取响应，具体固件语义未确认。 [RFIDFans 发布帖](https://www.rfidfans.com/thread/9)
- 中文版 `PN532CardReader.exe` 1.0.6.9 的「读 ID 卡」处理函数为 `0x060000FD`，英文版 `Nfcking.exe` 1.6.8.0 为 `0x060000F7`。两版以默认 115200 bps、8N1 打开串口后直接发送 `A5` 识别帧，DTR 和 RTS 都沿用 .NET 默认的关闭状态。中文版的串口读取超时为 5 秒，英文版为 2 秒。Mac 版低频读取采用中文版的控制线状态和 5 秒握手等待。 [RFIDFans 发布帖](https://www.rfidfans.com/thread/9) · [Microsoft DtrEnable](https://learn.microsoft.com/zh-cn/dotnet/api/system.io.ports.serialport.dtrenable) · [Microsoft RtsEnable](https://learn.microsoft.com/zh-cn/dotnet/api/system.io.ports.serialport.rtsenable)
- 中文版读取 23 字节并比较三种 `A6` 应答签名。握手通过后发 `AC` 读卡帧，响应命令为 `AD`。上位机以响应第 14 字节的状态识别 125 kHz 卡，从第 15 至 18 字节取卡号，按大端无符号整数显示。该扩展借用 PN532 串口帧头，Mac 实现保留原始请求帧。 [NXP PN532 标准协议](https://www.nxp.com/docs/en/user-guide/141520.pdf)
- Windows 在 `A5` 握手失败后才走备用分支，依次唤醒 PN532、执行 `SAMConfiguration`、切换 `P72` 并查询 GPIO。中文版根据 `P30` 的电平显示状态。这条分支结束时没有获取卡号或重发 `A5`。 [NXP PN532 GPIO 命令](https://www.nxp.com/docs/en/user-guide/141520.pdf#page=81)
- V555 实机在 115200 bps 下对 `A5` 回了 0 字节。关闭 DTR 和 RTS 后等待 5 秒仍为 0 字节，执行 PN532 唤醒和 `SAMConfiguration` 后重试也是如此。同期标准 PN532 固件查询与 GPIO 读取均成功。用 0.1.2 发布包复测时，握手在约 5 秒后超时，DTR 和 RTS 在握手期间关闭并在退出时恢复，读卡前后的固件查询都返回 1.6。V555 的低频模块如何启用、是否能经 USB 回传卡号仍待确认。
- 按中文版自动连接顺序复测 V555。发送 `SETTING=9` 后关闭并重开串口，再发送原始 PN532 唤醒帧，收到正常 `D5 15`。随后再次重开串口并发送 `A5`，等待 5 秒收到 0 字节，固件查询仍返回 1.6。两版按钮的低频收发都直接使用 .NET `SerialPort`。
- 中文安装包附带 `nfc.dll`（x86）和 `nfd.dll`（x64）。两者的 `nfc_initiator_transceive_for_mcu` 在 `pn532_uart` 后端分别分派到 `0x1000D4B0` 和 `0x180015F40`，两个回调都只执行 `SAMConfiguration(0x03)`，这是 PN532 与内部 SAM 通信的 Wired Card 模式。回调只返回命令执行结果。随包的 `nfctag.exe` 使用该导出，`nfc-list.exe` 和 `nlist.exe` 走高频轮询或卡片工具的入口。 [RFIDFans 发布帖](https://www.rfidfans.com/thread/9) · [NXP PN532 手册第 7.2.10 节](https://www.nxp.com/docs/en/user-guide/141520.pdf#page=89)
- `nfd.dll` 打开 `pn532_uart` 时，先以 `Diagnose(0x00)` 检查 `libnfc` 字符串回显，再用 `Diagnose(0x01)` 检查 ROM，等待上限为 3 秒。ROM 检查函数 `0x180012FC0` 接受 `0xFF` 为成功，NXP 手册将此值定义为 ROM 校验未通过。V555 实机以 115200 bps 返回正确回显及 `D5 01 FF`。重开串口并关闭 DTR 和 RTS 后，`A5` 在 5 秒内仍收到 0 字节，随后固件查询仍正常。两项诊断未提供 V555 启用低频或回传卡号的证据。 [NXP PN532 手册第 7.2.1 节](https://www.nxp.com/docs/en/user-guide/141520.pdf#page=69)
- WinGet 的 `1.0.6.8` 是安装包登记版本，清单的 SHA-256 与已分析的中文版安装包相同，包内主程序程序集版本是 `1.0.6.9`。WinGet 的历史清单曾记录另一份校验值，下载 URL 相同。 [WinGet 清单和更新记录](https://github.com/microsoft/winget-pkgs/pull/292528/files)

### 开源参考

- USB 串口层可参照 [Linux 的 `ch341` 驱动源码](https://github.com/torvalds/linux/blob/master/drivers/usb/serial/ch341.c) 和 [WCH CH340 芯片资料](https://www.wch.cn/products/CH340.html)。本机直接使用 Apple 自带驱动。
- NFC 串口协议可参照 [libnfc PN532 UART 后端](https://github.com/nfc-tools/libnfc/blob/master/libnfc/drivers/pn532_uart.c) 和 [NXP PN532 手册](https://www.nxp.com/docs/en/user-guide/141520.pdf)。本项目实现独立 Swift 后端。
- 标签数据格式来自 [NFC Forum 规范](https://nfc-forum.org/build/specifications/) 和 [NXP NTAG213/215/216 数据手册](https://www.nxp.com/docs/en/data-sheet/NTAG213_215_216.pdf)。
- 三份软件包来自 [RFIDFans 发布帖](https://www.rfidfans.com/thread/9)，分析在临时目录静态进行。

样本 SHA-256

| 样本 | SHA-256 |
| --- | --- |
| `pcr532.exe` | `20ec9676b2d1341561061a46c95191fb3a06a0ceb56cbb3bd2555f48a5f89151` |
| `Nfcking_eng.exe` | `7e79fa943c3f9291bfaf6ca6bcb95d982c4c875783381bddb623c7527dc49bf9` |
| `pcr532.apk` | `8014cd8876da6044293cf4ea2293689f873423eafff94f6b1fa624e6dbca4f10` |
