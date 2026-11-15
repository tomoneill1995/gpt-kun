import Foundation
import Network

/// Which toy-drone dialect the control and video layers speak.
enum DroneProfile: String, CaseIterable, Identifiable {
    /// KY UFO / FLOW-UFO (cooingdv): 192.168.1.1, RTSP 7070, control UDP 7099,
    /// 21-byte GL frame, `01 01` keep-alive once a second.
    case cooingdv
    /// WiFi CAM app (TZH): 192.168.4.153, video UDP 8080 (complete JPEG chunks),
    /// control UDP 8090, 8-byte short frame (20-byte extended on camera type 2).
    case wifiCam

    var id: String { rawValue }
    var title: String {
        switch self {
        case .cooingdv: return "KY UFO / FLOW-UFO (RTSP)"
        case .wifiCam: return "WiFi CAM (UDP JPEG)"
        }
    }
    var defaultHost: String {
        switch self {
        case .cooingdv: return "192.168.1.1"
        case .wifiCam: return "192.168.4.153"
        }
    }
    var controlPort: UInt16 {
        switch self {
        case .cooingdv: return 7099
        case .wifiCam: return 8090
        }
    }
    static func guess(forHost host: String) -> DroneProfile {
        host.hasPrefix("192.168.4.") ? .wifiCam : .cooingdv
    }
}

/// Semantic commands; each profile maps them to its own flag bits.
enum LinkCommand {
    case none, takeoff, land, emergency, calibrateA, calibrateB
}

/// UDP link to the drone's control port.
///
/// Two kinds of traffic go out on it:
/// - for cooingdv, the 2-byte keep-alive `01 01` once a second, which the drone
///   needs before it serves video at all (WiFi CAM has no known keep-alive);
/// - optionally, the control frame at 20 Hz, which is what the stock apps send
///   while they are the drone's controller. Sticks are centred unless the hover
///   offsets (trim, nudge, auto-hold, scan yaw) are enabled.
final class DroneLink: ObservableObject {
    @Published var state = "idle"
    @Published var lastReplyHex = ""
    @Published var repliesSeen = 0
    @Published var lastReplyAt: Date = .distantPast
    @Published var framesSent = 0
    @Published var controlRunning = false
    @Published var currentSticks = "roll 80 pitch 80 thr 80 yaw 80 cmd 00"
    /// Distinct telemetry values seen, newest last, with first-seen time and count.
    @Published var replyHistory: [(time: String, hex: String, count: Int)] = []

    private(set) var profile: DroneProfile = .cooingdv
    /// WiFi CAM: camera type reported on the video socket (1 = short frames, 2 = extended).
    var wifiCamCameraType: UInt8 = 1

