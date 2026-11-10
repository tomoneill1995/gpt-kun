import SwiftUI
import Combine
import MobileVLCKit

// VIDEO ONLY: no flight command transport or motor controls exist in this app.
// The only packet ever sent is the 2-byte keep-alive in DroneLink.

/// Collects VLC's own log so stream problems can be read on the phone screen.
final class ScreenLogger: NSObject, VLCLogging, ObservableObject {
    var level: VLCLogLevel = .debug
    @Published var lines: [String] = []
    /// Debug chatter is kept only for the modules on the stream path.
    private let watched = ["live555", "mjpeg", "jpeg", "avcodec", "videotoolbox", "vout", "packetizer", "decoder", "rtp", "rtsp"]

    func handleMessage(_ message: String, logLevel level: VLCLogLevel, context: VLCLogContext?) {
        let tag: String
        switch level {
        case .error: tag = "E"
        case .warning: tag = "W"
        case .info: tag = "I"
        default: tag = "D"
        }
        let module = context?.module ?? ""
        if level != .error && level != .warning {
            let hay = (module + " " + message).lowercased()
            guard watched.contains(where: { hay.contains($0) }) else { return }
        }
        let line = "\(tag) \(module): \(message)"
        DispatchQueue.main.async {
            self.lines.append(line)
            if self.lines.count > 60 { self.lines.removeFirst(self.lines.count - 60) }
        }
    }

    func clear() { lines.removeAll() }
}

final class VideoSession: ObservableObject {
    @Published var status = "Disconnected"
    @Published var playing = false
    @Published var stats = ""
    let player = VLCMediaPlayer()
    let logger = ScreenLogger()
    private var poll: Timer?
    private var logForward: AnyCancellable?

    init() {
        VLCLibrary.shared().loggers = [logger]
        // Nested ObservableObject changes do not reach SwiftUI on their own.
        logForward = logger.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func attach(_ view: UIView) {
        player.drawable = view
    }

    func start(host: String, overTCP: Bool) {
        stop()
        logger.clear()
        guard let url = URL(string: "rtsp://\(host):7070/webcam") else { return }
        let media = VLCMedia(url: url)
        var options: [String: Any] = ["network-caching": 300]
        if overTCP { options["rtsp-tcp"] = true }
        media.addOptions(options)
        player.media = media
        status = "Connecting \(overTCP ? "(TCP)" : "(UDP)") to \(url.absoluteString)"
        player.play()

        // Poll player state rather than relying on the VLC delegate; its Swift
        // signature differs between MobileVLCKit releases and a mismatch is a silent no-op.
        poll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        poll?.invalidate(); poll = nil
        player.stop()
        playing = false
        status = "Disconnected"
        stats = ""
    }

    private func refresh() {
        switch player.state {
        case .playing:
            playing = true
            status = "Playing (RTSP session up)"
        case .buffering, .opening:
            status = "Connecting / buffering"
        case .error:
            playing = false
            status = "Stream failed, see log"
        case .stopped, .ended:
            playing = false
            status = "Stopped"
        default:
            break
        }

        guard let media = player.media else { return }
        let size = player.videoSize
        var codec = "?"
        if let tracks = media.tracksInformation as? [[String: Any]] {
            for t in tracks {
                if let type = t[VLCMediaTracksInformationType] as? String, type == VLCMediaTracksInformationTypeVideo,
                   let fourcc = (t[VLCMediaTracksInformationCodec] as? NSNumber)?.uint32Value {
                    codec = fourCC(fourcc)
                    if let w = (t[VLCMediaTracksInformationVideoWidth] as? NSNumber)?.intValue,
                       let h = (t[VLCMediaTracksInformationVideoHeight] as? NSNumber)?.intValue {
                        codec += " \(w)x\(h)"
                    }
                }
            }
        }
        stats = "in \(media.numberOfReadBytesOnInput) B, demux \(media.numberOfReadBytesOnDemux) B, decoded \(media.numberOfDecodedVideoBlocks), shown \(media.numberOfDisplayedPictures), lost \(media.numberOfLostPictures)\nvideoSize \(Int(size.width))x\(Int(size.height)), track \(codec)"
    }

    private func fourCC(_ v: UInt32) -> String {
        let bytes = [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
        return String(bytes: bytes, encoding: .ascii) ?? String(format: "%08X", v)
    }
}

struct VLCVideoSurface: UIViewRepresentable {
    let session: VideoSession
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        session.attach(view)
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) { }
}

struct ContentView: View {
    @StateObject private var video = VideoSession()
    @StateObject private var link = DroneLink()
    @StateObject private var probe = PortProbe()
    @StateObject private var rtsp = RTSPProbe()
    @AppStorage("droneHost") private var droneHost = "192.168.1.1"
    @AppStorage("sendHeartbeat") private var sendHeartbeat = true
    @AppStorage("rtspTCP") private var rtspTCP = false
    @AppStorage("rotation") private var rotation = 0.0
    @State private var idleFrames = false

