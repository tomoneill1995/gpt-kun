# GPT-kun Eyes - camera-only iPhone proof of concept

**No flight or motor commands.** This app tries to show the video from a KY UFO-family Wi-Fi toy drone on an iPhone. The only packet it ever sends is a 2-byte keep-alive. It has not yet been compiled or tested on a real drone.

## Step 0 - find out which drone you actually have (do this first)

The KY UFO app drives at least two unrelated protocols, and a `FLOW-UFO-xxxxxx` network name has been reported with both. The router address is the tiebreaker:

| Router IP (Settings > Wi-Fi > the (i) next to the drone network) | Video protocol | This build |
|---|---|---|
| 192.168.1.1 | RTSP `rtsp://192.168.1.1:7070/webcam`, MJPEG, needs keep-alive `01 01` to UDP 7099 every second | **supported** |
| 192.168.169.1 | Custom UDP on 8800: client sends `EF 00 04 00`, drone sends MJPEG fragments (`93 01` header) without JPEG tables, client ACKs with `EF 02` | not yet, needs a custom decoder |
| 192.168.80.1 | Jieli CTP over TCP 3333, JPEG over UDP | not yet |

Details and sources are in [PROTOCOL-NOTES.md](PROTOCOL-NOTES.md).

**Zero-build check on the iPhone, if the router is 192.168.1.1:** install the free VLC app from the App Store, connect to the drone Wi-Fi, and open the network stream `rtsp://192.168.1.1:7070/webcam`. Some units stream without the keep-alive; if VLC shows a picture, the whole RTSP assumption is confirmed. A black screen is not a verdict, because the keep-alive may be required.

**With a PC that has Wi-Fi** (a USB Wi-Fi adapter works), run `python tools/heartbeat.py 192.168.1.1` in one window and in another:

```bash
ffplay -rtsp_transport udp -fflags nobuffer -flags low_delay rtsp://192.168.1.1:7070/webcam
```

**Inside this app:** the **Probe drone type** button does a TCP connect to port 7070 and reports open or refused. Open means the RTSP type.

## Free build from Windows

1. Create a **public** GitHub repository (public repos get free macOS Actions minutes).
2. Push all files including the hidden `.github/workflows/ios.yml`.
3. GitHub > Actions > **Build unsigned iPhone app** > Run workflow. A push to `main` also starts it.
4. Download the `GPTKunCamera-unsigned-ipa` artifact and extract the `.ipa`.
5. Install [Sideloadly](https://sideloadly.io/) on Windows, connect the iPhone by USB, sign and install the IPA with your own free Apple ID. Free signing expires after 7 days; Sideloadly can refresh it.
6. On the iPhone trust the developer profile (Settings > General > VPN & Device Management). Developer Mode may need enabling.

## First test (props off)

1. Remove propellers. Charge the battery. Quit the KY UFO app; the drone serves one client.
2. Connect the iPhone to the drone's Wi-Fi and accept the "no internet" prompt.
3. Open GPT-kun Eyes and allow local-network access.
4. Tap **Connect video**. The `drone replies` counter should start climbing within a few seconds; that proves the keep-alive is reaching a cooingdv drone. Video should follow. Use the rotate control if the picture is sideways; the camera module is mounted rotated on some units.
5. Tap **Disconnect** before leaving the app.

## Stack

- SwiftUI, Apple Network framework for the UDP keep-alive and the RTSP/RTP client
- Own RTSP client plus an RFC 2435 RTP/JPEG reassembler (`App/RTPJPEG.swift`), decoded with ImageIO. No third-party media library: MobileVLCKit negotiated the session fine but never decoded a frame from this drone, and the drone refuses RTSP over TCP (461), so the stream is UDP only.
- XcodeGen project generation, GitHub Actions macOS build, unsigned IPA, Sideloadly

## Status

- v0.1 to v0.3: pipeline proven, drone type confirmed (RTSP, 192.168.1.1), raw video packets received by the probe.
- v0.4: native viewer, first picture (garbled: wrong chroma sampling).
- **v0.5: clean live video, 240x320 at about 20 fps, confirmed on FLOW-UFO-985264 on 2026-11-11.** Camera phase complete.

## Next phase: wings

Manual flight with a local safety layer, in this order: a watchdog that lands or cuts motors when the link or the UI goes quiet, an emergency stop that works independently of everything else, then on-screen sticks, then takeoff and land. The 21-byte control frame is confirmed by the drone (lights go solid on the neutral frame). Only after that does GPT-kun get a restricted set of actions.

## Next

Flight control stays a separate module with a local watchdog and manual override. The known stick packet for this family is a 9-byte frame at 20 Hz on UDP 7099; it is intentionally not implemented here.
