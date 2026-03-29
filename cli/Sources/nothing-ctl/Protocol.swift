// CRC-16/ARC: init=0xFFFF, poly=0xA001 (bit-reversed CRC-16)
// Ported from the Nothing X macOS reference app.

enum ANCMode: UInt8 {
    case high         = 0x01
    case mid          = 0x02
    case low          = 0x03
    case adaptive     = 0x04
    case off          = 0x05
    case transparency = 0x07

    init?(name: String) {
        switch name.lowercased() {
        case "high":         self = .high
        case "mid":          self = .mid
        case "low":          self = .low
        case "adaptive":     self = .adaptive
        case "off":          self = .off
        case "transparency": self = .transparency
        default: return nil
        }
    }

    var displayName: String {
        switch self {
        case .high:         return "Noise Cancellation (High)"
        case .mid:          return "Noise Cancellation (Mid)"
        case .low:          return "Noise Cancellation (Low)"
        case .adaptive:     return "Adaptive Noise Cancellation"
        case .off:          return "Off"
        case .transparency: return "Transparency"
        }
    }

    // ANC status response: LE cmd = 0xE003, mode byte at index 9
    func isConfirmedBy(_ packet: [UInt8]) -> Bool {
        guard packet.count >= 10 else { return false }
        let cmd = (UInt16(packet[4]) << 8) | UInt16(packet[3])
        return cmd == 0xE003 && packet[9] == rawValue
    }
}

enum Command: UInt16 {
    case setANC      = 0x0FF0
    case getANC      = 0x1EC0
    case getBattery  = 0x07C0
    case getFirmware = 0x42C0
}

// MARK: - Battery

struct BatteryLevel {
    let percent: UInt8
    let charging: Bool

    var description: String {
        charging ? "\(percent)% ⚡" : "\(percent)%"
    }
}

struct BatteryStatus {
    var left:  BatteryLevel?
    var right: BatteryLevel?
    var case_: BatteryLevel?

    private static let batteryPrimary:   UInt16 = 0xE001
    private static let batterySecondary: UInt16 = 0x4007

    static func parse(from packets: [[UInt8]]) -> BatteryStatus? {
        for packet in packets {
            guard packet.count >= 8 else { continue }
            // Command bytes are little-endian in the Nothing protocol
            let cmd = (UInt16(packet[4]) << 8) | UInt16(packet[3])
            guard cmd == batteryPrimary || cmd == batterySecondary else { continue }
            let payloadLen = Int(packet[5])
            guard packet.count >= 8 + payloadLen, payloadLen > 0 else { continue }
            let payload = Array(packet[8..<(8 + payloadLen)])
            return parsePayload(payload)
        }
        return nil
    }

    private static func parsePayload(_ payload: [UInt8]) -> BatteryStatus {
        var status = BatteryStatus()
        let count = Int(payload[0])
        for i in 0..<count {
            let idx = 1 + i * 2
            guard idx + 1 < payload.count else { break }
            let levelByte = payload[idx + 1]
            let level = BatteryLevel(percent: levelByte & 0x7F, charging: (levelByte & 0x80) != 0)
            switch payload[idx] {
            case 0x02: status.left  = level
            case 0x03: status.right = level
            case 0x04: status.case_ = level
            default:   break
            }
        }
        return status
    }
}

enum PacketBuilder {
    // operationID: earctl uses 1-250 (never 0). We use a simple incrementing counter.
    private static var _operationID: UInt8 = 0
    static func nextOperationID() -> UInt8 {
        _operationID = _operationID >= 250 ? 1 : max(_operationID &+ 1, 1)
        return _operationID
    }

    static func build(command: Command, payload: [UInt8] = [], fsn: UInt8? = nil) -> [UInt8] {
        let cmd = command.rawValue
        let operationID = fsn ?? nextOperationID()
        var packet: [UInt8] = [
            0x55, 0x60, 0x01,
            UInt8((cmd >> 8) & 0xFF),
            UInt8(cmd & 0xFF),
            UInt8(payload.count),
            0x00,
            operationID,
        ]
        packet.append(contentsOf: payload)
        let crc = crc16(packet)
        packet.append(UInt8(crc & 0xFF))
        packet.append(UInt8((crc >> 8) & 0xFF))
        return packet
    }

    static func ancPacket(mode: ANCMode) -> [UInt8] {
        build(command: .setANC, payload: [0x01, mode.rawValue, 0x00])
    }

    private static func crc16(_ buffer: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in buffer {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                if (crc & 0x0001) != 0 {
                    crc = (crc >> 1) ^ 0xA001
                } else {
                    crc >>= 1
                }
            }
        }
        return crc
    }
}
