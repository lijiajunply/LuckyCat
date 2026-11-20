# ClashAdapter

`Sources/ClashAdapter/PacketFlowBridge.swift` is vendored from
[ProjectClash/Clash-Adapter](https://github.com/ProjectClash/Clash-Adapter) at
commit `9ba5c2724b68c753d57496c1036f4dfb1587e482`. It moves IP packets between
`NEPacketTunnelFlow` and the descriptor that the Clash core reads, including the
four-byte address-family header the core expects.

The source is licensed GPL-3.0; see `LICENSE`. The same license covers the
Clash core framework that `ClashPrototype/build.sh` produces. Check the
distribution requirements in [docs/LuckyCat-Clash-Prototype.md](../docs/LuckyCat-Clash-Prototype.md)
before shipping a build that includes these components.

The upstream revision is pinned by `ClashPrototype/sources.sha256`. Do not edit
the vendored file locally; update the pinned revision and the checksum together.
