# earctl — Alfred Workflow for Nothing Ear 2

Alfred workflow to control Nothing Ear 2 headphones on macOS via Classic Bluetooth.

---

## Protocol

- Transport: Classic Bluetooth RFCOMM, IOBluetooth framework
- Device class: `0x240404` (Audio/Video, Headphones)
- RFCOMM channel: discovered via NT Link UUID `aeac4a03-dff5-498f-843a-34487cf133eb` (ch15)
  - Do NOT use "Spp1" (ch12) — different serial port

### Packet format

```
[0x55, 0x60, 0x01, cmdH, cmdL, payloadLen, 0x00, FSN, ...payload, crc16L, crc16H]
```

- FSN: incrementing 1–250 (never 0)
- CRC-16/ARC: init=0xFFFF, poly=0xA001, over all preceding bytes, appended little-endian
- **Response command bytes are little-endian**: `(UInt16(packet[4]) << 8) | UInt16(packet[3])`

### Commands

| Action       | Command   | Payload                  | Response cmd (LE) |
|--------------|-----------|--------------------------|-------------------|
| GET battery  | `0x07C0`  | (none)                   | `0x4007`          |
| GET ANC mode | `0x1EC0`  | (none)                   |                   |
| SET ANC mode | `0x0FF0`  | `[0x01, mode, 0x00]`     | `0xE003`          |

### ANC modes
`HIGH=0x01, MID=0x02, LOW=0x03, ADAPTIVE=0x04, OFF=0x05, TRANSPARENCY=0x07`

---

## Architecture

```
NothingXfred/
├── cli/Sources/nothing-ctl/
│   ├── main.swift            ← arg parsing, RunLoop, exit
│   ├── BluetoothManager.swift← IOBluetooth RFCOMM, 5-attempt retry
│   ├── Protocol.swift        ← packet builder + CRC16
│   └── Commands.swift        ← command & enum constants
└── workflow/
    ├── info.plist            ← Alfred workflow metadata
    ├── bin/nothing-ctl       ← compiled CLI binary
    └── icons/                ← PNG icons per mode
```

## Build

```bash
cd cli && swift build -c release
cp .build/release/nothing-ctl ../workflow/bin/nothing-ctl
cd ../workflow && zip -r ../NothingEar2.alfredworkflow . -x "*.DS_Store"
```
