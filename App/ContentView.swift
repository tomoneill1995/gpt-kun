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
    @AppStorage("droneHost") private var droneHost = "192.168.1.1"
    @AppStorage("sendHeartbeat") private var sendHeartbeat = true
    @AppStorage("rotationV2") private var rotation = 270.0
    @State private var showLog = false
    @State private var showFlightLog = true

    private var host: String { droneHost.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hostIsValid: Bool {
        !host.isEmpty && host.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil
    }
    private var linkFresh: Bool { Date().timeIntervalSince(link.lastReplyAt) < 2 }

    private func connect() {
        if sendHeartbeat { link.start(host: host) }
        stream.start(host: host)
        UIApplication.shared.isIdleTimerDisabled = true
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
                Text("Experiment 006 - First hover")
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
                        Slider(value: $flight.hoverSeconds, in: 2...15, step: 1)
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

                    Text("One-key takeoff climbs to the height the drone chooses (about 1 m), holds with sticks centred, then one-key land. If the drone's replies stop for 1.5 s or the app leaves the foreground, it lands by itself. Emergency stop cuts the motors and the drone drops.")
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

                DisclosureGroup("RTSP log", isExpanded: $showLog) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(stream.log.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(size: 10, design: .monospaced))
                        }
                    }
                }
                .font(.callout)

                Divider()
                Label("No joystick input exists in this build. Sticks are always centred; the only commands are one-key takeoff/land and emergency stop.", systemImage: "shield.checkered")
                    .font(.callout)
            }
            .padding()
        }
        .onAppear { flight.link = link }
        .onChange(of: scenePhase) { phase in
            if phase != .active { flight.appWentToBackground() }
        }
        .onDisappear { disconnect() }
    }
}
