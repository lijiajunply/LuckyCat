# LuckyCat 标准隧道原型

此原型对应《LuckyCat iOS 技术方案与设计文档》第 1–2 周开发线。主 App 导入单个双栈 WireGuard 测试配置，展示首次使用的数据披露，并通过 iOS 管理连接。扩展使用公开的 `NEPacketTunnelFlow` 接入固定版本的 wireguard-go，在收到远端加密握手后安装路由和 DNS 设置。系统 VPN 状态显示在主 App 中。

原型配置和密钥按修订号保存在同团队共享钥匙串中，使用首次解锁后可访问的本机属性。系统 VPN 配置保存远端地址、配置标识和修订号。测试配置应在验证结束后撤销客户端公钥，并按团队流程删除原始文件。

## 构建与签名

- 使用 Xcode 27.2、Go 1.26.1 和 iOS 27.2。本阶段沿用工程原有 iOS 部署版本。
- 扩展在构建时编译 wireguard-go `v0.0.0-20261024220952-b3bc704ef0ee`，Go 依赖校验值见 [go.sum](../WireGuardBridge/go.sum)。Go 可执行文件需位于 PATH、`/usr/local/go/bin` 或 Homebrew 默认目录。首次构建需要下载锁定的依赖。
- 在 Xcode 登录有权限的开发团队。给 `com.luckyfish.LuckyCat` 和 `com.luckyfish.LuckyCat.PacketTunnel` 使用同一团队下的显式 App ID，开启 Network Extensions，使用含 `packet-tunnel-provider` 的开发描述文件。两个签名产物的 `keychain-access-groups` 应含同一个展开后的 `$(AppIdentifierPrefix)com.luckyfish.LuckyCat.WireGuardPrototype`，并和两包 Info.plist 的 `PrototypeKeychainGroup` 一致。
- 解锁并连接已注册的 iPhone，在 Xcode 选择 `LuckyCat` scheme 并运行。需要核对实际签名时，对主 App 和嵌入的 `PlugIns/LuckyCatPacketTunnel.appex` 分别运行 `codesign -d --entitlements :- <路径>`。

```sh
xcodebuild -scheme LuckyCat -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
xcodebuild -scheme LuckyCat -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO
(cd WireGuardBridge && go test -race ./...)
```

## 测试配置

在受控远端启用标准 WireGuard UDP 服务。为 iPhone 生成单独的客户端密钥，远端 Peer 配置的 `AllowedIPs` 应包含客户端 IPv4 的 `/32` 和 IPv6 的 `/128`。为测试目的地配置双栈回程。若测试公网出口或远端转发 DNS，远端还需要对应的 IP 转发、防火墙、路由和解析器配置。

把下例保存为 JSON 并替换样例值。远端字段使用可达的 IPv4 或 IPv6 地址字面量，端口为 UDP。密钥为 WireGuard 使用的 32 字节 Base64。DNS 服务器要能从隧道内访问，并与远端 UDP 端点地址不同。原型安装双栈默认路由，并将远端地址排除在隧道之外。iOS 隧道接口使用 IPv6 `/120`，远端 Peer 仍按客户端的 `/128` 授权。使用具备 IPv6 出站的端点与路径验证 IPv6-only 场景。

```json
{
  "endpointAddress": "192.0.2.40",
  "endpointPort": 51820,
  "clientIPv4": "10.66.0.2",
  "clientIPv6": "fd66::2",
  "dnsServers": ["10.66.0.1", "fd66::1"],
  "privateKey": "<客户端私钥>",
  "peerPublicKey": "<远端公钥>"
}
```

## 真机验收

1. 在 iPhone 上访问信任的测试站点，记录连接前的网络可用性。用「文件」导入 JSON，核对远端，点击「连接」并确认数据披露和系统 VPN 授权。用远端的 `wg show` 核对该客户端的握手和收发计数。
2. 在远端用 `tcpdump -ni wg0 'ip or ip6'` 观察隧道内流量。在 iPhone 上分别访问受控 IPv4 和 IPv6 的 TCP 服务、向受控 UDP 服务发包，并用系统解析器打开一个测试域名。使用未缓存的测试域名，同时核对 DNS 解析器收到的查询。另在远端外网接口核对 WireGuard UDP 报文和预期出站地址。
3. 在 LuckyCat 点「断开」，确认状态回到「已断开」。用新请求复测原始网络，并确认对应测试流量已离开隧道。再连接一次，检查系统设置里仍只有一条 LuckyCat VPN 配置。
4. 用端口不可达的测试配置检查握手超时反馈，再用正确配置确认可以连接。记录 iOS 版本、网络类型、构建版本与测试结果。捕获数据限团队环境使用。

## 2026 年 11 月 20 日验证记录

在 iPhone 17 Pro Max（iOS 27.2）上用 Mac 局域网内的临时 WireGuard 对端测试。两包的开发签名、Packet Tunnel 权限和共享钥匙串一致性均已核对。真机测试构建临时加入自动探针，隧道扩展取自工程源码。

