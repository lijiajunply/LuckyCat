# LuckyClash 优化清单（对齐 FlClash 能力）

本清单以对齐 FlClash 核心能力为目标，结合 iOS `NEPacketTunnelProvider` 约束与当前已集成的 `Clash.xcframework`（ProjectClash）已暴露的原生 API 整理而成，按优先级分为 **P0 → P3**。

---

## P0：核心体验与高频痛点

### 1. iOS PacketTunnel 稳定性与内存护栏（建议优先落地）
- [x] **内存软限制与压力释放**：在 `LuckyClashPacketTunnel/ClashEngine.swift` 的 `ClashSetupOptions` 中配置 `memoryLimit` 与 `memoryPressureShed`，防止加载大规则集 / `GeoSite.dat` 触碰 iOS 扩展 50 MB Jetsam 红线。
- [x] **OOM / 崩溃取证接入**：启动或诊断阶段读取 `ClashConsumeOOMEvidence`、`ClashConsumeGoCrashReport`、`ClashExplainLastStartup` 与 `ClashRecordMemoryPressureEvidence`，记录到 `DiagnosticLog` 便于真机排障。
- [x] **系统休眠与唤醒生命周期**：在 `LuckyClashPacketTunnel/PacketTunnelProvider.swift` 实现 `sleep(completionHandler:)` 与 `wake()`，转发给 `ClashBoxService.pause()` / `wake()`，降低锁屏耗电并避免唤醒后连接假死。
- [x] **网络切换感知与连接恢复**：在 `ClashEngine.handle(_ path:)` 切网时同步调用 `ClashSetNetworkIdentity(...)`，并在网络类型/默认路由变化后刷新系统 DNS 与清理失效连接。

### 2. 解除运行中全局禁用锁，支持内核配置热重载
- [x] **细化运行态操作权限**：解绑 `LuckyClash/Services/PrototypeVPN.swift`、`LuckyClash/Pages/ConnectionPage.swift`、`LuckyClash/Widgets/Profiles/ProfileDetailView.swift` 中的全局 `vpn.isActive` 禁用限制；VPN 运行中允许导入新配置、编辑/更新/重命名/删除**非活动配置**。
- [x] **扩展侧配置热重载**：升级 `PacketTunnelProvider.handleAppMessage`（解除 256 字节限制或扩展指令协议），支持在运行中调用 `ClashBoxService.reloadClassified(_:)` 无缝重载配置。
- [x] **无断网切换配置 & 更新活动订阅**：切换配置或更新当前活动配置时走热重载通道，消除 `PrototypeVPN.select(profileID:)` 中先断开隧道轮询等待再重连的断网抖动；仅在热重载失败或网络底层参数变化时回退为重连。

### 3. 多策略组独立选择、实时状态同步与持久化
- [x] **多策略组选中态持久化**：扩展 `LuckyClash/Models/ProfileLibrary.swift` 中 `Profile` 的选择模型，由单个 `clashGroup` / `clashSelectedMember` 升级为 `[String: String]`（`groupName -> selectedMember`）映射，兼容旧数据迁移。
- [x] **启动批量恢复策略组选择**：修改 `LuckyClashPacketTunnel/ClashEngine.swift` 启动流程，按保存的策略组映射批量调用 `ClashSelectProxy`。
- [x] **实时同步策略链与自动组状态**：通过 `ClashAPIClient.getGroups()` 读取各组实时 `now`（含 `url-test` / `fallback` / `load-balance` 当前生效节点）和固定状态，在节点页与连接页展示完整链路（如「代理 → 香港自动 → HK-01」）。
- [x] **自动组固定与解除固定**：支持在 `url-test` / `fallback` 策略组手动固定节点，并接入 `ClashAPIClient.unfixProxy(_:)` 一键恢复自动选择。

