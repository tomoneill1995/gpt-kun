import Foundation
import Network
import UIKit
import ImageIO

/// Native RTSP/RTP-JPEG viewer for the drone, no third-party media library.
///
/// Runs OPTIONS, DESCRIBE, SETUP and PLAY against rtsp://host:7070/webcam, receives
/// RTP on its own UDP port, reassembles each JPEG frame with `RTPJPEGAssembler`,
/// decodes it with ImageIO and publishes it as a UIImage. Sends nothing to the drone
/// except RTSP text. The drone answers 461 to TCP interleaving, so UDP only.
final class RTSPClient: ObservableObject {
    @Published var status = "idle"
    @Published var running = false
    @Published var frame: UIImage?
    @Published var frameSize = ""
    @Published var fps = 0.0
    @Published var rtpPackets = 0
    @Published var rtpBytes = 0
    @Published var framesDecoded = 0
    @Published var framesDropped = 0
    @Published var decodeFailures = 0
    @Published var rtpInfo = ""
    @Published var log: [String] = []

    /// Called on the decode queue with every decoded frame, before it is published.
    var onFrame: ((CGImage) -> Void)?

    private let queue = DispatchQueue(label: "gptkun.rtsp")
    private let decodeQueue = DispatchQueue(label: "gptkun.decode", qos: .userInteractive)
    private let assembler = RTPJPEGAssembler()
    private var tcp: NWConnection?
    private var listener: NWListener?
    private var udpConns: [NWConnection] = []
    private var buffer = Data()
    private var cseq = 0
    private var session: String?
    private var host = ""
    private var url = ""
    private var contentBase = ""
    private var keepAlive: DispatchSourceTimer?
    private var watchdog: DispatchSourceTimer?
    private var pendingHandler: ((Int, [String: String], String) -> Void)?
    private var lastPacketAt = Date.distantPast
    private var playedAt = Date.distantPast
    private var decodeBusy = false
    private var fpsWindowStart = Date()
    private var fpsWindowCount = 0
    private var packetCount = 0
    private var byteCount = 0
    private let clientPort: UInt16 = 50000

    // MARK: - Public

    func start(host: String) {
        stop()
        self.host = host
        url = "rtsp://\(host):7070/webcam"
        contentBase = url
        DispatchQueue.main.async {
            self.log = []
            self.rtpPackets = 0
            self.rtpBytes = 0
            self.framesDecoded = 0
            self.framesDropped = 0
            self.decodeFailures = 0
            self.rtpInfo = ""
            self.fps = 0
            self.running = true
            self.status = "connecting"
        }
        packetCount = 0
        byteCount = 0
        lastPacketAt = .distantPast
        playedAt = .distantPast
        emit("start, RTP on UDP \(clientPort)")
        startUDPListener()
        openControlConnection()
        startWatchdog()
    }

    func stop() {
        keepAlive?.cancel(); keepAlive = nil
        watchdog?.cancel(); watchdog = nil
        teardownSession()
        DispatchQueue.main.async {
            self.running = false
            self.status = "idle"
        }
    }

    // MARK: - Session lifecycle

