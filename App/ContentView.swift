import SwiftUI

// Camera plus the first flight behaviour (one-key takeoff, hover, one-key land)
// behind a two-step arm switch, with emergency stop, land-now and a link watchdog.
// Sticks are always centred in this build; there is no joystick input yet.

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var stream = RTSPClient()
    @StateObject private var link = DroneLink()
    @StateObject private var probe = PortProbe()
    @StateObject private var flight = FlightController()
    @StateObject private var hold = HoldController()
    @StateObject private var scan = ScanController()
    @AppStorage("hotSwitch") private var hotSwitch = false
    @AppStorage("scanInHover") private var scanInHover = false
    @AppStorage("droneHost") private var droneHost = "192.168.1.1"
    @AppStorage("sendHeartbeat") private var sendHeartbeat = true
    @AppStorage("rotationV2") private var rotation = 270.0
    @AppStorage("trimRoll") private var trimRoll = 0
    @AppStorage("trimPitch") private var trimPitch = 0
    @AppStorage("invertPitch") private var invertPitch = false
    @AppStorage("nudgeAmount") private var nudgeAmount = 20.0
    @State private var showLog = false
    @State private var showFlightLog = true

    private let trimStep = 3

    private func pushTrim() {
        link.setTrim(roll: trimRoll, pitch: invertPitch ? -trimPitch : trimPitch)
    }

    /// Roll and pitch offsets for a nudge direction. Positive pitch = forward unless inverted.
    private func nudge(roll: Int, pitch: Int) {
        let amount = Int(nudgeAmount)
        link.setNudge(roll: roll * amount, pitch: (invertPitch ? -pitch : pitch) * amount)
    }

    private func nudgeButton(_ label: String, roll: Int, pitch: Int) -> some View {
        Text(label)
            .font(.title2)
            .frame(width: 64, height: 56)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(link.controlRunning ? 0.35 : 0.12)))
            .onLongPressGesture(minimumDuration: 0, maximumDistance: 40, pressing: { pressing in
                if pressing { nudge(roll: roll, pitch: pitch) } else { nudge(roll: 0, pitch: 0) }
            }, perform: {})
    }

    private var host: String { droneHost.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hostIsValid: Bool {
        !host.isEmpty && host.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil
    }
    private var linkFresh: Bool { Date().timeIntervalSince(link.lastReplyAt) < 2 }

    private func connect() {
        if sendHeartbeat { link.start(host: host) }
        pushTrim()
        hold.reset()
        stream.start(host: host)
        UIApplication.shared.isIdleTimerDisabled = true
    }

    /// Camera switch: one datagram on the control port. By default the RTSP session is
    /// reopened afterwards (pyDroneWire found that necessary, and this drone's telemetry
    /// byte 1 = 2 says the same). "Hot switch" sends the command alone to test whether
    /// the running stream simply changes camera.
    private func switchCamera(_ id: UInt8) {
        link.sendRaw(Data([0x06, id]))
        hold.reset()
        guard !hotSwitch else { return }
        stream.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            stream.start(host: host)
        }
    }

    private var cameraSwitchDelay: TimeInterval { hotSwitch ? 0.7 : 3.0 }

    /// Arrow showing the estimated drone motion in screen coordinates.
    private var motionArrow: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let scale = 12.0
            let end = CGPoint(x: c.x + hold.motionX * scale, y: c.y + hold.motionY * scale)
            var ring = Path(); ring.addEllipse(in: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8))
            ctx.fill(ring, with: .color(.secondary))
            var p = Path(); p.move(to: c); p.addLine(to: end)
            ctx.stroke(p, with: .color(.green), lineWidth: 4)
        }
        .frame(width: 96, height: 96)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.15)))
    }

    private func disconnect() {
        if flight.inFlight { flight.landNow() }
        stream.stop()
        link.stop()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("GPT-kun's Eyes")
                    .font(.largeTitle.bold())
                Text("Experiment 010 - Look around")
                    .foregroundStyle(.secondary)

                ZStack {
                    Color.black
                    if let img = stream.frame {
                        Image(uiImage: img)
                            .resizable()
                            .interpolation(.medium)
                            .aspectRatio(contentMode: .fit)
                            .rotationEffect(.degrees(rotation))
                    } else {
                        Text(stream.running ? stream.status : "Not connected")
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(12)
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 14))

                Text("\(stream.status)  \(stream.frameSize)  \(String(format: "%.1f", stream.fps)) fps")
                    .font(.footnote.monospaced())

                // MARK: Flight
                VStack(alignment: .leading, spacing: 10) {
                    Text("Flight: \(flight.phase.rawValue)\(flight.countdown > 0 ? " \(flight.countdown) s" : "")")
                        .font(.title3.bold())

                    HStack(spacing: 12) {
                        Button {
                            flight.emergencyStop()
                        } label: {
                            Text("EMERGENCY STOP")
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 56)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(!link.isUp)

                        Button {
                            flight.landNow()
                        } label: {
                            Text("LAND NOW")
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 56)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .disabled(!flight.inFlight)
                    }

                    Toggle("ARM: props on, 2 m clear all round, phone in hand", isOn: $flight.armed)
                        .font(.callout)
                        .tint(.red)
                        .disabled(flight.inFlight || !linkFresh)

                    HStack {
                        Text("Hover \(Int(flight.hoverSeconds)) s")
                        Slider(value: $flight.hoverSeconds, in: 2...30, step: 1)
                            .disabled(flight.inFlight)
                    }
                    .font(.callout)

                    Button {
                        flight.startHoverTest()
                    } label: {
                        Text("Take off, hover, land")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!flight.armed || flight.inFlight || !linkFresh)

                    Text("One-key takeoff climbs to the height the drone chooses (about 1 m), holds, then one-key land. If the drone's replies stop for 1.5 s or the app leaves the foreground, it lands by itself. Emergency stop cuts the motors and the drone drops.")
                        .font(.caption).foregroundStyle(.secondary)

                    // Nudge pad: momentary roll/pitch while held, any time control frames run.
                    Text("Nudge (hold)").font(.headline)
                    HStack(spacing: 24) {
                        VStack(spacing: 6) {
                            nudgeButton("▲", roll: 0, pitch: 1)
                            HStack(spacing: 6) {
                                nudgeButton("◀", roll: -1, pitch: 0)
                                nudgeButton("▼", roll: 0, pitch: -1)
                                nudgeButton("▶", roll: 1, pitch: 0)
                            }
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("strength \(Int(nudgeAmount))").font(.callout)
                            Slider(value: $nudgeAmount, in: 10...50, step: 5)
                            Toggle("invert pitch", isOn: $invertPitch).font(.callout)
                                .onChange(of: invertPitch) { _ in pushTrim() }
                        }
                    }
                    Text("Forward is the direction the camera looks. If ▲ sends it backwards, switch invert pitch.")
                        .font(.caption).foregroundStyle(.secondary)

                    DisclosureGroup("Flight log", isExpanded: $showFlightLog) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(flight.log.enumerated()), id: \.offset) { _, line in
                                Text(line).font(.system(size: 10, design: .monospaced))
                            }
                        }
                    }
                    .font(.callout)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.12)))

                // MARK: Hold
                VStack(alignment: .leading, spacing: 10) {
                    Text("Auto-hold (optical flow)").font(.title3.bold())

                    HStack(spacing: 12) {
                        Button("Front cam") { switchCamera(0x01) }
                            .buttonStyle(.bordered).disabled(!link.isUp)
                        Button("Bottom cam") { switchCamera(0x02) }
                            .buttonStyle(.bordered).disabled(!link.isUp)
                        Text("use bottom for hold").font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("Hot switch (send command only, keep the stream open)", isOn: $hotSwitch)
                        .font(.callout)
                    Text("Test: with video live, switch cameras with this on. If the picture changes within a second the drone hot-switches; if it freezes, the watchdog reopens the stream after 4 s and the answer is no.")
                        .font(.caption).foregroundStyle(.secondary)

                    HStack(alignment: .top, spacing: 14) {
                        motionArrow
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(format: "motion %.1f, %.1f px/f", hold.motionX, hold.motionY))
                            Text("auto roll \(hold.autoRoll) pitch \(hold.autoPitch)")
                            Text(String(format: "learned lean %.1f, %.1f", hold.integralX, hold.integralY))
                            Text("\(hold.flowStatus) (\(hold.framesMeasured))")
                        }
                        .font(.footnote.monospaced())
                    }

                    Text("Hand-held check first, hold OFF: bottom cam, drone 30 cm over a textured floor, move it right: the arrow should point right. Move it forward: arrow up. If not, change the rotation picker until it does.")
                        .font(.caption).foregroundStyle(.secondary)

                    Toggle("Auto-hold during hover", isOn: $hold.enabled)
                        .font(.callout)
                        .tint(.green)
                    HStack {
                        Text("gain \(String(format: "%.1f", hold.gain))").font(.callout)
                        Slider(value: $hold.gain, in: 0...10, step: 0.5)
                    }
                    HStack {
                        Text("max \(Int(hold.maxCorrection))").font(.callout)
                        Slider(value: $hold.maxCorrection, in: 5...40, step: 5)
                    }
                    HStack(spacing: 16) {
                        Toggle("flip roll", isOn: $hold.flipRoll).font(.callout)
                        Toggle("flip pitch", isOn: $hold.flipPitch).font(.callout)
                    }
                    Text("If the drone accelerates away instead of settling, land and flip the axis that ran off. Start with gain 3 and max 15.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.12)))

                // MARK: Look around
                VStack(alignment: .leading, spacing: 10) {
                    Text("Look around (360 in 4 stills)").font(.title3.bold())
                    Text("During a hover: front camera, four 90-degree turns measured from the video, a still after each, then back to the bottom camera. Hold pauses meanwhile and keeps only its learned lean. The hover is extended until the scan finishes.")
                        .font(.caption).foregroundStyle(.secondary)

                    Toggle("Run scan automatically 3 s into each hover", isOn: $scanInHover)
                        .font(.callout)
                    HStack(spacing: 12) {
                        Button("Scan now") { scan.start() }
                            .buttonStyle(.borderedProminent)
                            .disabled(flight.phase != .hover || scan.active)
                        Button("Abort scan") { scan.abort(reason: "user") }
                            .buttonStyle(.bordered)
                            .disabled(!scan.active)
                    }
                    HStack {
                        Text("yaw \(Int(scan.yawAmount))").font(.callout)
                        Slider(value: $scan.yawAmount, in: 15...60, step: 5)
                    }
                    HStack {
                        Text("lens FOV \(Int(scan.hfov))").font(.callout)
                        Slider(value: $scan.hfov, in: 40...100, step: 5)
                    }
                    Toggle("Save stills to Photos", isOn: $scan.savePhotos).font(.callout)
                    Text("\(scan.status)  turn \(String(format: "%.0f", scan.turnDegrees)) deg")
                        .font(.footnote.monospaced())
                    if !scan.stills.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(Array(scan.stills.enumerated()), id: \.offset) { _, img in
                                Image(uiImage: img)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(height: 70)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                    ForEach(Array(scan.log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 10, design: .monospaced))
                    }
                    Text("If four turns overshoot the start heading, lower the lens FOV; if they fall short, raise it. If the drone barely turns in 4 s, raise yaw.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.12)))

                // MARK: Pre-flight
                VStack(alignment: .leading, spacing: 10) {
                    Text("Pre-flight").font(.title3.bold())

                    Toggle("Controller handshake (centred frames at 20 Hz)", isOn: Binding(
                        get: { link.controlRunning },
                        set: { on in on ? link.startControlFrames() : link.stopControlFrames() }
                    ))
                    .font(.callout)
                    .disabled(flight.phase != .idle || !link.isUp)
                    Text("Lights should go from flashing to solid within a second. Sticks are forced to exact centre here, during takeoff and landing, and for calibration; trim and nudge only act in the hover.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("sending: \(link.currentSticks)")
                        .font(.footnote.monospaced())

                    Text("Gyro calibration. Drone flat and still on the floor. The lights should flash a pattern for a second or two. Two candidate commands; try A first, with props off the first time.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Button("Calibrate A (0x80)") { flight.calibrate(bit: DroneLink.cmdCalibrateA) }
                            .buttonStyle(.bordered)
                            .disabled(flight.phase != .idle || !linkFresh)
                        Button("Calibrate B (0x04)") { flight.calibrate(bit: DroneLink.cmdCalibrateB) }
                            .buttonStyle(.bordered)
                            .disabled(flight.phase != .idle || !linkFresh)
                    }

                    Text("Trim: tap the direction it drifted. Each tap adds \(trimStep) to the opposite stick, applied on every flight.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button("drifts fwd") { trimPitch -= trimStep; pushTrim() }
                        Button("drifts back") { trimPitch += trimStep; pushTrim() }
                        Button("drifts left") { trimRoll += trimStep; pushTrim() }
                        Button("drifts right") { trimRoll -= trimStep; pushTrim() }
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                    HStack {
                        Text("trim roll \(trimRoll > 0 ? "+" : "")\(trimRoll)  pitch \(trimPitch > 0 ? "+" : "")\(trimPitch)")
                            .font(.footnote.monospaced())
                        Spacer()
                        Button("reset trim") { trimRoll = 0; trimPitch = 0; pushTrim() }
                            .font(.caption)
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.12)))

                // MARK: Connection
                VStack(alignment: .leading, spacing: 7) {
                    Text("Drone address").font(.headline)
                    TextField("192.168.1.1", text: $droneHost)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                }

                HStack(spacing: 12) {
                    Button("Connect video") { connect() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!hostIsValid || stream.running)
                    Button("Disconnect") { disconnect() }
                        .buttonStyle(.bordered)
                        .disabled(!stream.running)
                    Button("Probe") { probe.check(host: host) }
                        .buttonStyle(.bordered)
                        .disabled(!hostIsValid)
                }
                Text(probe.result).font(.footnote.monospaced())

                Toggle("Send 1 s keep-alive to UDP 7099", isOn: $sendHeartbeat)
                    .font(.callout)

                Picker("Rotate", selection: $rotation) {
                    Text("0").tag(0.0)
                    Text("90").tag(90.0)
                    Text("180").tag(180.0)
                    Text("270").tag(270.0)
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 4) {
                    Text("rtp: \(stream.rtpPackets) pkts, \(stream.rtpBytes) B")
                    Text("frames: \(stream.framesDecoded) shown, \(stream.framesDropped) dropped, \(stream.decodeFailures) failed")
                    Text("link: \(link.state)  control frames: \(link.controlRunning ? "ON" : "off") (\(link.framesSent) sent)")
                    Text("drone replies: \(link.repliesSeen)  last: \(link.lastReplyHex.isEmpty ? "-" : link.lastReplyHex)")
                }
                .font(.footnote.monospaced())

                DisclosureGroup("Telemetry values seen (first time, bytes, count)") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(link.replyHistory.enumerated()), id: \.offset) { _, row in
                            Text("\(row.time)  \(row.hex)  x\(row.count)")
                                .font(.system(size: 10, design: .monospaced))
                        }
                    }
                }
                .font(.callout)

                DisclosureGroup("RTSP log", isExpanded: $showLog) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(stream.log.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(size: 10, design: .monospaced))
                        }
                    }
                }
                .font(.callout)

                Divider()
                Label("Throttle and yaw are always centred. Roll and pitch move only in the hover: by trim, by a held nudge button, and by auto-hold within its max. Commands: one-key takeoff/land, emergency stop, gyro calibrate, camera switch.", systemImage: "shield.checkered")
                    .font(.callout)
            }
            .padding()
        }
        .onAppear {
            flight.link = link
            hold.link = link
            hold.rotation = rotation
            scan.link = link
            scan.hold = hold
            scan.stream = stream
            scan.rotation = rotation
            scan.cameraSwitchDelay = cameraSwitchDelay
            scan.switchCamera = { id in switchCamera(id) }
            scan.stillHovering = { [weak flight] in flight?.phase == .hover }
            stream.onFrame = { [weak hold] frame in hold?.process(frame) }
            hold.onShift = { [weak scan] x, y, w in scan?.onShift(x: x, y: y, screenWidth: w) }
            flight.scanActive = { [weak scan] in scan?.active ?? false }
            flight.onHoverStart = { [weak hold, weak scan] in
                hold?.reset()
                if scanInHover {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { scan?.start() }
                }
            }
            pushTrim()
        }
        .onChange(of: rotation) { r in hold.rotation = r; scan.rotation = r }
        .onChange(of: hotSwitch) { _ in scan.cameraSwitchDelay = cameraSwitchDelay }
        .onChange(of: flight.phase) { p in
            if p != .hover, scan.active { scan.abort(reason: "flight phase \(p.rawValue)") }
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active { flight.appWentToBackground() }
        }
        .onDisappear { disconnect() }
    }
}