    private var connection: NWConnection?
    private var timer: DispatchSourceTimer?
    private var controlTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "gptkun.dronelink")
    private let heartbeat = Data([0x01, 0x01])
    private var command: LinkCommand = .none       // only touched on `queue`
    private var trimRoll = 0, trimPitch = 0
    private var nudgeRoll = 0, nudgePitch = 0
    private var autoRoll = 0, autoPitch = 0
    private var yawOffset = 0
    private var offsetsEnabled = false
    private var frameCounter = 0

    // MARK: - Lifecycle

    func start(host: String, profile: DroneProfile) {
        stop()
        self.profile = profile
        guard let nwPort = NWEndpoint.Port(rawValue: profile.controlPort) else { return }
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        connection = conn

        conn.stateUpdateHandler = { [weak self] newState in
            DispatchQueue.main.async {
                switch newState {
                case .ready: self?.state = profile == .cooingdv ? "keep-alive running" : "control socket ready"
                case .waiting(let err): self?.state = "waiting: \(err.localizedDescription)"
                case .failed(let err): self?.state = "failed: \(err.localizedDescription)"
                case .cancelled: self?.state = "idle"
                default: break
                }
            }
        }
        conn.start(queue: queue)
        receiveLoop(conn)

        if profile == .cooingdv {
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: .seconds(1))
            t.setEventHandler { [weak self] in
                guard let self, let c = self.connection else { return }
                c.send(content: self.heartbeat, completion: .contentProcessed { _ in })
            }
            t.resume()
            timer = t
        }
    }

    func stop() {
        stopControlFrames()
        timer?.cancel(); timer = nil
        connection?.cancel(); connection = nil
        DispatchQueue.main.async { self.state = "idle" }
    }

    var isUp: Bool { connection != nil }

    /// Video layers call this when the drone is clearly alive (WiFi CAM sends no
    /// control-port telemetry, so its video datagrams stand in for it).
    func noteAlive() {
        DispatchQueue.main.async { self.lastReplyAt = Date() }
    }

    // MARK: - Control frames

    func startControlFrames() {
        stopControlFrames()
        queue.async { self.command = .none }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(50))
        t.setEventHandler { [weak self] in
            guard let self, let c = self.connection else { return }
            c.send(content: self.buildFrame(), completion: .contentProcessed { _ in })
            DispatchQueue.main.async { self.framesSent += 1 }
        }
        t.resume()
        controlTimer = t
        DispatchQueue.main.async { self.controlRunning = true }
    }

    func stopControlFrames() {
        controlTimer?.cancel(); controlTimer = nil
        queue.async {
            self.command = .none
            self.nudgeRoll = 0; self.nudgePitch = 0
            self.autoRoll = 0; self.autoPitch = 0
            self.yawOffset = 0
            self.offsetsEnabled = false
        }
        DispatchQueue.main.async { self.controlRunning = false }
    }

    func setCommand(_ cmd: LinkCommand) { queue.async { self.command = cmd } }
    func setTrim(roll: Int, pitch: Int) { queue.async { self.trimRoll = roll; self.trimPitch = pitch } }
    func setNudge(roll: Int, pitch: Int) { queue.async { self.nudgeRoll = roll; self.nudgePitch = pitch } }
    func setAuto(roll: Int, pitch: Int) { queue.async { self.autoRoll = roll; self.autoPitch = pitch } }
    func setYaw(_ offset: Int) { queue.async { self.yawOffset = offset } }
    func setOffsetsEnabled(_ on: Bool) { queue.async { self.offsetsEnabled = on } }

    /// Send one arbitrary datagram on the control port.
    func sendRaw(_ data: Data) {
        queue.async { [weak self] in
            guard let c = self?.connection else { return }
            c.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    // MARK: - Frame builders (on `queue`)

    private func sticks() -> (roll: UInt8, pitch: UInt8, throttle: UInt8, yaw: UInt8) {
        func stick(_ offset: Int) -> UInt8 { UInt8(max(1, min(255, 0x80 + offset))) }
        let roll = offsetsEnabled ? stick(trimRoll + nudgeRoll + autoRoll) : 0x80
        let pitch = offsetsEnabled ? stick(trimPitch + nudgePitch + autoPitch) : 0x80
        let yaw = offsetsEnabled ? stick(yawOffset) : 0x80
        return (roll, pitch, 0x80, yaw)
    }

    private func buildFrame() -> Data {
        let s = sticks()
        let frame: Data
        let cmdByte: UInt8
        switch profile {
        case .cooingdv:
            cmdByte = cooingdvBits(command)
            frame = buildGL(s, cmd: cmdByte)
        case .wifiCam:
            if wifiCamCameraType == 2 {
                let (f1, f2) = wifiCamExtendedBits(command)
                cmdByte = f1
                frame = buildWifiCamExtended(s, flags1: f1, flags2: f2)
            } else {
                cmdByte = wifiCamShortBits(command)
                frame = buildWifiCamShort(s, flags: cmdByte)
            }
        }
        frameCounter += 1
        if frameCounter % 5 == 0 {
            let text = String(format: "roll %02X pitch %02X thr %02X yaw %02X cmd %02X", s.roll, s.pitch, s.throttle, s.yaw, cmdByte)
            DispatchQueue.main.async { self.currentSticks = text }
        }
        return frame
    }

    /// pyDroneWire's 21-byte GL frame: 03 66 14, roll, pitch, throttle, yaw, cmd, 0x02,
    /// ten zero bytes, checksum (XOR of bytes 3...18), 0x99.
    private func buildGL(_ s: (roll: UInt8, pitch: UInt8, throttle: UInt8, yaw: UInt8), cmd: UInt8) -> Data {
        let flags2: UInt8 = 0x02
        let checksum = s.roll ^ s.pitch ^ s.throttle ^ s.yaw ^ cmd ^ flags2
        return Data([0x03, 0x66, 0x14,
                     s.roll, s.pitch, s.throttle, s.yaw,
                     cmd, flags2,
                     0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                     checksum, 0x99])
    }

    private func cooingdvBits(_ c: LinkCommand) -> UInt8 {
        switch c {
        case .none: return 0x00
        case .takeoff, .land: return 0x01      // one bit, toggles with the drone's state
        case .emergency: return 0x02
        case .calibrateA: return 0x80
        case .calibrateB: return 0x04
        }
    }

    /// WiFi CAM rule: an axis or checksum byte equal to a marker (0x66 / 0x99) is bumped by one.
    private func rightData(_ v: UInt8) -> UInt8 { (v == 0x66 || v == 0x99) ? v &+ 1 : v }

    /// 8 bytes: 66, roll, pitch, throttle, yaw, flags, XOR(bytes 1...5), 99.
    private func buildWifiCamShort(_ s: (roll: UInt8, pitch: UInt8, throttle: UInt8, yaw: UInt8), flags: UInt8) -> Data {
        let r = rightData(s.roll), p = rightData(s.pitch), t = rightData(s.throttle), y = rightData(s.yaw)
        let checksum = rightData(r ^ p ^ t ^ y ^ flags)
        return Data([0x66, r, p, t, y, flags, checksum, 0x99])
    }

    private func wifiCamShortBits(_ c: LinkCommand) -> UInt8 {
        switch c {
        case .none: return 0x00
        case .takeoff: return 0x01
        case .land: return 0x02
        case .emergency: return 0x04
        case .calibrateA, .calibrateB: return 0x80  // 0x04 is emergency in short mode
        }
    }

    /// 20 bytes: 66 14, roll, pitch, throttle, yaw, flags1, flags2, ten zeros, XOR(bytes 2...17), 99.
    private func buildWifiCamExtended(_ s: (roll: UInt8, pitch: UInt8, throttle: UInt8, yaw: UInt8), flags1: UInt8, flags2: UInt8) -> Data {
        let r = rightData(s.roll), p = rightData(s.pitch), t = rightData(s.throttle), y = rightData(s.yaw)
        let checksum = rightData(r ^ p ^ t ^ y ^ flags1 ^ flags2)
        return Data([0x66, 0x14, r, p, t, y, flags1, flags2,
                     0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                     checksum, 0x99])
    }

    private func wifiCamExtendedBits(_ c: LinkCommand) -> (UInt8, UInt8) {
        let altitudeHold: UInt8 = 0x02
        switch c {
        case .none: return (0x00, altitudeHold)
        case .takeoff, .land: return (0x01, altitudeHold)
        case .emergency: return (0x02, altitudeHold)
        case .calibrateA, .calibrateB: return (0x04, altitudeHold)
        }
    }

    // MARK: - Replies

    private func receiveLoop(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
                DispatchQueue.main.async {
                    self.lastReplyHex = hex
                    self.repliesSeen += 1
                    self.lastReplyAt = Date()
                    if let i = self.replyHistory.lastIndex(where: { $0.hex == hex }) {
                        self.replyHistory[i].count += 1
                    } else {
                        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
                        self.replyHistory.append((time: stamp, hex: hex, count: 1))
                        if self.replyHistory.count > 24 { self.replyHistory.removeFirst() }
                    }
                }
            }
            if error == nil, self.connection === conn { self.receiveLoop(conn) }
        }
    }
}

/// One-shot TCP connect test for the RTSP-type drones (port 7070 open).
final class PortProbe: ObservableObject {
    @Published var result = "not run"
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "gptkun.portprobe")

    func check(host: String, port: UInt16 = 7070, timeout: TimeInterval = 4) {
        connection?.cancel()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        connection = conn
        result = "checking TCP \(host):\(port)"

        var settled = false
        let finish: (String) -> Void = { [weak self] text in
            guard !settled else { return }
            settled = true
            conn.cancel()
            DispatchQueue.main.async { self?.result = text }
        }

        conn.stateUpdateHandler = { newState in
            switch newState {
            case .ready: finish("TCP \(port) OPEN: RTSP-type drone")
            case .failed(let err): finish("TCP \(port) closed (\(err.localizedDescription))")
            case .waiting(let err): finish("TCP \(port) refused (\(err.localizedDescription))")
            default: break
            }
        }
        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) {
            finish("TCP \(port): no answer in \(Int(timeout)) s")
        }
    }
}
