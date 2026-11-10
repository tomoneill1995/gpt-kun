import SwiftUI

// VIDEO ONLY: no takeoff, landing, flip or joystick input exists in this app.
// Control-port traffic is the 2-byte keep-alive and, only if the user switches it on,
// the centred idle frame used to test the controller handshake.

struct ContentView: View {
    @StateObject private var stream = RTSPClient()
    @StateObject private var link = DroneLink()
    @StateObject private var probe = PortProbe()
    @AppStorage("droneHost") private var droneHost = "192.168.1.1"
    @AppStorage("sendHeartbeat") private var sendHeartbeat = true
    @AppStorage("rotation") private var rotation = 0.0
    @State private var idleFrames = false
    @State private var showLog = false

    private var host: String { droneHost.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hostIsValid: Bool {
        !host.isEmpty && host.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil
    }

    private func connect() {
        if sendHeartbeat { link.start(host: host) }
        stream.start(host: host)
    }

    private func disconnect() {
        stream.stop()
        idleFrames = false
        link.stop()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("GPT-kun's Eyes")
                    .font(.largeTitle.bold())
                Text("Experiment 004 - Native viewer, no VLC")
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

                HStack {
                    Text("\(stream.status)  \(stream.frameSize)  \(String(format: "%.1f", stream.fps)) fps")
                    Spacer()
                }
                .font(.footnote.monospaced())

                VStack(alignment: .leading, spacing: 7) {
                    Text("Drone address").font(.headline)
                    TextField("192.168.1.1", text: $droneHost)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                }

                HStack(spacing: 12) {
                    Button("Probe drone type") { probe.check(host: host) }
                        .buttonStyle(.bordered)
                        .disabled(!hostIsValid)
                    Text(probe.result).font(.footnote.monospaced())
                }

                Toggle("Send 1 s keep-alive to UDP 7099", isOn: $sendHeartbeat)
                    .font(.callout)

                Picker("Rotate", selection: $rotation) {
                    Text("0").tag(0.0)
                    Text("90").tag(90.0)
                    Text("180").tag(180.0)
                    Text("270").tag(270.0)
                }
                .pickerStyle(.segmented)

                HStack(spacing: 12) {
                    Button("Connect video") { connect() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!hostIsValid || stream.running)
                    Button("Disconnect") { disconnect() }
                        .buttonStyle(.bordered)
                        .disabled(!stream.running)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("rtp: \(stream.rtpPackets) pkts, \(stream.rtpBytes) B")
                    Text("frames: \(stream.framesDecoded) shown, \(stream.framesDropped) dropped, \(stream.decodeFailures) failed")
                    Text("link: \(link.state)")
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
                VStack(alignment: .leading, spacing: 6) {
                    Text("Controller handshake test (props OFF)").font(.headline)
                    Toggle("Send neutral stick frame at 20 Hz", isOn: $idleFrames)
                        .font(.callout)
                        .onChange(of: idleFrames) { on in
                            if on {
                                if link.state == "idle" { link.start(host: host) }
                                link.startIdleFrames()
                            } else {
                                link.stopIdleFrames()
                            }
                        }
                    Text("pyDroneWire's 21-byte frame with all sticks centred and no command bit. On this drone it turns the lights from flashing to solid, meaning the drone accepts us as its controller. It does not arm, take off or spin motors; keep propellers off anyway. Sent: \(link.idleSent)")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Divider()
                Label("No takeoff, landing, flip or joystick input exists in this build.", systemImage: "shield.checkered")
                    .font(.callout)
            }
            .padding()
        }
        .onDisappear { disconnect() }
    }
}
