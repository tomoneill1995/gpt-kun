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

- v0.6: first flight behaviour. One-key takeoff, hover N seconds, one-key land, behind an arm switch, with emergency stop, land-now, link watchdog and background auto-land. Sticks stay centred; no joystick input.

## Flight test procedure (v0.6)

The drone's one-key takeoff climbs to a height its own flight controller picks, about a metre, and holds it. There is no altitude telemetry, so the app cannot ask for a specific height yet.

**Dry run first, propellers OFF.** Connect video, flip ARM, tap "Take off, hover, land" with 3 s hover. Expected: the lights go solid during the handshake second, the motors spin up on the takeoff command, keep spinning through the hover, and stop within a second or two after the land command. Then run it again and press EMERGENCY STOP during the hover: motors must stop at once. Only when both behave do the props go on.

**First real flight.** Props on, drone on a flat floor with some texture (not a plain white tile; the optical flow needs features), 2 m clear in every direction, nothing above it, battery full. Stand back, thumb over EMERGENCY STOP. Hover 3 s the first time. Expect a brisk climb to roughly a metre, a wobble, a hold, then a descent and motor stop.

**Known risk.** The takeoff and land commands are the same bit. The app holds it for 20 consecutive frames, so a single lost packet does not matter, but if the drone somehow misses the whole takeoff burst, the later "land" burst would take it off instead. Watch it, and use EMERGENCY STOP if anything looks wrong. Emergency stop cuts the motors wherever the drone is; from a metre onto carpet a toy of this weight is fine.

**First flight result (2026-11-11, v0.6):** took off to roughly a metre, then went forward and strongly left into a fridge. Emergency stop worked; the drone was fine. Likely cause: one folding arm was not fully clicked out, which tilts that motor and gives a steady push in one direction. Afterwards the drone sat with lights flashing and ignored handshake, calibrate and takeoff; frames were identical to the ones that flew, so that is the drone's post-crash or low-battery lockout. Battery went on charge.

**Pre-flight checklist:** all four arms clicked fully open, props tight, battery charged, drone flat and still at power-on, handshake switch gives solid lights before arming.

**Open questions for the next session:** which calibrate bit (0x80 or 0x04) the drone honours; whether the telemetry bytes change when the drone accepts the controller (then the app can wait for that instead of a 1 s timer); which way pitch and throttle really go.

## v0.7: calibrate, trim, nudge

1. **Calibrate** with the drone flat on the floor, props off the first time. Button A sends 0x80 (pyDroneWire), button B sends 0x04 (turbodrone / RC-Swamp). The right one makes the lights flash a pattern for a second or two. Note which one works in PROTOCOL-NOTES.md.
2. **Fly 3 s** in the biggest clear space available. Watch which way it drifts.
3. **Trim**: tap the button for the direction it drifted ("drifts left" adds right roll). One tap per obvious drift, then fly again. Trim persists between launches.
4. **Nudge pad**: hold an arrow during the hover to push the drone that way. Forward is where the camera looks. If the up arrow sends it backwards, switch "invert pitch"; one source says this drone's pitch axis is inverted in hardware.

Throttle and yaw stay centred. The hover height is still the drone's own.

## v0.9: optical-flow auto-hold

The drone reports no position, so the app measures drift from the video: Vision's translational registration gives the shift between consecutive frames, and over a floor that is the drone's motion. A PI controller turns it into roll and pitch offsets (P leans against motion, I learns the standing lean, which is auto-trim), clamped to a max you set, applied only in the hover.

1. **Bottom camera.** Tap "Bottom cam" (sends `06 02`, then reopens RTSP). Rotate the picture so "up" is the drone's front.
2. **Hand-held check, hold OFF, props off.** Hold the drone 30 cm over a floor with some texture and move it right: the green arrow should point right. Move it forward: arrow up. Fix with the rotation picker.
3. **First hold flight.** Gain 3, max 15, hover 10 s, biggest clear floor you have, thumb on EMERGENCY STOP. It should settle rather than drift. If it accelerates away along one axis, land and switch that axis's flip toggle; the stick direction for pitch is still unverified on this unit.
4. **Tune.** Raise gain until it starts to twitch, then back off. The "learned lean" numbers after a good hover are what trim should be.

Front camera works too but confuses turning with sideways drift, so expect worse hold.

**Result (2026-11-14):** auto-hold on the bottom camera "seems to be working pretty well".

## v0.10: hot-switch test, telemetry history, 360 look-around

- **One camera at a time.** The drone has a single stream; `06 01` / `06 02` choose which camera feeds it. This unit's telemetry byte 1 is 2, which other projects read as "switch needs an RTSP reopen". The **Hot switch** toggle sends the command without reopening so you can see whether the picture changes anyway. If it freezes, the stream watchdog reopens it after 4 s.
- **Telemetry history.** Every distinct 11-byte reply is listed with first-seen time and count. So far it has been constant on the ground; fly and see whether any byte tracks battery, altitude or flow quality. The built-in optical-flow sensor is internal and never reported directly.
- **Look around.** In a hover: front camera, yaw stick at a set amount until the video says 90 degrees have gone by (horizontal shift times lens FOV over frame width), settle 1.5 s, capture a still, four times, then bottom camera and hold resumes. Stills show as thumbnails and go to Photos. Each turn is capped at 4 s in case the scene is featureless. If four turns overshoot the start heading, lower the lens FOV setting; if short, raise it. The hover is extended while the scan runs, up to 45 s.

**Result (2026-11-14):** hot switch does nothing; every camera change is a 3 s reopen. The fast scan turned correctly but the drone drifted off and crashed during the long blind stretch with the hold paused.

## v0.11: safe scan

Default scan mode keeps the bottom camera and the hold running. Yaw is measured from the floor by fitting a homography between frames (Vision), so no lens guess is needed; the proportional term is dropped during the turn and the learned lean kept. For each still the drone glances: front camera (about 3 s reopen plus 0.8 s), capture, bottom camera (3 s), then 2.5 s for the hold to re-centre. While the front camera is up, horizontal image shift still drives a half-gain roll correction. Roughly 50 s for four stills; the hover extends up to 80 s. The old fast mode remains behind a toggle for drones that can hot-switch.

## After that

Throttle on the nudge pad once its direction is known, a lower hover, then a restricted action set for GPT-kun.

## Next

Flight control stays a separate module with a local watchdog and manual override. The known stick packet for this family is a 9-byte frame at 20 Hz on UDP 7099; it is intentionally not implemented here.
