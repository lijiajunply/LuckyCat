# LuckyCat ProjectClash 内部原型

对应设计文档第 2 节和第 3–4 周开发线。首个候选选用 Clash YAML 中的单个双栈 WireGuard 节点，便于沿用标准隧道阶段的受控远端和 TCP、UDP、DNS 验收方法。其他节点类型暂未列入兼容范围。

## 固定版本与复现

| 组件 | 固定版本 |
| --- | --- |
| ProjectClash SDK | [`v1.19.34-clash.1`](https://github.com/ProjectClash/Clash/tree/v1.19.34-clash.1)，提交 `c8f2fc1d58bf9ac856a0bf161bc9489591821f45` |
| Clash-Adapter | [`9ba5c2724b68c753d57496c1036f4dfb1587e482`](https://github.com/ProjectClash/Clash-Adapter/tree/9ba5c2724b68c753d57496c1036f4dfb1587e482)，与 [上游 Client 锁文件](https://github.com/ProjectClash/Clash-Client/blob/f84db6a964505c9f8592cc2dd1b16a25454b3dd7/Dependencies.lock.json) 配对 |
| 编译工具 | Xcode 27.2、独立安装的 Go 1.26.11、SagerNet gomobile 和 gobind `v0.1.13` |
| gomobile 模块校验值 | `h1:foTOGKJetah9VwaJl1XJx5TswIAVg8NfYmHOhrOc95I=` |

从仓库根目录运行。将独立安装的 Go 放到 PATH 前端，上游构建需要对 Go runtime 应用 overlay，Go 模块缓存内的自动下载工具链无法用于这一步。

```sh
PATH="/path/to/go1.26.11/bin:$PATH" ./ClashPrototype/build.sh
```

脚本核对 Git 提交和 [源文件 SHA-256](../ClashPrototype/sources.sha256)，在临时目录构建静态 SDK。独立 Swift 验证程序以 Extension 编译约束链接 SDK、`libresolv` 和 Adapter 源码，覆盖 iOS arm64、iOS Simulator arm64/x86_64 及当前 Mac 架构。脚本在 Mac 运行 YAML 和包桥验证，再运行上游 Go 测试。临时目录包含构建日志、SDK 校验值和对应源码。选择独立验证程序是为了保持当前 WireGuard 基线可用，并避免在同一进程内组合两个 Go 静态运行时。

在临时目录的 `core` 下运行 `go run -mod=readonly ./cmd/package_licenses -output dist/licenses` 可复现上游的 Apple SDK 模块许可清单。本轮生成的 `INDEX.json` 覆盖上游 Apple 目标合计 119 个模块。Adapter 许可、生成绑定的运行时通知及实际发布版选用的数据仍须纳入分发材料。

## 验证范围

| 路径 | 本轮验证 | 下一阶段证据 |
| --- | --- | --- |
| YAML → SDK | 单个 WireGuard 节点转换为 JSON，有效样例和无效密钥交给 SDK 验证。样例使用文档地址和合成密钥 | 设计白名单、大小和结构限制，以及完整配置导入 |
| Swift 包桥 → 内核入口 | Mac 探针经本地 socket pair 双向收发 IPv4、IPv6 包，检查四字节地址族头。上游测试另行检查传入坏描述符时的启动清理 | iPhone Extension 上通过系统 `NEPacketTunnelFlow` 验证装路由、启动、停止与回包 |
| 内核出站 → 受控远端 | 上游互操作测试用临时 WireGuard 对端验证双栈 TCP、UDP、隧道内 DNS 及失败密钥场景 | 在 iPhone 上将包桥与内核出站串联，核对远端实际包、DNS、出口、物理接口变化和断开行为，采集扩展内存峰值 |

候选路径为 iOS 网络栈 → `NEPacketTunnelFlow` → Adapter 的本地数据报 socket pair → Clash 用户态网络栈 → WireGuard 出站 → 受控远端。回包经相反路径注入 iOS 网络栈。内核会在用户态处理 TCP/UDP 并重建出站流，远端包语义和 Apple 对整条路径的要求仍需逐项核对。验证时使用显式隧道内 DNS 与固定 IP 对端，并检查物理链路上仅出现预期的 WireGuard 传输。 [Adapter 源码](https://github.com/ProjectClash/Clash-Adapter/blob/9ba5c2724b68c753d57496c1036f4dfb1587e482/Sources/ClashAdapter/PacketFlowBridge.swift) · [Apple TN3120](https://developer.apple.com/documentation/technotes/tn3120-expected-use-cases-for-network-extension-packet-tunnel-providers)

## 2026 年 11 月 20 日验证记录

- iOS arm64 真机目标和 iOS Simulator arm64/x86_64 目标完成静态链接。Apple Silicon Mac 与 arm64 模拟器通过 YAML 转换、单节点及错误密钥验证，并通过替身 Packet Flow 完成双栈包桥往返。
- 同一台 Mac 上两次独立构建的 SDK 清单和三个静态库的 SHA-256 一致。一次构建生成的 `sdk.sha256` 如下。
- 上游 Go 测试通过。受控远端互操作覆盖 auto、mips 和 gVisor 三种候选栈模式，验证双栈 TCP/UDP、DNS，以及错误对端公钥时连接失败。
- LuckyCat 既有模拟器回归通过，共 2 项单元测试和 2 项 UI 测试。
- iPhone 上的 VPN 授权、系统 Packet Flow 到远端的完整路径和扩展资源基线仍待验证。

```text
a4d6609cb5effcd19622b0c77b9396d8023bb7f38670a2b222d20feee8e4c06d  Info.plist
b8801330eb59533eda36e49a624562bf42526a48712c0fd01879547f40341c3e  ios-arm64/Clash.framework/Clash
716d9efb5b200c2f660271449958bc29a6a81ba55dd83c489bf03aea717ba2cc  ios-arm64_x86_64-simulator/Clash.framework/Clash
9e50bb04887a749116d90029e882d6f700a34c285b651ec1478eb4305101b87b  macos-arm64_x86_64/Clash.framework/Clash
```

## 发布条件

- 固定版 Adapter 用公开的 Packet Flow 方法和自建 socket pair。SDK 的 Darwin DNSInfo 实现另有三个 Apple 私有符号，接入路径包括物理接口监测中的 DNS 变更检查。发布候选需从构建产物移除该依赖，复测显式 DNS、接口切换及断线恢复，并核查本地监听器和其余链接代码。 [Darwin DNSInfo](https://github.com/ProjectClash/Clash/blob/c8f2fc1d58bf9ac856a0bf161bc9489591821f45/bind/clash/system_resolver_dnsinfo_darwin.go) · [Apple 审核指南 §2.5.1](https://developer.apple.com/app-store/review/guidelines/#software-requirements)
- Core 与 Adapter 均附 GPL-3.0。当前验证把未经修改的内核、gomobile 生成绑定和两份 Adapter 源文件编入独立探针。生成绑定含 BSD 风格许可的 gomobile 运行时代码，内核还有适用不同许可的传递依赖。外部分发决策需要准确的链接清单、通知、对应源码与构建材料，覆盖规则数据或 Geo 数据的实际来源，并确认 GPL、目标开源模式和 App Store 分发条款可以同时满足。本轮探针只使用内联规则和合成配置。 [Core 通知和依赖许可](https://github.com/ProjectClash/Clash/blob/c8f2fc1d58bf9ac856a0bf161bc9489591821f45/THIRD_PARTY_LICENSES.md) · [Adapter 许可](https://github.com/ProjectClash/Clash-Adapter/blob/9ba5c2724b68c753d57496c1036f4dfb1587e482/LICENSE) · [Apple 开发者协议与条款](https://developer.apple.com/support/terms/)
