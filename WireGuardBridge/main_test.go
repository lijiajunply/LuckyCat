package main

import (
	"bytes"
	"crypto/ecdh"
	"crypto/rand"
	"fmt"
	"net/netip"
	"strings"
	"testing"
	"time"

	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun/tuntest"
)

func TestPacketFlowExchangesIPv4AndIPv6WithWireGuardPeer(t *testing.T) {
	serverKey := newKey(t)
	clientKey := newKey(t)
	remoteFlow := tuntest.NewChannelTUN()
	remote := device.NewDevice(remoteFlow.TUN(), conn.NewDefaultBind(), device.NewLogger(device.LogLevelSilent, ""))
	t.Cleanup(remote.Close)

	if err := remote.IpcSet(fmt.Sprintf(
		"private_key=%x\npublic_key=%x\nallowed_ip=192.0.2.2/32\nallowed_ip=2001:db8::2/128\n",
		serverKey.Bytes(), clientKey.PublicKey().Bytes(),
	)); err != nil {
		t.Fatal("configure remote peer:", err)
	}
	if err := remote.Up(); err != nil {
		t.Fatal("start remote peer:", err)
	}
	status, err := remote.IpcGet()
	if err != nil {
		t.Fatal("read peer status:", err)
	}
	var port string
	for _, line := range strings.Split(status, "\n") {
		if value, ok := strings.CutPrefix(line, "listen_port="); ok {
			port = value
			break
		}
	}
	if port == "" {
		t.Fatal("remote peer did not bind a UDP port")
	}

	inbound := make(chan []byte, 2)
	local, err := startTunnel(fmt.Sprintf(
		"private_key=%x\npublic_key=%x\nendpoint=127.0.0.1:%s\npersistent_keepalive_interval=10\nallowed_ip=0.0.0.0/0\nallowed_ip=::/0\n",
		clientKey.Bytes(), serverKey.PublicKey().Bytes(), port,
	), 1280, func(packet []byte) {
		inbound <- bytes.Clone(packet)
	})
	if err != nil {
		t.Fatal("start packet flow device:", err)
	}
	t.Cleanup(local.device.Close)

	for _, pair := range [][2]string{{"192.0.2.2", "192.0.2.1"}, {"2001:db8::2", "2001:db8::1"}} {
		client := netip.MustParseAddr(pair[0])
		server := netip.MustParseAddr(pair[1])
		outbound := ipPacket(client, server)
		select {
		case local.flow.packets <- outbound:
		case <-time.After(5 * time.Second):
			t.Fatal("could not enqueue packet")
		}
		expectPacket(t, remoteFlow.Inbound, outbound)

		reply := ipPacket(server, client)
		select {
		case remoteFlow.Outbound <- reply:
		case <-time.After(5 * time.Second):
			t.Fatal("could not enqueue reply")
		}
		expectPacket(t, inbound, reply)
	}
}

func newKey(t *testing.T) *ecdh.PrivateKey {
	t.Helper()
	key, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return key
}

func expectPacket(t *testing.T, received <-chan []byte, expected []byte) {
	t.Helper()
	select {
	case packet := <-received:
		if !bytes.Equal(packet, expected) {
			t.Fatalf("unexpected IP packet: %x, expected %x", packet, expected)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for IP packet")
	}
}

func ipPacket(source, destination netip.Addr) []byte {
	if source.Is4() {
		packet := make([]byte, 20)
		packet[0], packet[3], packet[8], packet[9] = 0x45, 20, 64, 59
		copy(packet[12:16], source.AsSlice())
		copy(packet[16:20], destination.AsSlice())
		return packet
	}
	packet := make([]byte, 40)
	packet[0], packet[6], packet[7] = 0x60, 59, 64
	copy(packet[8:24], source.AsSlice())
	copy(packet[24:40], destination.AsSlice())
	return packet
}
