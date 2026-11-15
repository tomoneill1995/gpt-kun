import Foundation
import Network
import UIKit
import ImageIO

/// Video for the WiFi CAM (TZH) family, as reverse-engineered in turbodrone's
/// `wifi_cam` backend.
///
/// The phone sends `42 76` to UDP 192.168.4.153:8080 and the drone answers with
/// 1472-byte datagrams: an 8-byte header (frame id, last-chunk flag, chunk count,
/// resolution code, three unused bytes, a "retain" byte) followed by 1464 bytes of a
/// complete JPEG file split into chunks. No ACKs. An 8-byte datagram `55 .. 99` on
/// the same socket reports the camera type (byte 2), which decides the control frame
/// format. `42 77` stops, `42 78` rotates, `42 79` switches camera, all without
/// reopening anything.
final class WiFiCamVideo: ObservableObject {
    @Published var status = "idle"
    @Published var running = false
    @Published var frame: UIImage?
    @Published var frameSize = ""
    @Published var fps = 0.0
    @Published var packets = 0
    @Published var bytes = 0
    @Published var framesDecoded = 0
    @Published var framesDropped = 0
    @Published var decodeFailures = 0
    @Published var cameraType: UInt8 = 0
    @Published var log: [String] = []

    /// Called on the decode queue with every decoded frame, before it is published.
    var onFrame: ((CGImage) -> Void)?
    /// Called on every datagram so the link layer can treat the drone as alive.
    var onAlive: (() -> Void)?
    /// Called when the drone reports its camera type.
    var onCameraType: ((UInt8) -> Void)?

    static let startStream = Data([0x42, 0x76])
    static let stopStream = Data([0x42, 0x77])
    static let rotate = Data([0x42, 0x78])
    static let switchCamera = Data([0x42, 0x79])

    private let queue = DispatchQueue(label: "gptkun.wificam")
    private let decodeQueue = DispatchQueue(label: "gptkun.wificam.decode", qos: .userInteractive)
    private var connection: NWConnection?
    private var watchdog: DispatchSourceTimer?
    private var lastPacketAt = Date.distantPast
    private var decodeBusy = false
    private var fpsWindowStart = Date()
    private var fpsWindowCount = 0
    private var packetCount = 0
    private var byteCount = 0
    private var dropped = 0

    private let headerSize = 8
    private let chunkSize = 0x5B8
    private var buffer = Data()
    private var currentFrameId: UInt8?
    private var chunkIndex = 0

    func start(host: String) {
        stop()
        guard let port = NWEndpoint.Port(rawValue: 8080) else { return }
        DispatchQueue.main.async {
            self.log = []
            self.packets = 0; self.bytes = 0
            self.framesDecoded = 0; self.framesDropped = 0; self.decodeFailures = 0
            self.fps = 0
            self.running = true
            self.status = "connecting"
        }
        packetCount = 0; byteCount = 0; dropped = 0
        lastPacketAt = .distantPast
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        let conn = NWConnection(host: NWEndpoint.Host(host), port: port, using: params)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.emit("udp 8080 ready, sending start 42 76")
                self.send(Self.startStream)
                self.setStatus("waiting for first frame")
                self.receive(conn)
            case .failed(let e): self.emit("udp failed: \(e.localizedDescription)")
            case .waiting(let e): self.emit("udp waiting: \(e.localizedDescription)")
            default: break
            }
        }
        conn.start(queue: queue)
        startWatchdog()
    }

    func stop() {
        watchdog?.cancel(); watchdog = nil
        if connection != nil { send(Self.stopStream) }
        let c = connection
        queue.asyncAfter(deadline: .now() + 0.2) { c?.cancel() }
        connection = nil
        buffer.removeAll()
        currentFrameId = nil
        DispatchQueue.main.async {
            self.running = false
            self.status = "idle"
        }
    }

    /// Camera switch is a single datagram; the stream keeps running.
    func switchCameraNow() { send(Self.switchCamera); emit("camera switch 42 79") }
    func rotateNow() { send(Self.rotate); emit("rotate 42 78") }

    private func send(_ data: Data) {
        queue.async { [weak self] in
            guard let c = self?.connection else { return }
            c.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    private func startWatchdog() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 3, repeating: 3)
        t.setEventHandler { [weak self] in
            guard let self, self.connection != nil else { return }
            if Date().timeIntervalSince(self.lastPacketAt) > 3 {
                self.emit("no datagrams for 3 s, re-sending start")
                self.send(Self.startStream)
            }
        }
        t.resume()
        watchdog = t
    }

    private func receive(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.handle(data) }
            if error == nil, self.connection === conn { self.receive(conn) }
        }
    }

    private func handle(_ d: Data) {
        lastPacketAt = Date()
        packetCount += 1
        byteCount += d.count
        onAlive?()
        if packetCount == 1 {
            let head = d.prefix(12).map { String(format: "%02X", $0) }.joined(separator: " ")
            emit("first datagram \(d.count) B: \(head)")
        }
        if packetCount % 20 == 0 {
            let p = packetCount, b = byteCount, dr = dropped
            DispatchQueue.main.async { self.packets = p; self.bytes = b; self.framesDropped = dr }
        }
        let b = [UInt8](d)

        // Camera type report: 55 00 0X 00 00 00 0X 99
        if b.count == 8, b[0] == 0x55, b[7] == 0x99 {
            let type = b[2]
            emit("camera type \(type)")
            DispatchQueue.main.async { self.cameraType = type }
            onCameraType?(type)
            return
        }
        guard b.count > headerSize else { return }

        let frameId = b[0]
        let isLast = b[1] == 1
        let totalChunks = Int(b[2])
        if currentFrameId != frameId {
            if currentFrameId != nil, !buffer.isEmpty { dropped += 1 }   // previous frame never finished
            currentFrameId = frameId
            buffer.removeAll(keepingCapacity: true)
            chunkIndex = 0
        }
        buffer.append(contentsOf: b[headerSize...])
        chunkIndex += 1

        guard isLast else { return }
        defer { currentFrameId = nil; buffer.removeAll(keepingCapacity: true) }
        guard chunkIndex == totalChunks || totalChunks == 0 else {
            dropped += 1
            return
        }
        // Trim to the EOI marker.
        guard buffer.count > 4, buffer[buffer.startIndex] == 0xFF, buffer[buffer.startIndex + 1] == 0xD8 else {
            dropped += 1
            return
        }
        var end = buffer.count
        if let eoi = buffer.range(of: Data([0xFF, 0xD9]), options: .backwards) {
            end = eoi.upperBound - buffer.startIndex
        }
        let jpeg = buffer.prefix(end)
        decode(Data(jpeg))
    }

    private func decode(_ jpeg: Data) {
        guard !decodeBusy else { return }
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
                        let head = jpeg.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
                        self.log.append("decode failed, \(jpeg.count) B, head \(head)")
                    }
                }
            }
            self.queue.async { self.decodeBusy = false }
        }
    }

    private func setStatus(_ s: String) { DispatchQueue.main.async { self.status = s } }

    private func emit(_ line: String) {
        DispatchQueue.main.async {
            self.log.append(line)
            if self.log.count > 30 { self.log.removeFirst(self.log.count - 30) }
        }
    }
}
