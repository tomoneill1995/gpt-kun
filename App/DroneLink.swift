import Foundation
import Network

/// UDP link to the drone's control port (192.168.1.1:7099).
///
/// Two kinds of traffic go out on it:
/// - the 2-byte keep-alive `01 01` once a second, which the drone needs before it
///   serves video at all;
/// - optionally, the 21-byte GL control frame at 20 Hz, which is what the stock app
///   sends while it is the drone's controller. Sticks are held centred in this build;
///   only the command byte changes, and only `FlightController` changes it.
final class DroneLink: ObservableObject {
    @Published var state = "idle"
    @Published var lastReplyHex = ""
    @Published var repliesSeen = 0
    @Published var lastReplyAt: Date = .distantPast
    @Published var framesSent = 0
    @Published var controlRunning = false

    /// Command bits in byte 7 of the GL frame. pyDroneWire, turbodrone and RC-Swamp
    /// agree on the two this app uses.
    static let cmdNone: UInt8 = 0x00
    static let cmdTakeoffLand: UInt8 = 0x01   // one-key takeoff when landed, land when flying
    static let cmdEmergencyStop: UInt8 = 0x02 // cuts the motors immediately
    // Gyro calibration: sources disagree for this frame layout. pyDroneWire (same
    // drone) uses 0x80; turbodrone and RC-Swamp list 0x04 for the GL variant.
    static let cmdCalibrateA: UInt8 = 0x80
    static let cmdCalibrateB: UInt8 = 0x04

    private var connection: NWConnection?
    private var timer: DispatchSourceTimer?
    private var controlTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "gptkun.dronelink")
    private let heartbeat = Data([0x01, 0x01])
    private var command: UInt8 = 0x00          // only touched on `queue`
    // Stick offsets from centre, in frame units (-127...127). Only touched on `queue`.
    private var trimRoll = 0, trimPitch = 0
    private var nudgeRoll = 0, nudgePitch = 0

    // MARK: - Keep-alive

    func start(host: String, port: UInt16 = 7099) {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        connection = conn

        conn.stateUpdateHandler = { [weak self] newState in
            DispatchQueue.main.async {
                switch newState {
                case .ready: self?.state = "keep-alive running"
                case .waiting(let err): self?.state = "waiting: \(err.localizedDescription)"
                case .failed(let err): self?.state = "failed: \(err.localizedDescription)"
                case .cancelled: self?.state = "idle"
                default: break
                }
            }
        }
        conn.start(queue: queue)
        receiveLoop(conn)

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .seconds(1))
        t.setEventHandler { [weak self] in
            guard let self, let c = self.connection else { return }
            c.send(content: self.heartbeat, completion: .contentProcessed { _ in })
        }
        t.resume()
        timer = t
    }

    func stop() {
        stopControlFrames()
        timer?.cancel(); timer = nil
        connection?.cancel(); connection = nil
        DispatchQueue.main.async { self.state = "idle" }
    }

    var isUp: Bool { connection != nil }

    // MARK: - Control frames

    /// Start the 20 Hz control stream with sticks centred and no command.
    func startControlFrames() {
        stopControlFrames()
        queue.async { self.command = Self.cmdNone }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(50))
        t.setEventHandler { [weak self] in
            guard let self, let c = self.connection else { return }
            c.send(content: self.buildFrame(command: self.command), completion: .contentProcessed { _ in })
            DispatchQueue.main.async { self.framesSent += 1 }
        }
        t.resume()
        controlTimer = t
        DispatchQueue.main.async { self.controlRunning = true }
    }

    func stopControlFrames() {
        controlTimer?.cancel(); controlTimer = nil
        queue.async { self.command = Self.cmdNone; self.nudgeRoll = 0; self.nudgePitch = 0 }
        DispatchQueue.main.async { self.controlRunning = false }
    }

    /// Set the command bits carried by every following frame until changed again.
    func setCommand(_ cmd: UInt8) {
        queue.async { self.command = cmd }
    }

    /// Persistent correction added to the centred sticks (positive roll = right,
    /// positive pitch = forward, per pyDroneWire's reading of the protocol).
    func setTrim(roll: Int, pitch: Int) {
        queue.async { self.trimRoll = roll; self.trimPitch = pitch }
    }

    /// Momentary deflection while a nudge button is held. Zero when released.
    func setNudge(roll: Int, pitch: Int) {
        queue.async { self.nudgeRoll = roll; self.nudgePitch = pitch }
    }

    /// pyDroneWire's 21-byte GL frame: 03 66 14, roll, pitch, throttle, yaw, cmd, 0x02,
    /// ten zero bytes, checksum (XOR of bytes 3...18), 0x99. Throttle and yaw stay centred.
    private func buildFrame(command: UInt8) -> Data {
        func stick(_ offset: Int) -> UInt8 { UInt8(max(1, min(255, 0x80 + offset))) }
        let roll = stick(trimRoll + nudgeRoll)
        let pitch = stick(trimPitch + nudgePitch)
        let throttle: UInt8 = 0x80, yaw: UInt8 = 0x80
        let flags2: UInt8 = 0x02
        let checksum = roll ^ pitch ^ throttle ^ yaw ^ command ^ flags2
        return Data([0x03, 0x66, 0x14,
                     roll, pitch, throttle, yaw,
                     command, flags2,
                     0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                     checksum, 0x99])
    }

    // MARK: - Replies

    /// The drone answers several times a second with 11 bytes of telemetry.
    private func receiveLoop(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
                DispatchQueue.main.async {
                    self.lastReplyHex = hex
                    self.repliesSeen += 1
                    self.lastReplyAt = Date()
                }
            }
            if error == nil, self.connection === conn { self.receiveLoop(conn) }
        }
    }
}

/// One-shot TCP connect test. The RTSP-type drones accept a TCP connection on 7070;
/// the custom-UDP (flowufo) type refuses it.
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
            case .ready:
                finish("TCP \(port) OPEN: RTSP-type drone")
            case .failed(let err):
                finish("TCP \(port) closed (\(err.localizedDescription))")
            case .waiting(let err):
                finish("TCP \(port) refused (\(err.localizedDescription))")
            default:
                break
            }
        }
        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) {
            finish("TCP \(port): no answer in \(Int(timeout)) s")
        }
    }
}
