import Foundation
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private let lifecycle = DispatchQueue(label: "com.luckyfish.LuckyClash.PacketTunnel")
    private var clash: ClashEngine?
    private var startCompletion: ((Error?) -> Void)?

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        lifecycle.async {
            guard self.startCompletion == nil else {
                completionHandler(PrototypeError.engineStartup)
                return
            }
            guard let selection = self.clashSelection() else {
                completionHandler(PrototypeError.missingConfiguration)
                return
            }
            let engine = ClashEngine(provider: self)
            self.clash = engine
            self.startCompletion = completionHandler
            engine.start(
                configurationText: selection.configuration,
                selectedGroup: selection.group,
                selectedNode: selection.node,
                mode: selection.mode
            ) { error in
                self.lifecycle.async {
                    if error != nil {
                        self.clash = nil
                    }
                    self.finishStart(error)
                }
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        lifecycle.async {
            let finish = {
                self.finishStart(PrototypeError.startCancelled)
                completionHandler()
            }
            if let clash = self.clash {
                self.clash = nil
                clash.stop(completion: finish)
            } else {
                finish()
            }
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard messageData.count <= 256,
              let request = try? JSONDecoder().decode(TunnelStatusMessage.Request.self, from: messageData),
              request.version == TunnelStatusMessage.version else {
            completionHandler?(nil)
            return
        }
        lifecycle.async {
            guard let clash = self.clash else {
                completionHandler?(nil)
                return
            }
            let traffic = clash.traffic()
            let reply = TunnelStatusMessage.Reply(
                version: TunnelStatusMessage.version,
                id: request.id,
                ready: clash.isReady(),
                bytesIn: traffic?.received,
                bytesOut: traffic?.sent
            )
            completionHandler?(try? JSONEncoder().encode(reply))
        }
    }

    private struct ClashSelection {
        let configuration: String
        let group: String?
        let node: String?
        let mode: TrafficMode?
    }

    private func clashSelection() -> ClashSelection? {
        guard let provider = protocolConfiguration as? NETunnelProviderProtocol,
              let values = provider.providerConfiguration,
              values[ClashTunnelStore.engineKey] as? String == ClashTunnelStore.engineClash,
              let profileID = (values[ClashTunnelStore.profileKey] as? String).flatMap(UUID.init(uuidString:)),
              let revision = (values[ClashTunnelStore.revisionKey] as? String).flatMap(UUID.init(uuidString:)),
              let stored = try? ClashTunnelStore.load(profileID: profileID, revision: revision) else {
            return nil
        }
        let mode = (values[ClashTunnelStore.modeKey] as? String)
            .flatMap(TrafficMode.init(rawValue:))
        return ClashSelection(
            configuration: mode.map { ClashModeOverride.apply($0, to: stored) } ?? stored,
            group: values[ClashTunnelStore.selectedGroupKey] as? String,
            node: values[ClashTunnelStore.selectedNodeKey] as? String,
            mode: mode
        )
    }

    private func finishStart(_ error: Error?) {
        guard let completion = startCompletion else { return }
        startCompletion = nil
        completion(error)
    }
}
