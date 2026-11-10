import Foundation
import Network

/// Minimal RTSP client used as a diagnostic, independent of VLC.
///
/// It performs OPTIONS, DESCRIBE, SETUP and PLAY against rtsp://host:7070/webcam,
/// shows every response on screen, and counts the RTP packets that arrive either
/// on its own UDP port (default) or interleaved on the RTSP TCP socket.
/// It sends nothing to the drone except RTSP text.
final class RTSPProbe: ObservableObject {
    @Published var log: [String] = []
    @Published var rtpPackets = 0
    @Published var rtpBytes = 0
    @Published var rtpInfo = ""
    @Published var running = false

    private let queue = DispatchQueue(label: "gptkun.rtspprobe")
    private var tcp: NWConnection?
    private var listener: NWListener?
    private var udpConns: [NWConnection] = []
    private var buffer = Data()
    private var cseq = 0
    private var session: String?
    private var useTCP = false
    private var url = ""
    private var contentBase = ""
    private var keepAlive: DispatchSourceTimer?
    private var pendingHandler: ((Int, [String: String], String) -> Void)?
    private let clientPort: UInt16 = 50000

    // MARK: - Public

    func start(host: String, overTCP: Bool) {
        stop()
        useTCP = overTCP
        url = "rtsp://\(host):7070/webcam"
        contentBase = url
        DispatchQueue.main.async {
            self.log = []
            self.rtpPackets = 0
            self.rtpBytes = 0
            self.rtpInfo = ""
            self.running = true
        }
        emit("probe start \(overTCP ? "TCP interleaved" : "UDP port \(clientPort)")")

        if !overTCP { startUDPListener() }

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
            case .waiting(let e):
                self.emit("tcp waiting: \(e.localizedDescription)")
            default: break
            }
        }
        conn.start(queue: queue)
    }

    func stop() {
        keepAlive?.cancel(); keepAlive = nil
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
        DispatchQueue.main.async { self.running = false }
    }

    // MARK: - RTSP sequence

    private func sendOptions() {
        send(method: "OPTIONS", target: url) { [weak self] code, _, _ in
            guard let self else { return }
            guard code == 200 else { self.emit("OPTIONS failed, stopping"); return }
            self.sendDescribe()
        }
    }

    private func sendDescribe() {
        send(method: "DESCRIBE", target: url, extra: ["Accept": "application/sdp"]) { [weak self] code, headers, body in
            guard let self else { return }
            guard code == 200 else { self.emit("DESCRIBE failed, stopping"); return }
            if let base = headers["content-base"] ?? headers["content-location"] { self.contentBase = base }
            for line in body.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) where !line.isEmpty {
                self.emit("sdp \(line)")
            }
            let control = self.videoControl(fromSDP: body)
            self.emit("video control url: \(control)")
            self.sendSetup(control)
        }
    }

    private func sendSetup(_ control: String) {
        let transport = useTCP
            ? "RTP/AVP/TCP;unicast;interleaved=0-1"
            : "RTP/AVP;unicast;client_port=\(clientPort)-\(clientPort + 1)"
        send(method: "SETUP", target: control, extra: ["Transport": transport]) { [weak self] code, headers, _ in
            guard let self else { return }
            guard code == 200 else { self.emit("SETUP failed (\(code)), stopping"); return }
            if let s = headers["session"] {
                self.session = String(s.split(separator: ";").first ?? Substring(s))
            }
            self.emit("session: \(self.session ?? "none"); transport: \(headers["transport"] ?? "none")")
            self.sendPlay()
        }
    }

    private func sendPlay() {
        var extra = ["Range": "npt=0.000-"]
        if let s = session { extra["Session"] = s }
        send(method: "PLAY", target: url, extra: extra) { [weak self] code, headers, _ in
            guard let self else { return }
            guard code == 200 else { self.emit("PLAY failed (\(code)), stopping"); return }
            self.emit("PLAY ok. RTP-Info: \(headers["rtp-info"] ?? "none"). Counting packets...")
            self.startKeepAlive()
        }
    }

    private func startKeepAlive() {
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
        var req = "\(method) \(target) RTSP/1.0\r\nCSeq: \(cseq)\r\nUser-Agent: GPTKun/0.3\r\n"
        for (k, v) in extra { req += "\(k): \(v)\r\n" }
        req += "\r\n"
        pendingHandler = handler
        emit("> \(method) \(target)")
        conn.send(content: req.data(using: .utf8), completion: .contentProcessed { [weak self] err in
            if let err { self?.emit("send error: \(err.localizedDescription)") }
        })
    }

    // MARK: - TCP receive and parsing

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
            if buffer[buffer.startIndex] == 0x24 { // '$' interleaved frame
                guard buffer.count >= 4 else { return }
                let channel = buffer[buffer.startIndex + 1]
                let len = Int(buffer[buffer.startIndex + 2]) << 8 | Int(buffer[buffer.startIndex + 3])
                guard buffer.count >= 4 + len else { return }
                let payload = buffer.subdata(in: (buffer.startIndex + 4)..<(buffer.startIndex + 4 + len))
                buffer.removeFirst(4 + len)
                if channel == 0 { countRTP(payload) }
                continue
            }
            guard let headerEnd = range(of: "\r\n\r\n", in: buffer) else {
                if buffer.count > 65536 { buffer.removeAll(); emit("buffer overflow, cleared") }
                return
            }
            let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
            guard let headerText = String(data: headerData, encoding: .utf8) else {
                buffer.removeAll(); emit("non-text data on RTSP socket, cleared"); return
            }
            var headers: [String: String] = [:]
            let lines = headerText.components(separatedBy: "\r\n")
            for line in lines.dropFirst() {
                if let colon = line.firstIndex(of: ":") {
                    let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    headers[key] = value
                }
            }
            let bodyLen = Int(headers["content-length"] ?? "0") ?? 0
            let total = headerData.count + 4 + bodyLen
            guard buffer.count >= total else { return }
            let bodyData = buffer.subdata(in: headerEnd.upperBound..<(headerEnd.upperBound + bodyLen))
            buffer.removeFirst(total)
            let body = String(data: bodyData, encoding: .utf8) ?? ""
            let statusLine = lines.first ?? ""
            let code = Int(statusLine.split(separator: " ").dropFirst().first ?? "0") ?? 0
            emit("< \(statusLine)")
            for key in ["public", "transport", "session", "content-base", "rtp-info"] {
                if let v = headers[key] { emit("  \(key): \(v)") }
            }
            if let h = pendingHandler {
                pendingHandler = nil
                h(code, headers, body)
            }
        }
    }

    private func range(of marker: String, in data: Data) -> Range<Data.Index>? {
        guard let m = marker.data(using: .utf8) else { return nil }
        return data.range(of: m)
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

    // MARK: - UDP RTP receive

    private func startUDPListener() {
        guard let port = NWEndpoint.Port(rawValue: clientPort) else { return }
        do {
            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: port)
            l.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.emit("udp listener ready on \(port)")
                case .failed(let e): self?.emit("udp listener failed: \(e.localizedDescription)")
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] conn in
                guard let self else { return }
                self.udpConns.append(conn)
                self.emit("udp traffic from \(conn.endpoint)")
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
            if let data, !data.isEmpty { self.countRTP(data) }
            if error == nil { self.udpReceive(conn) }
        }
    }

    private func countRTP(_ packet: Data) {
        let n = rtpPackets + 1
        var info = rtpInfo
        if n == 1 || n % 50 == 0 {
            info = describeRTP(packet)
        }
        DispatchQueue.main.async {
            self.rtpPackets = n
            self.rtpBytes += packet.count
            self.rtpInfo = info
        }
    }

    private func describeRTP(_ p: Data) -> String {
        guard p.count >= 12 else { return "short packet \(p.count) B" }
        let b = [UInt8](p)
        let version = b[0] >> 6
        let marker = (b[1] & 0x80) != 0
        let pt = b[1] & 0x7f
        let seq = Int(b[2]) << 8 | Int(b[3])
        var s = "RTP v\(version) pt \(pt) seq \(seq) marker \(marker) len \(p.count)"
        if pt == 26, p.count >= 20 {
            // RFC 2435 JPEG header: type-specific, 24-bit offset, type, Q, width/8, height/8
            let offset = Int(b[13]) << 16 | Int(b[14]) << 8 | Int(b[15])
            s += " | JPEG type \(b[16]) Q \(b[17]) \(Int(b[18]) * 8)x\(Int(b[19]) * 8) offset \(offset)"
        }
        let head = b.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
        return s + "\n" + head
    }

    private func emit(_ line: String) {
        DispatchQueue.main.async {
            self.log.append(line)
            if self.log.count > 60 { self.log.removeFirst(self.log.count - 60) }
        }
    }
}