| 项目 | 结果 |
| --- | --- |
| 首次授权 | iOS 授权后成功建立隧道。首次操作期间曾显示系统配置读写失败，随后重试成功 |
| IPv4 和 IPv6 | 原 `/128` 接口设置出现 IPv6 TCP、UDP 超时。改为 `/120` 后，连续三轮通过双栈 TCP、UDP 回显，IPv6 探测目标位于客户端 `/120` 之外 |
| DNS | iOS 系统解析器发送 A、AAAA 查询，对端在隧道内收到并应答。App 使用解析结果完成 TCP 回显 |
| 断开恢复 | 三轮均回到「已断开」，连接前和断开后的公网 HTTPS 探针均成功。重复连接后系统只有一条 LuckyCat VPN 配置 |
| 远端不可达 | 关停对端后重连，系统回到「已断开」。修复重复系统状态通知覆盖断开原因的问题后，App 显示 WireGuard 握手超时 |
| 自动化 | iOS 27.2 模拟器用例全部通过。本地 wireguard-go 集成测试连续 20 次通过，并启用 Go race detector |

真机记录覆盖同一 Wi‑Fi 环境。公网 VPN 出口、蜂窝、IPv6-only/NAT64、网络切换和长稳测试仍待验证。

参考 [Apple Network Extensions 配置](https://developer.apple.com/documentation/xcode/configuring-network-extensions/) · [Apple Packet Tunnel 适用场景](https://developer.apple.com/documentation/technotes/tn3120-expected-use-cases-for-network-extension-packet-tunnel-providers) · [wireguard-go 固定提交](https://git.zx2c4.com/wireguard-go/commit/?id=b3bc704ef0ee21a36298601a9e1e5ff90377ac52)。

## 第三阶段配置导入

在「配置」页从文件导入或粘贴 YAML，预览节点，选择默认节点并保存。连接页读取本机保存的选择，首次连接前会显示数据使用说明。切换节点前先断开 VPN，选择后手动连接。原型 JSON 仍可导入。

YAML 使用 UTF-8，文件上限 32 KiB，最多 16 个节点。只接受根级 `proxies` 列表，按示例使用两格列表缩进和四格字段缩进。可用独立注释行和简单的单引号或双引号值。YAML 别名、标签、行内映射、策略组和规则超出该格式。各节点名称须唯一。`udp` 可省略或设为 `true`。`dns` 使用行内列表，地址应可经隧道访问。替换示例密钥后再导入。

```yaml
proxies:
  - name: Test Peer
    type: wireguard
    server: 192.0.2.40
    port: 51820
    ip: 10.66.0.2
    ipv6: "fd66::2"
    private-key: "<客户端私钥>"
    public-key: "<远端公钥>"
    dns: [10.66.0.1, "fd66::1"]
    udp: true
```

真机构建需要在主 App 和扩展的签名描述文件中加入 `group.com.luckyfish.LuckyCat`。App Group 保存带版本的快照，已有共享钥匙串组保存凭据。系统 VPN 配置通过配置 ID 和快照修订号读取对应版本。

## 第四阶段连接页与诊断

连接页用开关控制连接和断开；连接中、断开中禁用开关，避免重复请求。操作失败时按原因给出恢复入口：权限问题打开系统设置，配置问题跳到配置页，远端握手失败可重试。

扩展在 `handleAppMessage` 中返回就绪状态和 wireguard-go 的聚合 `rx_bytes`、`tx_bytes`。主 App 连接期间每 5 秒查询一次，显示接收、发送和更新时间；消息超时或版本不符时显示「暂不可用」，不改变系统 VPN 状态。分片计数不在每包路径上跨进程调用。

本地诊断写入 App 支持目录，最多 200 条、保留 7 天，仅记录事件、错误码和时间。设置页可预览、导出或清除记录；写入前清理控制字符并截断过长事件，不记录密钥、订阅链接、访问目标和包内容。

配置页新增「设为当前」和每个节点的「兼容提示」。导入预览显示节点的双栈地址、DNS 和首版限制。节点兼容提示由导入时保存的非敏感元数据生成；旧配置缺少元数据时提示重新导入。

验证命令：

```sh
xcodebuild -scheme LuckyCat -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
xcodebuild -scheme LuckyCat -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO
xcodebuild test -scheme LuckyCat -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -only-testing:LuckyCatTests
(cd WireGuardBridge && go test -race ./...)
```

模拟器 UI 测试不要加 `CODE_SIGNING_ALLOWED=NO`，否则测试宿主无法写入钥匙串，保存配置会失败。2026 年 11 月 20 日复跑：13 项单元测试通过，配置导入 UI 测试通过，Go race 测试通过，真机和模拟器编译通过。扩展流量上报、断线重连和真机长稳仍需在受控远端复测。
