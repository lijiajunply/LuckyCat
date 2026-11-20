package main

/*
#include "Bridge.h"

static inline void writePacket(LCWireGuardWriter writer, uintptr_t context, uint8_t *packet, int length) {
    writer(context, packet, length);
}
*/
import "C"

import (
	"os"
	"runtime/cgo"
	"strconv"
	"strings"
	"unsafe"

	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun"
)

const queueCapacity = 128

// packetFlowDevice exchanges unframed IP packets with NEPacketTunnelFlow.
type packetFlowDevice struct {
	mtu     int
	packets chan []byte
	done    chan struct{}
	events  chan tun.Event
	write   func([]byte)
}

func (flow *packetFlowDevice) File() *os.File           { return nil }
func (flow *packetFlowDevice) MTU() (int, error)        { return flow.mtu, nil }
func (flow *packetFlowDevice) Name() (string, error)    { return "LuckyCat", nil }
func (flow *packetFlowDevice) Events() <-chan tun.Event { return flow.events }
func (flow *packetFlowDevice) BatchSize() int           { return 1 }

func (flow *packetFlowDevice) Read(buffers [][]byte, sizes []int, offset int) (int, error) {
	select {
	case <-flow.done:
		return 0, os.ErrClosed
	case packet := <-flow.packets:
		sizes[0] = copy(buffers[0][offset:], packet)
		return 1, nil
	}
}

func (flow *packetFlowDevice) Write(buffers [][]byte, offset int) (int, error) {
	for _, packet := range buffers {
		flow.write(packet[offset:])
	}
	return len(buffers), nil
}

func (flow *packetFlowDevice) Close() error {
	close(flow.done)
	close(flow.events)
	return nil
}

type tunnel struct {
	device *device.Device
	flow   *packetFlowDevice
}

func startTunnel(configuration string, mtu int, write func([]byte)) (tunnel, error) {
	flow := &packetFlowDevice{
		mtu:     mtu,
		packets: make(chan []byte, queueCapacity),
		done:    make(chan struct{}),
		events:  make(chan tun.Event),
		write:   write,
	}
	engine := device.NewDevice(flow, conn.NewDefaultBind(), device.NewLogger(device.LogLevelSilent, ""))
	if err := engine.IpcSet(configuration); err != nil {
		engine.Close()
		return tunnel{}, err
	}
	if err := engine.Up(); err != nil {
		engine.Close()
		return tunnel{}, err
	}
	return tunnel{device: engine, flow: flow}, nil
}

//export LCWireGuardStart
func LCWireGuardStart(configuration *C.char, mtu C.int, context C.uintptr_t, writer C.LCWireGuardWriter) C.uintptr_t {
	running, err := startTunnel(C.GoString(configuration), int(mtu), func(packet []byte) {
		if len(packet) > 0 {
			C.writePacket(writer, context, (*C.uint8_t)(unsafe.Pointer(&packet[0])), C.int(len(packet)))
		}
	})
	if err != nil {
		return 0
	}
	return C.uintptr_t(cgo.NewHandle(running))
}

//export LCWireGuardStop
func LCWireGuardStop(handle C.uintptr_t) {
	reference := cgo.Handle(handle)
	reference.Value().(tunnel).device.Close()
	reference.Delete()
}

//export LCWireGuardEnqueue
func LCWireGuardEnqueue(handle C.uintptr_t, packet *C.uint8_t, length C.int) C.int {
	flow := cgo.Handle(handle).Value().(tunnel).flow
	if length <= 0 || int(length) > flow.mtu || len(flow.packets) == cap(flow.packets) {
		return 0
	}
	select {
	case flow.packets <- C.GoBytes(unsafe.Pointer(packet), length):
		return 1
	default:
		return 0
	}
}

//export LCWireGuardHasHandshake
func LCWireGuardHasHandshake(handle C.uintptr_t) C.int {
	engine := cgo.Handle(handle).Value().(tunnel).device
	status, err := engine.IpcGet()
	if err != nil {
		return 0
	}
	for _, line := range strings.Split(status, "\n") {
		if seconds, ok := strings.CutPrefix(line, "last_handshake_time_sec="); ok && seconds != "0" {
			return 1
		}
	}
	return 0
}

// LCWireGuardTraffic reports aggregated peer counters: bytes received from and sent to the peer.
//
//export LCWireGuardTraffic
func LCWireGuardTraffic(handle C.uintptr_t, received *C.uint64_t, sent *C.uint64_t) C.int {
	engine := cgo.Handle(handle).Value().(tunnel).device
	status, err := engine.IpcGet()
	if err != nil {
		return 0
	}
	var rxBytes, txBytes uint64
	for _, line := range strings.Split(status, "\n") {
		if value, ok := strings.CutPrefix(line, "rx_bytes="); ok {
			if parsed, err := strconv.ParseUint(value, 10, 64); err == nil {
				rxBytes += parsed
			}
		}
		if value, ok := strings.CutPrefix(line, "tx_bytes="); ok {
			if parsed, err := strconv.ParseUint(value, 10, 64); err == nil {
				txBytes += parsed
			}
		}
	}
	*received = C.uint64_t(rxBytes)
	*sent = C.uint64_t(txBytes)
	return 1
}

func main() {}
