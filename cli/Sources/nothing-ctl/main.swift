import Foundation
import IOBluetooth

// MARK: - Entry point

let allArgs = CommandLine.arguments.dropFirst()
let verbose = allArgs.contains("--verbose")
let args = allArgs.filter { $0 != "--verbose" }

guard let subcommand = args.first else {
    fputs("Usage: nothing-ctl <anc|battery|debug> [--verbose]\n", stderr)
    exit(1)
}

switch subcommand {
case "anc":
    guard let modeArg = args.dropFirst().first, let mode = ANCMode(name: modeArg) else {
        fputs("Usage: nothing-ctl anc <off|transparency|high|mid|low|adaptive>\n", stderr)
        exit(1)
    }
    runANC(mode: mode)

case "battery":
    runBattery()

case "debug":
    runDebug()

default:
    fputs("Unknown command: \(subcommand)\n", stderr)
    fputs("Usage: nothing-ctl <anc|battery|debug> [--verbose]\n", stderr)
    exit(1)
}

// MARK: - ANC command

func runANC(mode: ANCMode) {
    let packet = PacketBuilder.ancPacket(mode: mode)

    for attempt in 1...5 {
        let bt = BluetoothManager()
        do {
            try runWithRunLoop(timeout: 8) {
                try bt.connect()
                if verbose { fputs("Connected (attempt \(attempt))\n", stderr) }

                if verbose { fputs("Sending: \(hex(packet))\n", stderr) }
                try bt.send(packet)
                let responses = bt.drain(timeout: 1.5)
                if verbose {
                    if responses.isEmpty {
                        fputs("Response: (none)\n", stderr)
                    } else {
                        for (i, r) in responses.enumerated() {
                            fputs("Response[\(i)]: \(hex(r))\n", stderr)
                        }
                    }
                }

                if verbose && !responses.contains(where: { mode.isConfirmedBy($0) }) {
                    fputs("Warning: no mode confirmation received\n", stderr)
                }

                bt.disconnect()
            }
            print(mode.displayName)
            exit(0)
        } catch BluetoothManager.Error.noRFCOMMService {
            fputs("Nothing Ear 2 found but no SPP service in SDP records. Try reconnecting.\n", stderr)
            exit(2)
        } catch {
            // noDeviceFound, connectionFailed, timeout — all transient; retry
            if attempt < 5 {
                if verbose { fputs("Connect failed (attempt \(attempt)): \(error) — retrying...\n", stderr) }
                Thread.sleep(forTimeInterval: 0.5)
            } else {
                if case BluetoothManager.Error.noDeviceFound = error {
                    fputs("Nothing Ear 2 not connected. Put the earbuds in your ears and try again.\n", stderr)
                    exit(2)
                }
                fputs("Error: \(error)\n", stderr)
                exit(1)
            }
        }
    }
}

// MARK: - Battery command

func runBattery() {
    let packet = PacketBuilder.build(command: .getBattery)

    for attempt in 1...5 {
        let bt = BluetoothManager()
        do {
            try runWithRunLoop(timeout: 8) {
                try bt.connect()
                if verbose { fputs("Connected (attempt \(attempt))\n", stderr) }

                if verbose { fputs("Sending: \(hex(packet))\n", stderr) }
                try bt.send(packet)
                let responses = bt.drain(timeout: 1.0)
                if verbose {
                    for (i, r) in responses.enumerated() {
                        fputs("Response[\(i)]: \(hex(r))\n", stderr)
                    }
                }

                bt.disconnect()

                guard let status = BatteryStatus.parse(from: responses) else {
                    fputs("Could not parse battery response.\n", stderr)
                    exit(1)
                }

                var parts: [String] = []
                if let l = status.left  { parts.append("L  \(l.description)") }
                if let r = status.right { parts.append("R  \(r.description)") }
                if let c = status.case_ { parts.append("⬡  \(c.description)") }
                print(parts.joined(separator: "\n"))
                exit(0)
            }
        } catch BluetoothManager.Error.noRFCOMMService {
            fputs("Nothing Ear 2 found but no SPP service. Try reconnecting.\n", stderr)
            exit(2)
        } catch {
            if attempt < 5 {
                if verbose { fputs("Connect failed (attempt \(attempt)): \(error) — retrying...\n", stderr) }
                Thread.sleep(forTimeInterval: 0.5)
            } else {
                if case BluetoothManager.Error.noDeviceFound = error {
                    fputs("Nothing Ear 2 not connected. Put the earbuds in your ears and try again.\n", stderr)
                    exit(2)
                }
                fputs("Error: \(error)\n", stderr)
                exit(1)
            }
        }
    }
}

// MARK: - Debug command

func runDebug() {
    let paired = IOBluetoothDevice.pairedDevices() ?? []
    print("Paired Bluetooth devices (\(paired.count)):")
    for obj in paired {
        guard let dev = obj as? IOBluetoothDevice else { continue }
        let name = dev.name ?? "(unknown)"
        let addr = dev.addressString ?? "??"
        let cls  = dev.classOfDevice
        let connected = dev.isConnected() ? "connected" : "not connected"
        print("  \(name)  addr=\(addr)  class=\(cls)  \(connected)")

        if let services = dev.services as? [IOBluetoothSDPServiceRecord] {
            for svc in services {
                let svcName = svc.getServiceName() ?? "(unnamed)"
                var channelID: BluetoothRFCOMMChannelID = 0
                let hasRFCOMM = svc.getRFCOMMChannelID(&channelID) == kIOReturnSuccess
                let channelStr = hasRFCOMM ? "  rfcomm-ch=\(channelID)" : ""

                // Collect all UUIDs from this service record
                var uuids: [String] = []
                if let attrs = svc.attributes as? [NSNumber: IOBluetoothSDPDataElement] {
                    // Attribute 0x0001 = ServiceClassIDList, 0x0004 = ProtocolDescriptorList
                    for (_, element) in attrs {
                        if let uuid = element.getUUIDValue() {
                            uuids.append(uuid.description)
                        }
                    }
                }
                let uuidStr = uuids.isEmpty ? "" : "  uuids=[\(uuids.joined(separator: ", "))]"
                print("    SDP: \(svcName)\(channelStr)\(uuidStr)")
            }
        }
    }
    exit(0)
}

// MARK: - Helpers

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
}

// MARK: - RunLoop helper
// IOBluetooth delegate callbacks need a running RunLoop.
// We run the body on a background thread while spinning the main RunLoop.

func runWithRunLoop(timeout: TimeInterval, body: @escaping () throws -> Void) throws {
    var thrownError: Error?
    let done = DispatchSemaphore(value: 0)

    DispatchQueue.global().async {
        do {
            try body()
        } catch {
            thrownError = error
        }
        done.signal()
    }

    let deadline = Date().addingTimeInterval(timeout)
    while done.wait(timeout: .now()) == .timedOut {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        if Date() > deadline {
            fputs("RunLoop watchdog timeout\n", stderr)
            exit(3)
        }
    }

    if let err = thrownError {
        throw err
    }
}
