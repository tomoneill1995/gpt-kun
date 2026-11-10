# Protocol notes for the FLOW-UFO / KY UFO drone family

Collected 2026-11-10 from open-source reverse-engineering work. Nothing here has been verified against our own drone yet. Where sources disagree, both are listed.

## Which type is it?

The SSID prefix is NOT a reliable discriminator. `FLOW-UFO-xxxxxx` appears in both:

| Source | SSID | Drone IP | Video |
|---|---|---|---|
| [hakimjanov/pyDroneWire](https://github.com/hakimjanov/pyDroneWire) | `FLOW-UFO-XXXXXX` | 192.168.1.1 | RTSP `rtsp://192.168.1.1:7070/webcam` |
| [OpenIPC decoder issue 196](https://github.com/OpenIPC/decoder/issues/196) | `FLOW-UFO-…` / `FLOW_…` (D16) | 192.168.169.1 | custom UDP on 8800 (`flowufo://`) |
| OpenIPC, same thread | `FLY-UFO-xxxxxx` (K200) | 192.168.1.1 | RTSP 7070 |

Rule of thumb from that thread: 192.168.1.x with TCP 7070 open and a heartbeat on 7099 is the RTSP (cooingdv) type; 192.168.169.x is the custom-UDP type. The in-app "Probe drone type" button does a TCP connect to 7070 to tell them apart.

## Type A: RTSP (192.168.1.1)

Sources: pyDroneWire (`drone_controller.py`), [Juliii-p/e88-drone-pc-control](https://github.com/Juliii-p/e88-drone-pc-control), [CraxCurl/RC-Swamp working.md](https://github.com/CraxCurl/RC-Swamp/blob/main/working.md), [PatrickAcheson/E99-drone-reverse-engineer](https://github.com/PatrickAcheson/E99-drone-reverse-engineer).

- Control and keep-alive: UDP 192.168.1.1:7099. Client source port is ephemeral; replies come back to it.
- Keep-alive: bytes `01 01` every 1 s. Stream only runs while a client is alive on 7099. (pyDroneWire's README claims a 9-byte heartbeat; its code sends `01 01`. Trust the code.)
- Video: `rtsp://192.168.1.1:7070/webcam`, RTP over UDP, MJPEG. Front and bottom camera share the URL; switching is done on the control port. After a switch, reopen the RTSP session (pyDroneWire waits 1.5 s and retries up to 5 times). Camera can be mounted sideways; some units need 90 or 270 degree rotation.
- Camera switch: single datagram `06 01` (front) or `06 02` (bottom) to 7099.
- Drone telemetry: a few bytes about once per second. First byte is a module id (83 seen on Juliii-p's unit). None of the sources parse it further.
- **Our drone (FLOW-UFO-985264, observed 2026-11-10/11):**
  - TCP 7070 open. Replies to the `01 01` keep-alive with 11 bytes `65 02 31 46 31 46 00 00 00 00 00`, roughly 8 per second. First byte 0x65 = 101 is in RC-Swamp's GL range, so the 21-byte GL stick packet is the right one.
  - RTSP server: `OPTIONS` answers `Public: DESCRIBE, SETUP, TEARDOWN, PLAY, PAUSE`. SDP: `s=Test`, `a=type:broadcast`, `c=IN IP4 0.0.0.0`, `m=video 0 RTP/AVP 26`, `a=control:track0`, content-base `rtsp://192.168.1.1:7070/webcam/`. `SETUP` with `RTP/AVP/TCP;unicast;interleaved=0-1` is refused with **461 Unsupported Transport**: UDP only. UDP SETUP returns `server_port=52042-52043` and a 32-char hex session id. No RTP-Info on PLAY.
  - Video: standard RTP/JPEG (RFC 2435), payload type 26, **JPEG type 65** (4:2:2 with restart markers), **Q 255** (quantisation tables in-band), **240x320** portrait, about 27 packets/s and 107 KB/s observed. Frames are roughly 9.4 KB.
  - MobileVLCKit 3.7.5 reached "playing" but decoded nothing over UDP, with no error logged, while a plain Swift RTSP client on the same phone received the packets. Cause not identified; VLC was dropped in v0.4 in favour of a native RFC 2435 reassembler and ImageIO decode.
  - Sending pyDroneWire's centred 21-byte idle frame at 20 Hz turns the drone's lights from flashing to solid. That is the "controller connected" state, and it confirms the GL packet layout and checksum. Video streams without it; the keep-alive alone is enough.

### Stick packet, 21-byte "GL" layout (pyDroneWire, matches RC-Swamp's GL variant)

NOT implemented in the app. Recorded for the future flight module only.

```
[0]  0x03   [1] 0x66   [2] 0x14          fixed header
[3]  roll   [4] pitch  [5] throttle  [6] yaw     0x00-0xFF, neutral 0x80
[7]  cmd    [8] speed (always 0x02)
[9..18]     ten 0x00 bytes (unknown)
[19] checksum = XOR of bytes [3..18]
[20] 0x99   tail
```
Idle packet: `03 66 14 80 80 80 80 00 02 00 00 00 00 00 00 00 00 00 00 02 99`. Sent at 20 Hz only while armed.

cmd byte (pyDroneWire code; its README lists different values, the code wins):

| cmd | meaning | hold |
|---|---|---|
| 0x01 | takeoff / land toggle | 1.0 s |
| 0x02 | emergency stop | 1.0 s |
| 0x08 | flip | 0.5 s |
| 0x10 | headless toggle | 0.5 s |
| 0x80 | gyro calibrate (only on the ground) | 1.0 s |

RC-Swamp notes the same bit in its GL variant is used for both takeoff and land, so the toggle is ambiguous. Its 9-byte "Legacy" layout (`03 66 R P T Y FLAGS CHK 99`, checksum XOR of bytes 2..6, flags 0x01 takeoff, 0x02 land, 0x04 stop, 0x08 flip, 0x10 headless, 0x80 calibrate) applies to other units in the family; RC-Swamp says the first telemetry byte identifies which (GL if 90-101, 103, 82, 85 or 88).

morphDrone's README (quoted in OpenIPC 196): "on the KY UFO, pitch and throttle are inverted in hardware".

Gotchas from those projects: closing the controller does not land the drone; emergency stop cuts motors mid-air; a low battery degrades the Wi-Fi link badly; altitude hold at throttle 0x80 is not reliable.

## Type B: custom UDP, "flowufo" (192.168.169.1)

Sources: [turbodrone](https://github.com/marshallrichards/turbodrone) `backend/protocols/wifi_uav_video_protocol.py`, `backend/utils/wifi_uav_packets.py`, `backend/utils/wifi_uav_jpeg.py`; [OpenIPC decoder PR 215](https://github.com/OpenIPC/decoder/pull/215); [FahrulRPutra/reversing-wifi-uav](https://github.com/FahrulRPutra/reversing-wifi-uav). Unverified against hardware by us.

- Ports: client sends to UDP 8800 (some units also 8801). Drone sends video from UDP 1234 to the client's source port.
- Start: `EF 00 04 00` to 8800 (and 8801), repeated every 200 ms until the first frame arrives.
- Video datagrams: at least 56 bytes, start with `93 01`. Native layout: frame id u64 LE at [8..15], fragment index u32 LE at [32..35], fragment count u32 LE at [36..39], body length u32 LE at [40..43], quality at [48], JPEG scan data from [56]. Legacy layout (when u16 LE at [2..3] is not the datagram length): frame id u16 at [16..17], fragment index u16 at [32..33].
- ACK / next-frame request: `EF 02` + u16 LE total length + `02 02 00 01` + slot count at [8] + frame seq u32 LE at [12..15] + command length u16 LE at [16..17] + 64-byte command field from [18] (neutral `66 14 80 80 80 80 00 02 … 02 99`) + quality `32 4B 14 2D 00` at [82..86] + `00` + ACK slots (frame seq u64 LE, status u32 LE, record length u32 LE, received-fragment bitmap u32 LE words). turbodrone sends it when a frame completes or after 80 ms without one; OpenIPC sends every 25 ms.
- JPEG reassembly: the stream carries only scan data. Client prepends SOI, DQT (Annex K luma and chroma tables, unscaled), SOF0 (8-bit, 640x360 default, 4:4:4, quant ids 0/1/1), SOS (`00 11 11 00 3F 00`), then appends `FF D9`. No DHT segment is written; the decoder must fall back to the standard Huffman tables (libjpeg does, Apple's ImageIO is unverified). OpenIPC's `?dqt=zigzag|raster|q50` option says the table order is still a question.
- Flight: turbodrone's control uses a separate longer `66 14 … 99` layout; reversing-wifi-uav describes a 20-byte packet starting `66` and ending `99` with an XOR checksum. Not needed for the camera-only phase.

An iOS port of type B needs: a UDP socket bound to one port, the start packet loop, fragment reassembly keyed by frame id, header synthesis, and decoding via UIImage or ImageIO. No VLC needed.

## Build pipeline facts

- MobileVLCKit 3.7.0 through 3.7.5 exist on VideoLAN's CocoaPods server (3.7.5 dated 2026-10-31). The cocoapods.org page is stale and shows 4.0.0a2 from 2023.
- GitHub Actions `macos-latest` has CocoaPods preinstalled; XcodeGen comes from Homebrew in the workflow.
