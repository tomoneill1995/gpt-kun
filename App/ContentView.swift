import SwiftUI
import MobileVLCKit

// VIDEO ONLY: no flight command transport or motor controls exist in this app.
// The only packet ever sent is the 2-byte keep-alive in DroneLink.
final class VideoSession: ObservableObject {
    @Published var status = "Disconnected"
    @Published var playing = false
    let player = VLCMediaPlayer()
    private var poll: Timer?

    func attach(_ view: UIView) {
        player.drawable = view
    }

    func start(host: String) {
        stop()
        guard let url = URL(string: "rtsp://\(host):7070/webcam") else { return }
        let media = VLCMedia(url: url)
        // Low latency settings; the toy streams MJPEG over RTP/UDP.
        media.addOptions([
            "network-caching": 150,
            "rtsp-caching": 150,
            "clock-jitter": 0,
            "clock-synchro": 0
        ])
        player.media = media
        status = "Connecting to \(url.absoluteString)"
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
    }

    private func refresh() {
        switch player.state {
        case .playing:
            playing = true
            status = "Receiving video"
        case .buffering, .opening:
            status = "Connecting / buffering"
        case .error:
            playing = false
            status = "Stream failed: wrong variant, IP, or no keep-alive"
        case .stopped, .ended:
            playing = false
            status = "Stopped"
        default:
            break
        }
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
    @AppStorage("droneHost") private var droneHost = "192.168.1.1"
    @AppStorage("sendHeartbeat") private var sendHeartbeat = true
    @AppStorage("rotation") private var rotation = 0.0

    private var hostIsValid: Bool {
        let h = droneHost.trimmingCharacters(in: .whitespacesAndNewlines)
        return !h.isEmpty && h.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("GPT-kun's Eyes")
                    .font(.largeTitle.bold())
                Text("Experiment 001 - Camera only")
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
                    Text("Use the Router address from Settings > Wi-Fi > (i). 192.168.1.1 means the RTSP type this app targets. 192.168.169.1 means the custom-UDP type, which this build cannot show yet.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Button("Probe drone type") {
                        probe.check(host: droneHost.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    .buttonStyle(.bordered)
                    .disabled(!hostIsValid)
                    Text(probe.result).font(.footnote.monospaced())
                }

                Toggle("Send 1 s keep-alive to UDP 7099 (required on KY UFO)", isOn: $sendHeartbeat)
                    .font(.callout)

                Picker("Rotate", selection: $rotation) {
                    Text("0").tag(0.0)
                    Text("90").tag(90.0)
                    Text("180").tag(180.0)
                    Text("270").tag(270.0)
                }
                .pickerStyle(.segmented)

                HStack(spacing: 12) {
                    Button("Connect video") {
                        let host = droneHost.trimmingCharacters(in: .whitespacesAndNewlines)
                        if sendHeartbeat { link.start(host: host) }
                        video.start(host: host)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hostIsValid)
                    Button("Disconnect") { video.stop(); link.stop() }
                        .buttonStyle(.bordered)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("video: \(video.status)")
                    Text("link: \(link.state)")
                    Text("drone replies: \(link.repliesSeen)  last: \(link.lastReplyHex.isEmpty ? "-" : link.lastReplyHex)")
                }
                .font(.footnote.monospaced())

                Divider()
                Label("No motor, takeoff, landing, or joystick commands exist in this build.", systemImage: "shield.checkered")
                    .font(.callout)
                Text("Connect the iPhone to the drone's Wi-Fi first and close the KY UFO app; the drone serves one client. Replies on the link line prove the drone is the cooingdv type even if video stays black.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding()
        }
        .onDisappear { video.stop(); link.stop() }
    }
}