    private var host: String { droneHost.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hostIsValid: Bool {
        !host.isEmpty && host.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil
    }

    private func connect() {
        if sendHeartbeat { link.start(host: host) }
        video.start(host: host, overTCP: rtspTCP)
    }

    private func disconnect() {
        video.stop()
        rtsp.stop()
        idleFrames = false
        link.stop()
    }

    private func runRTSPProbe() {
        video.stop()                      // the drone serves one video client at a time
        if sendHeartbeat, link.state == "idle" { link.start(host: host) }
        rtsp.start(host: host, overTCP: rtspTCP)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("GPT-kun's Eyes")
                    .font(.largeTitle.bold())
                Text("Experiment 003 - Camera only, VLC-free RTSP probe")
                    .foregroundStyle(.secondary)

                ZStack {
                    VLCVideoSurface(session: video)
                        .rotationEffect(.degrees(rotation))
                        .aspectRatio(4 / 3, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .background(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    if !video.playing {
                        Text("Waiting for camera feed")
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(12)
                    }
                }

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
                Toggle("RTSP over TCP (default is UDP)", isOn: $rtspTCP)
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
                        .disabled(!hostIsValid)
                    Button("Reconnect") {
                        video.stop()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            video.start(host: host, overTCP: rtspTCP)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!hostIsValid)
                    Button("Disconnect") { disconnect() }
                        .buttonStyle(.bordered)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("video: \(video.status)")
                    Text(video.stats)
                    Text("link: \(link.state)")
                    Text("drone replies: \(link.repliesSeen)  last: \(link.lastReplyHex.isEmpty ? "-" : link.lastReplyHex)")
                }
                .font(.footnote.monospaced())

                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("RTSP probe (no VLC)").font(.headline)
                    Text("Talks RTSP to the drone directly and counts raw video packets. Stops the VLC view first.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Button("Run RTSP probe") { runRTSPProbe() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!hostIsValid || rtsp.running)
                        Button("Stop probe") { rtsp.stop() }
                            .buttonStyle(.bordered)
                            .disabled(!rtsp.running)
                    }
                    Text("rtp packets: \(rtsp.rtpPackets)  bytes: \(rtsp.rtpBytes)")
                        .font(.footnote.monospaced())
                    if !rtsp.rtpInfo.isEmpty {
                        Text(rtsp.rtpInfo).font(.system(size: 10, design: .monospaced))
                    }
                    ForEach(Array(rtsp.log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 10, design: .monospaced))
                    }
                }

                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Last resort (props OFF)").font(.headline)
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
                    Text("Some units only stream while control frames flow. This is the 21-byte frame pyDroneWire sends with all sticks centred and no command bit set. It does not arm, take off or spin motors, but keep propellers off while testing. Sent: \(link.idleSent)")
                        .font(.caption).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("VLC log (stream modules)").font(.headline)
                    if video.logger.lines.isEmpty {
                        Text("nothing yet").foregroundStyle(.secondary)
                    }
                    ForEach(Array(video.logger.lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 10, design: .monospaced))
                    }
                }

                Divider()
                Label("No takeoff, landing, flip or joystick input exists in this build. The only control-port traffic is the keep-alive and, if you switch it on, the centred idle frame above.", systemImage: "shield.checkered")
                    .font(.callout)
            }
            .padding()
        }
        .onDisappear { disconnect() }
    }
}
