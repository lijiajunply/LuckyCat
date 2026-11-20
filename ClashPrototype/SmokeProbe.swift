import Clash
import Darwin
import Foundation

@main
enum SmokeProbe {
    enum Failure: Error {
        case yamlConversion
        case nodeValidationResponse
        case validNodeRejected(String)
        case invalidKeyAccepted
        case packetRoundTrip
    }

    static func main() {
        do {
            try verifyYAML()
            try verifyPacketBridge()
        } catch {
            FileHandle.standardError.write(Data("Clash probe failed: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func verifyYAML() throws {
        let yaml = """
        proxies:
          - name: controlled-peer
            type: wireguard
            server: 192.0.2.40
            port: 51820
            ip: 10.77.0.2
            ipv6: "fd00:77::2"
            private-key: "\(Data(repeating: 1, count: 32).base64EncodedString())"
            public-key: "\(Data(repeating: 2, count: 32).base64EncodedString())"
            udp: true
        rules:
          - MATCH,controlled-peer
        """

        var error: NSError?
        guard let output = ClashYamlToJSON(yaml, &error),
              let document = try JSONSerialization.jsonObject(with: Data(output.value.utf8)) as? [String: Any],
              let nodes = document["proxies"] as? [[String: Any]],
              nodes.count == 1, var node = nodes.first,
              node["name"] as? String == "controlled-peer",
              document["rules"] as? [String] == ["MATCH,controlled-peer"],
              ClashYamlToJSON("[invalid", nil) == nil else {
            throw Failure.yamlConversion
        }

        let valid = try validate(node)
        guard valid.ok else { throw Failure.validNodeRejected(valid.message ?? "No reason returned") }
        node["private-key"] = "invalid"
        guard try !validate(node).ok else { throw Failure.invalidKeyAccepted }
        print("Clash SDK parsed YAML and checked a WireGuard node and invalid key")
    }

    private struct NodeVerdict: Decodable {
        let ok: Bool
        let message: String?
    }

    private static func validate(_ node: [String: Any]) throws -> NodeVerdict {
        let json = try JSONSerialization.data(withJSONObject: node)
        var error: NSError?
        guard let result = ClashValidateItemForIOS("proxy", String(decoding: json, as: UTF8.self), "{}", &error) else {
            if let error { throw error }
            throw Failure.nodeValidationResponse
        }
        return try JSONDecoder().decode(NodeVerdict.self, from: Data(result.value.utf8))
    }

    private static func verifyPacketBridge() throws {
        let packets: [(Data, Int32)] = [
            (Data([0x45, 0, 0, 20] + Array(repeating: 0, count: 16)), AF_INET),
            (Data([0x60] + Array(repeating: 0, count: 39)), AF_INET6)
        ]
        let flow = ProbePacketFlow(packets)
        let bridge = PacketFlowBridge(packetFlow: flow, onFailure: { _ in })
        let descriptor = try bridge.start()
        defer { bridge.stop() }

        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        for (packet, family) in packets {
            guard poll(&pollDescriptor, 1, 2_000) == 1 else { throw Failure.packetRoundTrip }
            var bytes = [UInt8](repeating: 0, count: 128)
            let count = bytes.withUnsafeMutableBytes { Darwin.recv(descriptor, $0.baseAddress, $0.count, 0) }
            var networkFamily = family.bigEndian
            let expected = withUnsafeBytes(of: &networkFamily) { Data($0) } + packet
            guard count == expected.count, Data(bytes.prefix(count)) == expected else {
                throw Failure.packetRoundTrip
            }
            let sent = expected.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) }
            guard sent == count else { throw Failure.packetRoundTrip }
        }

        guard flow.waitForPackets() else { throw Failure.packetRoundTrip }
        print("Clash Adapter returned IPv4 and IPv6 packets through its socket pair")
    }
}

private final class ProbePacketFlow: PacketFlowIO {
    private let expected: [(Data, Int32)]
    private let arrived = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var sent = false
    private var returned: [(Data, Int32)] = []

    init(_ packets: [(Data, Int32)]) {
        expected = packets
    }

    func readPackets(completionHandler: @escaping @Sendable ([Data], [NSNumber]) -> Void) {
        lock.lock()
        let shouldSend = !sent
        sent = true
        lock.unlock()
        if shouldSend {
            completionHandler(expected.map(\.0), expected.map { NSNumber(value: $0.1) })
        }
    }

    func writePackets(_ packets: [Data], withProtocols protocols: [NSNumber]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        returned.append(contentsOf: zip(packets, protocols.map(\.int32Value)))
        if returned.count >= expected.count { arrived.signal() }
        return true
    }

    func waitForPackets() -> Bool {
        guard arrived.wait(timeout: .now() + .seconds(2)) == .success else { return false }
        lock.lock()
        defer { lock.unlock() }
        return returned.elementsEqual(expected, by: ==)
    }
}
