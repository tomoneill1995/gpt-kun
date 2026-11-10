import Foundation
import Network

/// UDP link to the drone's control/heartbeat port.
///
/// KY UFO / FLOW-UFO drones at 192.168.1.1 only serve their RTSP stream while a client
/// is sending a keep-alive of bytes `01 01` to UDP 7099 once per second (pyDroneWire,
/// e88-drone-pc-control, OpenIPC decoder all agree). This class sends ONLY that
/// keep-alive. It never sends a stick, takeoff, land or flip packet; the flight packet
/// format is deliberately not in this app.
final class DroneLink: ObservableObject {
    @Published var state = "idle"
    @Published var lastReplyHex = ""
    @Published var repliesSeen = 0

    private var connection: NWConnection?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "gptkun.dronelink")
    private let heartbeat = Data([0x01, 0x01])

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
        timer?.cancel(); timer = nil
        connection?.cancel(); connection = nil
        DispatchQueue.main.async { self.state = "idle" }
    }

    /// The drone answers roughly once a second with a few bytes of telemetry.
    /// Seeing any reply proves we are talking to a cooingdv-family drone.
    private func receiveLoop(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
                DispatchQueue.main.async {
                    self.lastReplyHex = hex
                    self.repliesSeen += 1
                }
            }
            if error == nil, self.connection === conn { self.receiveLoop(conn) }
        }
    }
}

/// One-shot TCP connect test. The RTSP-type drones accept a TCP connection on 7070;
/// the custom-UDP (flowufo) type refuses it. This is the cheapest way to tell them
/// apart from an iPhone with no PC available.
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
                finish("TCP \(port) OPEN: RTSP-type drone, this app should work")
            case .failed(let err):
                finish("TCP \(port) closed (\(err.localizedDescription)): not the RTSP type")
            case .waiting(let err):
                // A refused connection lands here and would retry forever; treat as closed.
                finish("TCP \(port) refused (\(err.localizedDescription)): not the RTSP type")
            default:
                break
            }
        }
        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) {
            finish("TCP \(port): no answer in \(Int(timeout)) s. Wrong IP, or not the RTSP type")
        }
    }
}
