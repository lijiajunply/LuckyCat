import Foundation
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private let lifecycle = DispatchQueue(label: "com.luckyfish.LuckyClash.PacketTunnel")
    private var clash: ClashEngine?
    private var startCompletion: ((Error?) -> Void)?
    private var runningProfileID: UUID?

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        lifecycle.async {
            guard self.startCompletion == nil else {
                completionHandler(PrototypeError.engineStartup)
                return
            }
            guard let selection = self.clashSelection(),
                  let configuration = try? selection.configuration() else {
                VPNWidgetStatus.disconnected.publish()
                completionHandler(PrototypeError.missingConfiguration)
                return
            }
            let engine = ClashEngine(provider: self)
            self.clash = engine
            self.startCompletion = completionHandler
            engine.start(
                configurationText: configuration,
                groupSelections: selection.groupSelections,
                selectedNode: selection.node,
                mode: selection.mode
            ) { error in
                self.lifecycle.async {
                    guard self.clash === engine else { return }
                    if error != nil {
                        self.clash = nil
                    } else {
                        self.runningProfileID = selection.profileID
                    }
                    self.finishStart(error)
                    (error == nil ? VPNWidgetStatus.connected : .disconnected).publish()
                }
            }
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        lifecycle.async {
            if let clash = self.clash {
                clash.sleep(completion: completionHandler)
            } else {
                completionHandler()
            }
        }
    }

    override func wake() {
        lifecycle.async { self.clash?.wake() }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        lifecycle.async {
            self.runningProfileID = nil
            let finish = {
                self.lifecycle.async {
                    self.finishStart(PrototypeError.startCancelled)
                    VPNWidgetStatus.disconnected.publish()
                    completionHandler()
                }
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
        if messageData.count <= 256,
           let request = try? JSONDecoder().decode(TunnelMemoryMessage.Request.self, from: messageData),
           request.version == TunnelStatusMessage.version, request.freeMemory {
            lifecycle.async {
                guard let clash = self.clash, self.startCompletion == nil else {
                    completionHandler?(nil)
                    return
                }
                clash.freeMemory {
                    let reply = TunnelMemoryMessage.Reply(version: request.version, id: request.id)
                    completionHandler?(try? JSONEncoder().encode(reply))
                }
            }
            return
        }
        if messageData.count <= TunnelReloadMessage.maximumBytes,
           let request = try? JSONDecoder().decode(TunnelReloadMessage.Request.self, from: messageData) {
            guard request.version == TunnelReloadMessage.version else {
                completionHandler?(nil)
                return
            }
            lifecycle.async {
                guard let clash = self.clash, self.startCompletion == nil else {
                    completionHandler?(nil)
                    return
                }
                clash.reload(request) { reply in
                    self.lifecycle.async {
                        guard self.clash === clash else {
                            completionHandler?(nil)
                            return
                        }
                        if reply.outcome == .applied { self.runningProfileID = request.selection.profileID }
                        completionHandler?(try? JSONEncoder().encode(reply))
                    }
                }
            }
            return
        }
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
            let reply = TunnelStatusMessage.Reply(
                version: TunnelStatusMessage.version,
                id: request.id,
                ready: clash.isReady(),
                bytesIn: nil,
                bytesOut: nil,
                runningProfileID: self.runningProfileID
            )
            completionHandler?(try? JSONEncoder().encode(reply))
        }
    }

    private func clashSelection() -> TunnelReloadMessage.Selection? {
        guard let provider = protocolConfiguration as? NETunnelProviderProtocol,
              let values = provider.providerConfiguration,
              values[ClashTunnelStore.engineKey] as? String == ClashTunnelStore.engineClash,
              let profileID = (values[ClashTunnelStore.profileKey] as? String).flatMap(UUID.init(uuidString:)),
              let revision = (values[ClashTunnelStore.revisionKey] as? String).flatMap(UUID.init(uuidString:)) else {
            return nil
        }
        let mode = (values[ClashTunnelStore.modeKey] as? String)
            .flatMap(TrafficMode.init(rawValue:))
        return TunnelReloadMessage.Selection(
            profileID: profileID,
            revision: revision,
            group: values[ClashTunnelStore.selectedGroupKey] as? String,
            node: values[ClashTunnelStore.selectedNodeKey] as? String,
            mode: mode,
            selections: values[ClashTunnelStore.selectionsKey] as? [String: String]
        )
    }

    private func finishStart(_ error: Error?) {
        guard let completion = startCompletion else { return }
        startCompletion = nil
        completion(error)
    }
}
