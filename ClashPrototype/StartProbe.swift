import Clash
import Darwin
import Foundation

@main
enum StartProbe {
    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(Data("probe failed: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("lcclash-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let options = ClashSetupOptions()
        options.basePath = root.path
        options.workingPath = root.appendingPathComponent("working").path
        options.tempPath = root.appendingPathComponent("temp").path
        options.runtimeProfile = ClashRuntimeProfileIOSPacketTunnel
        options.timeZone = TimeZone.current.identifier
        options.systemDNSServerLines = ClashSystemResolverLines()
        options.logMaxLines = 200
        var error: NSError?
        guard ClashSetup(options, &error) else { throw error ?? NSError(domain: "setup", code: 0) }

        let platform = Platform()
        guard let service = ClashNewService(platform, &error) else { throw error ?? NSError(domain: "service", code: 0) }

        let yaml = """
        mode: rule
        proxies:
          - name: Test
            type: ss
            server: 127.0.0.1
            port: 9
            cipher: aes-128-gcm
            password: test
        rules:
          - MATCH,Test
        dns:
          enable: true
          nameserver: [223.5.5.5]
        """
        let outcome = service.startClassified(yaml)
        print("outcome class=\(outcome?.errorClass ?? "nil") message=\(outcome?.message ?? "nil")")
        if let classValue = outcome?.errorClass, !classValue.isEmpty, classValue != ClashCoreOutcomeCommitted {
            exit(2)
        }
        print("status=\(service.status()) traffic=\(ClashTrafficJSON())")
        try? service.close()
        print("closed")
    }
}

final class Platform: NSObject, ClashPlatformInterfaceProtocol {
    private var fds: [Int32] = []
    func writeLog(_ message: String?) { if let message { print("[core] \(message)") } }
    func tunFailed(_ reason: String?) { print("[core] tunFailed: \(reason ?? "")") }
    func openTun(_ options: (any ClashTunOptionsProtocol)?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        guard let options, let ret0_ else { throw NSError(domain: "openTun", code: 0) }
        var pair = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &pair) == 0 else { throw NSError(domain: "socketpair", code: Int(errno)) }
        fds = pair
        let dns = try options.getDNSServerAddress()
        print("openTun mtu=\(options.getMTU()) dns=\(dns.value) fd=\(pair[0])")
        ret0_.pointee = pair[0]
    }
    func usePlatformAutoDetectControl() -> Bool { true }
    func autoDetectControl(_ fd: Int32) throws {}
    func startDefaultInterfaceMonitor(_ listener: (any ClashInterfaceUpdateListenerProtocol)?) throws {
        listener?.updateDefaultInterface("en0", interfaceIndex: 4, isExpensive: false, isConstrained: false, supportsIPv4: true, supportsIPv6: true)
    }
    func closeDefaultInterfaceMonitor(_ listener: (any ClashInterfaceUpdateListenerProtocol)?) throws {}
    func getInterfaces() throws -> any ClashNetworkInterfaceIteratorProtocol { EmptyIterator() }
    func underNetworkExtension() -> Bool { true }
}

final class EmptyIterator: NSObject, ClashNetworkInterfaceIteratorProtocol {
    func hasNext() -> Bool { false }
    func len() -> Int32 { 0 }
    func next() -> ClashNetworkInterface? { nil }
}
