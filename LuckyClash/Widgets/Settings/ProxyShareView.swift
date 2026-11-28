import SwiftUI
import NetworkExtension
import Darwin

struct ProxyShareView: View {
    let vpn: PrototypeVPN
    @State private var port = 7890
    @State private var username = ""
    @State private var password = ""
    @State private var status: ProxyShareStatus?
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                if let status, status.enabled {
                    LabeledContent("状态", value: "共享中")
                    LabeledContent("端口", value: "\(status.port)")
                    LabeledContent("协议", value: status.protocols.joined(separator: " / "))
                    ForEach(localAddresses(), id: \.self) { address in
                        LabeledContent("局域网地址", value: address)
                    }
                    Button("停止共享", role: .destructive) { Task { await stop() } }
                        .disabled(busy)
                } else {
                    TextField("端口", value: $port, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                    TextField("用户名", text: $username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("密码", text: $password)
                    if !username.isEmpty && !ProxyShareCredentials.validUsername(username) {
                        Text("用户名不能包含冒号、控制字符或首尾空白，长度最多 255 字节。")
                            .font(.footnote).foregroundStyle(.red)
                    }
                    if !password.isEmpty && !ProxyShareCredentials.validPassword(password) {
                        Text("密码不能包含控制字符，长度最多 255 字节。")
                            .font(.footnote).foregroundStyle(.red)
                    }
                    Button("启动共享") { Task { await start() } }
                        .disabled(busy || vpn.status != .connected || !(1024...65535).contains(port)
                                  || !ProxyShareCredentials.validUsername(username) || !ProxyShareCredentials.validPassword(password))
                }
            } footer: {
                Text("共享提供 HTTP 和 SOCKS 代理，当前内核要求用户名和密码。")
            }
            if vpn.status != .connected { Text("连接 VPN 后可使用共享。").foregroundStyle(.secondary) }
            if let message { Text(message).foregroundStyle(.secondary) }
        }
        .navigationTitle("局域网共享")
        .task(id: vpn.status) { await refresh() }
    }

    private func refresh() async {
        guard vpn.status == .connected else { status = nil; return }
        do { status = try await vpn.live.proxyShareStatus(); message = nil }
        catch { message = error.localizedDescription }
    }

    private func start() async {
        busy = true
        defer { busy = false }
        do {
            try await vpn.live.startProxyShare(port: port, username: username, password: password)
            password = ""
            await refresh()
        } catch { message = error.localizedDescription }
    }

    private func stop() async {
        busy = true
        defer { busy = false }
        do { try await vpn.live.stopProxyShare(); await refresh() }
        catch { message = error.localizedDescription }
    }

    private func localAddresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        return sequence(first: first, next: { $0.pointee.ifa_next }).compactMap { pointer in
            let item = pointer.pointee
            guard let address = item.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: item.ifa_name).hasPrefix("en"),
                  item.ifa_flags & UInt32(IFF_UP) != 0 else { return nil }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host,
                              socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
            return String(cString: host)
        }.sorted()
    }
}
