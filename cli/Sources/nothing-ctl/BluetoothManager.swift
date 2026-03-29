import Foundation
import IOBluetooth

// Device class for Nothing headphones (Ear 1 & Ear 2 share this class).
// 0x240404 = Major class: Audio/Video, Minor: Headphones
private let nothingDeviceClass: Int = 0x240404

// NT Link UUID: the proprietary Nothing control SPP service.
// Earctl and ear-web both target this UUID (aeac4a03-dff5-498f-843a-34487cf133eb).
// On the user's Ear 2 this appears as an unnamed service on channel 15.
private let nothingNTLinkUUID = Data([
    0xae, 0xac, 0x4a, 0x03, 0xdf, 0xf5, 0x49, 0x8f,
    0x84, 0x3a, 0x34, 0x48, 0x7c, 0xf1, 0x33, 0xeb
])

// Fallback: match by SDP service name if UUID lookup fails.
private let sppServiceNames = ["spp1", "spp"]

final class BluetoothManager: NSObject {

    enum Error: Swift.Error {
        case noDeviceFound
        case noRFCOMMService
        case connectionFailed(String)
        case sendFailed(String)
        case timeout
    }

    private var rfcomm: IOBluetoothRFCOMMChannel?
    private var connectSemaphore = DispatchSemaphore(value: 0)
    private var connectError: Swift.Error?
    private var connectPending = false
    var onData: (([UInt8]) -> Void)?

    func findDevice() -> IOBluetoothDevice? {
        (IOBluetoothDevice.pairedDevices() ?? [])
            .compactMap { $0 as? IOBluetoothDevice }
            .first(where: { $0.classOfDevice == nothingDeviceClass })
    }

    // Discover the RFCOMM channel ID via SDP.
    // Priority: NT Link UUID → SPP service name → first available RFCOMM channel.
    func rfcommChannelID(for device: IOBluetoothDevice) -> BluetoothRFCOMMChannelID? {
        guard let services = device.services as? [IOBluetoothSDPServiceRecord] else {
            return nil
        }

        // 1. NT Link UUID (aeac4a03-dff5-498f-843a-34487cf133eb) — earctl/ear-web target
        for service in services {
            if serviceContainsUUID(service, uuid: nothingNTLinkUUID) {
                var channelID: BluetoothRFCOMMChannelID = 0
                if service.getRFCOMMChannelID(&channelID) == kIOReturnSuccess {
                    return channelID
                }
            }
        }

        // 2. Known SPP service names
        for service in services {
            let name = (service.getServiceName() ?? "").lowercased()
            if sppServiceNames.contains(name) {
                var channelID: BluetoothRFCOMMChannelID = 0
                if service.getRFCOMMChannelID(&channelID) == kIOReturnSuccess {
                    return channelID
                }
            }
        }

        // 3. First service with any RFCOMM channel
        for service in services {
            var channelID: BluetoothRFCOMMChannelID = 0
            if service.getRFCOMMChannelID(&channelID) == kIOReturnSuccess {
                return channelID
            }
        }

        return nil
    }

    private func serviceContainsUUID(_ service: IOBluetoothSDPServiceRecord, uuid target: Data) -> Bool {
        guard let attrs = service.attributes as? [NSNumber: IOBluetoothSDPDataElement] else {
            return false
        }
        for (_, element) in attrs {
            if let uuid = element.getUUIDValue(), Data(uuid) == target {
                return true
            }
        }
        return false
    }

    func connect() throws {
        guard let device = findDevice() else {
            throw Error.noDeviceFound
        }
        // SDP services are only populated when the device is actively connected.
        // If the list is empty the earbuds are likely in the case or asleep.
        guard let channelID = rfcommChannelID(for: device) else {
            throw device.isConnected() ? Error.noRFCOMMService : Error.noDeviceFound
        }

        var channel: IOBluetoothRFCOMMChannel? = nil
        let result = device.openRFCOMMChannelAsync(&channel, withChannelID: channelID, delegate: self)
        guard result == kIOReturnSuccess, let ch = channel else {
            throw Error.connectionFailed("openRFCOMMChannelAsync failed: \(result)")
        }
        rfcomm = ch
        connectPending = true

        // Wait for delegate confirmation (up to 5s)
        if connectSemaphore.wait(timeout: .now() + 5) == .timedOut {
            connectPending = false
            throw Error.timeout
        }
        connectPending = false
        if let err = connectError { throw err }
    }

    func send(_ bytes: [UInt8]) throws {
        guard let channel = rfcomm else {
            throw Error.sendFailed("not connected")
        }
        var mutable = bytes
        let result = channel.writeSync(&mutable, length: UInt16(mutable.count))
        guard result == kIOReturnSuccess else {
            throw Error.sendFailed("writeSync failed: \(result)")
        }
    }

    // Collect all packets that arrive within `window` seconds.
    // Waits up to `window` for the first packet, then at most `interPacket`
    // between subsequent packets — so we exit quickly once the device goes quiet.
    func drain(timeout window: TimeInterval, interPacket: TimeInterval = 0.05) -> [[UInt8]] {
        var packets: [[UInt8]] = []
        let sem = DispatchSemaphore(value: 0)
        onData = { packets.append($0); sem.signal() }
        defer { onData = nil }
        let deadline = DispatchTime.now() + window
        var next = deadline
        while sem.wait(timeout: next) == .success {
            next = min(deadline, .now() + interPacket)
        }
        return packets
    }

    func disconnect() {
        rfcomm?.close()
        rfcomm = nil
    }
}

extension BluetoothManager: IOBluetoothRFCOMMChannelDelegate {
    func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        connectError = error == kIOReturnSuccess ? nil : Error.connectionFailed("channel open failed: \(error)")
        connectSemaphore.signal()
    }

    func rfcommChannelData(
        _ rfcommChannel: IOBluetoothRFCOMMChannel!,
        data dataPointer: UnsafeMutableRawPointer!,
        length dataLength: Int
    ) {
        let bytes = Array(UnsafeBufferPointer(
            start: dataPointer.assumingMemoryBound(to: UInt8.self),
            count: dataLength
        ))
        onData?(bytes)
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        guard connectPending else { return }
        connectError = Error.connectionFailed("channel closed unexpectedly")
        connectSemaphore.signal()
    }
}