### 4. 节点/策略组页交互升级与 Providers 管理
- [x] **节点搜索、排序与过滤**：在 `LuckyClash/Pages/ProfilesView.swift` 增加搜索框（可结合 `ClashAPIClient.searchProxies` / `searchGroupMembers`）、排序（默认 / 延迟升序 / 名称）、隐藏超时节点、一键定位当前选中节点。
- [x] **视图样式切换**：支持策略组「Tab 分组 / 折叠列表」切换，以及节点「紧凑网格卡片 / 行列表」布局切换。
- [x] **测速体验优化**：在每个策略组头部增加显式一键测速按钮与加载态；在设置中开放延迟测试超时时间（`delayTestTimeout`）配置；运行中测速避免覆盖未返回结果的旧延迟。
- [x] **Proxy / Rule Providers 管理页**：接入 `ClashAPIClient.getProxyProviders`、`getRuleProviders`、`updateProxyProvider(_:)`、`updateRuleProvider(_:)`、`healthCheckProxyProvider(_:)`，展示节点/规则数、订阅流量与更新时间，支持运行中手动更新和健康检查。

---

## P1：配置覆写、规则能力与高级网络设置

### 5. 非破坏性配置覆写体系（Overrides）
- [x] **覆写模型与合成管线**：建立独立于原始订阅 YAML 的全局与单配置覆写数据模型，利用 SDK 内置 `ClashMergeOverrideForIOS`、`ClashEditRulesForIOS`、`ClashDocumentHandle` 在应用前动态合并，保证订阅更新不丢失本地定制。
- [x] **DNS 覆写设置页**：可视化配置 `enhanced-mode`（`fake-ip` / `redir-host`）、`nameserver`、`fallback`、`fake-ip-filter`、`respect-rules`、`ipv6` 与自定义 `hosts`；提供运行中一键清理缓存按钮（`ClashAPIClient.flushDNSCache` / `flushFakeIPCache`）。
- [x] **附加规则（Added Rules）**：支持在原始订阅规则之前/之后前置或追加自定义规则（直连 / 代理 / 拒绝 / 指定策略组）。
- [x] **规则浏览、命中统计与模拟测试**：接入 `ClashAPIClient.getRulesPage`、`getRuleHits`、`ClashMatchRuleForIOS`、`ClashRuleCatalog`，支持按类型/关键字查看生效规则、查看规则命中次数，以及输入域名/IP 模拟命中的规则与出口。
- [x] **Sniffer / NTP 覆写与最终配置预览**：支持可视化开关流量嗅探（Sniffer）与 NTP 覆写，并支持预览覆写合并后的最终生效 YAML。

### 6. 按需连接（On-Demand）、局域网共享与高级网络设置
- [x] **按需连接（SSID 排除）**：解除 `LuckyClash/Services/PrototypeVPN.swift` 中 `manager.isOnDemandEnabled = false` 硬编码，利用 iOS 原生 `NEOnDemandRule` 实现信任 Wi-Fi SSID 白名单自动断开、切回蜂窝/其他 Wi-Fi 自动连接。
- [x] **局域网共享代理（Allow LAN / Proxy Share）**：接入 SDK 的 `startProxyShare:username:password:`、`stopProxyShare:`、`getProxyShareStatus:`，在设置页提供开关、端口、局域网地址展示与可选账密鉴权。
- [x] **TUN / 网络参数设置**：在设置页开放 `ClashSetupOptions` / `ClashAppPolicyOptions` 已有能力：IPv6 模式（`tunIPv6Mode`）、IP 查询模式（`ipQueryMode`）、TUN MTU（`tunMTU`）、`includeAllNetworks`、绕过私有地址与仅统计代理流量（`onlyStatisticsProxy`）。
- [x] **通用请求与订阅设置**：支持自定义订阅请求的 User-Agent（默认与预设/自定义）、证书校验开关、Geo 资源自动更新策略与自定义 Geo 下载源（不局限于单次配置中的 `geox-url`）。

---

## P2：仪表盘与可观测性增强

### 7. 连接页仪表盘化与路由一致性
- [x] **首页仪表盘卡片**：在 `LuckyClash/Pages/ConnectionPage.swift` 增加实时上下行速率折线图（Swift Charts）、会话总流量卡片与内核内存占用卡片（补齐 `LuckyClash/Services/ClashLiveClient.swift` 中 `writeMemory(_:)` 的空实现，并提供一键 `ClashFreeMemory()` 入口）。
- [x] **流媒体与 AI 服务可用性检测**：新增服务状态卡片（对标 FlClash `ServiceStatusCard`），一键探测 ChatGPT / Claude / Google / YouTube / Netflix 等服务的连通性、延迟与区域解锁状态。
- [x] **出口 IP 路由一致性优化**：改进 `ConnectionPage` 切换模式/节点后仅 `Task.sleep(for: .seconds(1))` 盲等重测的实现；引入路由版本号与快速失败重试，避免切换瞬间闪烁错误或展示旧出口 IP。
- [x] **统一流量数据来源**：收敛 `PrototypeVPN` 每 5 秒 `sendProviderMessage` 轮询与 `NetworkStore` 实时 Socket 流量的重复统计逻辑。