    private func openControlConnection() {
        guard let port = NWEndpoint.Port(rawValue: 7070) else { return }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        tcp = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.emit("tcp 7070 connected")
                self.receiveLoop(conn)
                self.sendOptions()
            case .failed(let e):
                self.emit("tcp failed: \(e.localizedDescription)")
                self.setStatus("control connection failed")
            case .waiting(let e):
                self.emit("tcp waiting: \(e.localizedDescription)")
                self.setStatus("waiting for drone")
            default: break
            }
        }
        conn.start(queue: queue)
    }

    private func teardownSession() {
        if let s = session, tcp != nil {
            send(method: "TEARDOWN", target: url, extra: ["Session": s]) { _, _, _ in }
        }
        let t = tcp
        queue.asyncAfter(deadline: .now() + 0.3) { t?.cancel() }
        tcp = nil
        listener?.cancel(); listener = nil
        udpConns.forEach { $0.cancel() }
        udpConns.removeAll()
        buffer.removeAll()
        session = nil
        pendingHandler = nil
    }

    /// Restart the RTSP session in place if video stops arriving.
    private func startWatchdog() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Date()
            let sinceLast = now.timeIntervalSince(self.lastPacketAt)
            let sincePlay = now.timeIntervalSince(self.playedAt)
            let stalled = (self.lastPacketAt == .distantPast && sincePlay > 6) || (self.lastPacketAt != .distantPast && sinceLast > 4)
            if self.playedAt != .distantPast, stalled {
                self.emit("no video for a while, restarting session")
                self.setStatus("restarting")
                self.keepAlive?.cancel(); self.keepAlive = nil
                self.teardownSession()
                self.lastPacketAt = .distantPast
                self.playedAt = .distantPast
                self.queue.asyncAfter(deadline: .now() + 0.5) {
                    self.startUDPListener()
                    self.openControlConnection()
                }
            }
        }
        t.resume()
        watchdog = t
    }

    // MARK: - RTSP sequence

    private func sendOptions() {
        send(method: "OPTIONS", target: url) { [weak self] code, _, _ in
            guard let self else { return }
            guard code == 200 else { self.emit("OPTIONS failed"); return }
            self.sendDescribe()
        }
    }

    private func sendDescribe() {
        send(method: "DESCRIBE", target: url, extra: ["Accept": "application/sdp"]) { [weak self] code, headers, body in
            guard let self else { return }
            guard code == 200 else { self.emit("DESCRIBE failed"); return }
            if let base = headers["content-base"] ?? headers["content-location"] { self.contentBase = base }
            let control = self.videoControl(fromSDP: body)
            self.emit("sdp: \(body.replacingOccurrences(of: "\r\n", with: " | "))")
            self.sendSetup(control)
        }
    }

    private func sendSetup(_ control: String) {
        let transport = "RTP/AVP;unicast;client_port=\(clientPort)-\(clientPort + 1)"
        send(method: "SETUP", target: control, extra: ["Transport": transport]) { [weak self] code, headers, _ in
            guard let self else { return }
            guard code == 200 else { self.emit("SETUP failed (\(code))"); self.setStatus("SETUP refused \(code)"); return }
            if let s = headers["session"] {
                self.session = String(s.split(separator: ";").first ?? Substring(s))
            }
            self.emit("session \(self.session ?? "none"), \(headers["transport"] ?? "")")
            self.sendPlay()
        }
    }

    private func sendPlay() {
        var extra = ["Range": "npt=0.000-"]
        if let s = session { extra["Session"] = s }
        send(method: "PLAY", target: url, extra: extra) { [weak self] code, _, _ in
            guard let self else { return }
            guard code == 200 else { self.emit("PLAY failed (\(code))"); self.setStatus("PLAY refused \(code)"); return }
            self.emit("PLAY ok")
            self.playedAt = Date()
            self.setStatus("playing, waiting for first frame")
            self.startKeepAlive()
        }
    }

    private func startKeepAlive() {
        keepAlive?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 15, repeating: 15)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            var extra: [String: String] = [:]
            if let s = self.session { extra["Session"] = s }
            self.send(method: "OPTIONS", target: self.url, extra: extra) { _, _, _ in }
        }
        t.resume()
        keepAlive = t
    }

    private func send(method: String, target: String, extra: [String: String] = [:],
                      handler: @escaping (Int, [String: String], String) -> Void) {
        guard let conn = tcp else { return }
        cseq += 1
        var req = "\(method) \(target) RTSP/1.0\r\nCSeq: \(cseq)\r\nUser-Agent: GPTKun/0.4\r\n"
        for (k, v) in extra { req += "\(k): \(v)\r\n" }
        req += "\r\n"
        pendingHandler = handler
        conn.send(content: req.data(using: .utf8), completion: .contentProcessed { [weak self] err in
            if let err { self?.emit("send error: \(err.localizedDescription)") }
        })
    }

    // MARK: - RTSP response parsing

    private func receiveLoop(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drainBuffer()
            }
            if let error {
                self.emit("tcp receive error: \(error.localizedDescription)")
                return
            }
            if isComplete {
                self.emit("tcp closed by drone")
                return
            }
            if self.tcp === conn { self.receiveLoop(conn) }
        }
    }

    private func drainBuffer() {
        while !buffer.isEmpty {
            guard let marker = "\r\n\r\n".data(using: .utf8), let headerEnd = buffer.range(of: marker) else {
                if buffer.count > 65536 { buffer.removeAll() }
                return
            }
            let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
            guard let headerText = String(data: headerData, encoding: .utf8) else { buffer.removeAll(); return }
            var headers: [String: String] = [:]
            let lines = headerText.components(separatedBy: "\r\n")
            for line in lines.dropFirst() {
                if let colon = line.firstIndex(of: ":") {
                    headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                        line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
            }
            let bodyLen = Int(headers["content-length"] ?? "0") ?? 0
            let total = headerData.count + 4 + bodyLen
            guard buffer.count >= total else { return }
            let body = String(data: buffer.subdata(in: headerEnd.upperBound..<(headerEnd.upperBound + bodyLen)), encoding: .utf8) ?? ""
            buffer.removeFirst(total)
            let statusLine = lines.first ?? ""
            let code = Int(statusLine.split(separator: " ").dropFirst().first ?? "0") ?? 0
            emit("< \(statusLine)")
            if let h = pendingHandler {
                pendingHandler = nil
                h(code, headers, body)
            }
        }
    }

    private func videoControl(fromSDP sdp: String) -> String {
        var inVideo = false
        var control: String?
        for raw in sdp.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("m=") { inVideo = line.hasPrefix("m=video") }
            if inVideo, line.hasPrefix("a=control:") {
                control = String(line.dropFirst("a=control:".count))
                break
            }
        }
        guard let c = control, c != "*" else { return contentBase }
        if c.hasPrefix("rtsp://") { return c }
        return contentBase.hasSuffix("/") ? contentBase + c : contentBase + "/" + c
    }

    // MARK: - RTP receive and decode

    private func startUDPListener() {
        guard let port = NWEndpoint.Port(rawValue: clientPort) else { return }
        do {
            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: port)
            l.stateUpdateHandler = { [weak self] state in
                if case .failed(let e) = state { self?.emit("udp listener failed: \(e.localizedDescription)") }
            }
            l.newConnectionHandler = { [weak self] conn in
                guard let self else { return }
                self.udpConns.append(conn)
                conn.start(queue: self.queue)
                self.udpReceive(conn)
            }
            l.start(queue: queue)
            listener = l
        } catch {
            emit("udp listener error: \(error.localizedDescription)")
        }
    }

    private func udpReceive(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.handleRTP(data) }
            if error == nil { self.udpReceive(conn) }
        }
    }

    private func handleRTP(_ packet: Data) {
        lastPacketAt = Date()
        packetCount += 1
        byteCount += packet.count
        if packetCount == 1 { emit("first RTP packet: \(describeRTP(packet))") }
        if packetCount % 25 == 0 {
            let p = packetCount, b = byteCount, d = assembler.dropped
            DispatchQueue.main.async {
                self.rtpPackets = p
                self.rtpBytes = b
                self.framesDropped = d
            }
        }
        guard let jpeg = assembler.push(packet) else { return }
        guard !decodeBusy else { return }       // never queue up stale frames
        decodeBusy = true
        decodeQueue.async { [weak self] in
            guard let self else { return }
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            if let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
               let cg = CGImageSourceCreateImageAtIndex(src, 0, options) {
                self.onFrame?(cg)
                let image = UIImage(cgImage: cg)
                DispatchQueue.main.async {
                    self.frame = image
                    self.framesDecoded += 1
                    self.frameSize = "\(cg.width)x\(cg.height)"
                    self.status = "live"
                    self.fpsWindowCount += 1
                    let elapsed = Date().timeIntervalSince(self.fpsWindowStart)
                    if elapsed >= 1 {
                        self.fps = Double(self.fpsWindowCount) / elapsed
                        self.fpsWindowCount = 0
                        self.fpsWindowStart = Date()
                    }
                }
            } else {
                DispatchQueue.main.async {
                    self.decodeFailures += 1
                    if self.decodeFailures == 1 {
                        let head = jpeg.prefix(24).map { String(format: "%02X", $0) }.joined(separator: " ")
                        self.log.append("decode failed, jpeg \(jpeg.count) B, head \(head)")
                    }
                }
            }
            self.queue.async { self.decodeBusy = false }
        }
    }

    private func describeRTP(_ p: Data) -> String {
        guard p.count >= 20 else { return "short packet \(p.count) B" }
        let b = [UInt8](p)
        let pt = b[1] & 0x7f
        var s = "pt \(pt) len \(p.count)"
        if pt == 26 {
            s += " | JPEG type \(b[16]) Q \(b[17]) \(Int(b[18]) * 8)x\(Int(b[19]) * 8)"
        }
        return s
    }

    private func setStatus(_ s: String) {
        DispatchQueue.main.async { self.status = s }
    }

    private func emit(_ line: String) {
        DispatchQueue.main.async {
            self.log.append(line)
            if self.log.count > 30 { self.log.removeFirst(self.log.count - 30) }
        }
    }
}