### 8. 网络观测与诊断工具增强
- [x] **请求历史（Requests）**：在 `LuckyClash/Pages/NetworkPage.swift` 新增「请求历史」视图，接入 `ClashCommandConnectionEvents` 与 `setConnectionEventsWriter:` 记录已关闭连接；支持按时间/流量/速率排序、暂停刷新、导出与清空。
- [x] **连接一键加规则**：在 `ConnectionDetailView` 中支持针对当前连接的域名/IP 一键添加到「附加规则」（直连 / 代理 / 拒绝）。
- [x] **DNS 实时排查工具**：接入 `ClashAPIClient.queryDNS:qType:` 与 `explainDNS:qType:probe:`，输入域名即可查看 DNS 解析结果、上游服务器与策略解释。
- [x] **日志体验增强**：开放内核日志级别动态切换（`debug` / `info` / `warning` / `error` / `silent`），支持暂停滚动与按标签过滤。
- [x] **网络质量与 NAT(STUN) 检测工具**：接入 SDK 内置的 `ClashNetworkQualityTest`（Apple RPM / 带宽测速）与 `ClashSTUNTest`（NAT 映射与过滤类型检测），作为诊断工具箱页面。

---

## P3：iOS 生态体验、数据流转与扩展能力

### 9. 交互式小组件与控制中心开关
- [x] **AppIntents 交互式小组件**：升级 `LuckyClashWidget/VPNStatusWidget.swift`，支持在主屏幕/锁屏小组件一键启停 VPN 与显示当前策略组/节点。
- [x] **iOS 18 控制中心开关（ControlWidget）**：新增 `ControlWidgetToggle`（对齐 FlClash Android 的 Quick Settings Tile），支持从控制中心一键连接/断开 VPN。
- [x] **快捷指令（Shortcuts）集成**：提供连接、断开、切换分流模式、切换策略组节点的 AppIntents，支持 iOS 自动化场景（如连接指定 Wi-Fi / 打开特定 App 时自动切换模式）。

### 10. 备份与恢复、自定义配置与多语言主题
- [x] **备份与恢复**：支持将配置列表、覆写规则、策略组选择与偏好设置打包导出/导入（本地文件、WebDAV、iCloud Drive），支持加密备份保护节点凭据。
- [x] **自定义配置构建器**：支持脱离单一订阅，自由聚合多个订阅/手动节点、可视化编排策略组与规则集（对齐 FlClash `views/profiles/custom/`）。
- [x] **多语言与主题外观**：引入 String Catalog (`Localizable.xcstrings`) 替换硬编码中文，支持中英文切换与跟随系统/浅色/深色外观、自定义强调色。

---

## 建议迭代路线

1. ~~**Milestone 1（稳底座 + 顺手度）**：完成 **#1 内存护栏与休眠恢复** + **#2 解除运行中锁定与配置热重载**。~~（已完成）
2. ~~**Milestone 2（策略与节点核心对齐）**：完成 **#3 多策略组独立选择与实时同步** + **#4 节点搜索/排序/Providers 管理**。~~（已完成）
3. ~~**Milestone 3（配置覆写与 iOS 原生按需连接）**：完成 **#5 DNS/规则覆写与规则测试** + **#6 按需连接（SSID 排除）与局域网共享**。~~（已完成）
4. ~~**Milestone 4（仪表盘与高级诊断）**：完成 **#7 仪表盘卡片与服务检测** + **#8 请求历史/DNS 诊断/STUN** + **#9 控制中心与交互式小组件**。~~（已完成）
5. ~~**Milestone 5（数据同步与生态完善）**：完成 **#10 备份恢复、自定义配置与国际化**。~~（已完成）
