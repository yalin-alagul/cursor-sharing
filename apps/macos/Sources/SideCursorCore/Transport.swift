import Foundation
import IOBluetooth
import Network

public enum TransportError: Error, LocalizedError {
    case invalidPort
    case disconnected
    case streamBusy
    case bluetoothUnavailable(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPort: return "The listening port is invalid."
        case .disconnected: return "The connection was closed."
        case .streamBusy: return "The transport already has a pending read."
        case let .bluetoothUnavailable(message): return "Bluetooth RFCOMM is unavailable: \(message)"
        case let .io(message): return "Transport I/O failed: \(message)"
        }
    }
}

/// A small exact-read byte stream layer lets the authenticated v2 protocol run
/// unchanged over Tailscale TCP or an RFCOMM byte stream.
public protocol RawByteStream: AnyObject {
    func start(
        onReady: @escaping (Result<Void, Error>) -> Void,
        onTerminal: @escaping (Error?) -> Void
    )
    func send(_ data: Data, completion: @escaping (Result<Void, Error>) -> Void)
    func receiveExactly(_ count: Int, completion: @escaping (Result<Data, Error>) -> Void)
    func cancel()
}

public final class NetworkByteStream: RawByteStream {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var didReportReady = false
    private var didReportTerminal = false
    private var onReady: ((Result<Void, Error>) -> Void)?
    private var onTerminal: ((Error?) -> Void)?

    public init(connection: NWConnection, queue: DispatchQueue = DispatchQueue(label: "com.yalinalagul.sidecursor.tcp")) {
        self.connection = connection
        self.queue = queue
    }

    public func start(
        onReady: @escaping (Result<Void, Error>) -> Void,
        onTerminal: @escaping (Error?) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            self.onReady = onReady
            self.onTerminal = onTerminal
            self.connection.stateUpdateHandler = { [weak self] state in
                self?.queue.async { self?.handle(state: state) }
            }
            self.connection.start(queue: self.queue)
        }
    }

    public func send(_ data: Data, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self, !self.didReportTerminal else {
                completion(.failure(TransportError.disconnected))
                return
            }
            self.connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    completion(.failure(error))
                } else {
                    completion(.success(()))
                }
            })
        }
    }

    public func receiveExactly(_ count: Int, completion: @escaping (Result<Data, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self, !self.didReportTerminal else {
                completion(.failure(TransportError.disconnected))
                return
            }
            self.readExactly(count, data: Data(), completion: completion)
        }
    }

    public func cancel() {
        queue.async { [weak self] in self?.connection.cancel() }
    }

    private func handle(state: NWConnection.State) {
        switch state {
        case .ready:
            guard !didReportReady else { return }
            didReportReady = true
            onReady?(.success(()))
        case let .failed(error):
            if !didReportReady {
                didReportReady = true
                onReady?(.failure(error))
            }
            reportTerminal(error)
        case .cancelled:
            reportTerminal(nil)
        default:
            break
        }
    }

    private func readExactly(_ count: Int, data: Data, completion: @escaping (Result<Data, Error>) -> Void) {
        guard count > 0 else {
            completion(.success(data))
            return
        }
        let remaining = count - data.count
        connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { [weak self] content, _, complete, error in
            guard let self else { return }
            self.queue.async {
                if let error {
                    completion(.failure(error))
                    return
                }
                var next = data
                if let content { next.append(content) }
                if next.count == count {
                    completion(.success(next))
                } else if complete {
                    completion(.failure(TransportError.disconnected))
                } else {
                    self.readExactly(count, data: next, completion: completion)
                }
            }
        }
    }

    private func reportTerminal(_ error: Error?) {
        guard !didReportTerminal else { return }
        didReportTerminal = true
        onTerminal?(error)
    }
}

public final class TCPListener {
    private let port: UInt16
    private let queue = DispatchQueue(label: "com.yalinalagul.sidecursor.listener")
    private var listener: NWListener?

    public init(port: UInt16) {
        self.port = port
    }

    public func start(
        onListening: @escaping () -> Void,
        onConnection: @escaping (NetworkByteStream) -> Void,
        onFailure: @escaping (Error) -> Void
    ) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw TransportError.invalidPort }
        // Cursor deltas and acknowledgement frames are deliberately tiny.
        // Disable Nagle coalescing so a single motion or return acknowledgement
        // is not held behind the platform delayed-ACK timer.
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let listener = try NWListener(using: NWParameters(tls: nil, tcp: tcp), on: endpointPort)
        listener.newConnectionHandler = { connection in
            onConnection(NetworkByteStream(connection: connection))
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                onListening()
            case let .failed(error):
                onFailure(error)
            default:
                break
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }
}

/// Owns the required v2 server handshake, post-handshake frame codec, and the
/// single ordered receive loop.  The same logical Mac-server handshake is used
/// on TCP and Bluetooth even when RFCOMM's socket direction is reversed.
public final class EncryptedPeerConnection {
    private let stream: RawByteStream
    private let pairingSecret: Data
    private let lock = NSLock()
    private var codec: EncryptedFrameCodec?
    private var didClose = false
    private var onReady: ((Result<Void, Error>) -> Void)?
    private var onMessage: ((ProtocolMessage) -> Void)?
    private var onClosed: ((Error?) -> Void)?

    public init(stream: RawByteStream, pairingSecret: Data) {
        self.stream = stream
        self.pairingSecret = pairingSecret
    }

    public func startAsServer(
        onReady: @escaping (Result<Void, Error>) -> Void,
        onMessage: @escaping (ProtocolMessage) -> Void,
        onClosed: @escaping (Error?) -> Void
    ) {
        self.onReady = onReady
        self.onMessage = onMessage
        self.onClosed = onClosed
        stream.start(
            onReady: { [weak self] result in
                switch result {
                case .success: self?.beginHandshake()
                case let .failure(error): self?.failBeforeReady(error)
                }
            },
            onTerminal: { [weak self] error in self?.finish(error) }
        )
    }

    public func send(_ message: ProtocolMessage) {
        let frame: Data
        do {
            lock.lock()
            defer { lock.unlock() }
            guard var codec else { throw TransportError.disconnected }
            let body = try codec.seal(message)
            self.codec = codec
            frame = try EncryptedFrameCodec.lengthPrefixed(body)
        } catch {
            finish(error)
            return
        }
        stream.send(frame) { [weak self] result in
            if case let .failure(error) = result { self?.finish(error) }
        }
    }

    public func close() {
        stream.cancel()
        finish(nil)
    }

    private func beginHandshake() {
        do {
            let handshake = try ServerHandshake(pairingSecret: pairingSecret)
            let data = try JSONEncoder().encode(handshake.hello)
            try sendPlain(data) { [weak self] result in
                switch result {
                case .success: self?.readPlainPair(handshake)
                case let .failure(error): self?.failBeforeReady(error)
                }
            }
        } catch {
            failBeforeReady(error)
        }
    }

    private func readPlainPair(_ handshake: ServerHandshake) {
        readFramed(maximumLength: ProtocolV2.maximumHandshakeBytes) { [weak self] result in
            guard let self else { return }
            do {
                let pair = try JSONDecoder().decode(HandshakeEnvelope.self, from: try result.get())
                let accepted = try handshake.accept(pair)
                let payload = try JSONEncoder().encode(accepted.accept)
                try self.sendPlain(payload) { [weak self] sendResult in
                    guard let self else { return }
                    switch sendResult {
                    case .success:
                        self.lock.lock()
                        self.codec = EncryptedFrameCodec(sessionKey: accepted.sessionKey)
                        self.lock.unlock()
                        self.onReady?(.success(()))
                        self.readNextEncryptedFrame()
                    case let .failure(error):
                        self.failBeforeReady(error)
                    }
                }
            } catch {
                self.failBeforeReady(error)
            }
        }
    }

    private func readNextEncryptedFrame() {
        readFramed(maximumLength: ProtocolV2.maximumFrameBytes) { [weak self] result in
            guard let self else { return }
            do {
                let body = try result.get()
                let message: ProtocolMessage
                self.lock.lock()
                do {
                    guard var codec = self.codec else { throw TransportError.disconnected }
                    message = try codec.open(body)
                    self.codec = codec
                    self.lock.unlock()
                } catch {
                    self.lock.unlock()
                    throw error
                }
                self.onMessage?(message)
                self.readNextEncryptedFrame()
            } catch {
                self.finish(error)
            }
        }
    }

    private func sendPlain(_ payload: Data, completion: @escaping (Result<Void, Error>) -> Void) throws {
        guard payload.count <= ProtocolV2.maximumHandshakeBytes else { throw ProtocolError.frameTooLarge }
        let frame = try EncryptedFrameCodec.lengthPrefixed(payload)
        stream.send(frame, completion: completion)
    }

    private func readFramed(maximumLength: Int, completion: @escaping (Result<Data, Error>) -> Void) {
        stream.receiveExactly(4) { [weak self] headerResult in
            guard let self else { return }
            do {
                let header = try headerResult.get()
                let length = try EncryptedFrameCodec.length(from: header)
                guard length <= maximumLength else { throw ProtocolError.frameTooLarge }
                self.stream.receiveExactly(length, completion: completion)
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func failBeforeReady(_ error: Error) {
        onReady?(.failure(error))
        stream.cancel()
        finish(error)
    }

    private func finish(_ error: Error?) {
        lock.lock()
        let shouldFinish = !didClose
        didClose = true
        lock.unlock()
        guard shouldFinish else { return }
        onClosed?(error)
    }
}

/// The Windows companion advertises this fixed service UUID through SDP.
/// RFCOMM assigns the actual channel dynamically, so the Mac must resolve the
/// service record before it opens a channel.  A hard-coded channel is both
/// unreliable and incompatible with the Windows WinRT RFCOMM provider.
public enum SideCursorBluetoothService {
    public static let uuidString = "2A99401E-C4A4-4CD4-9AB1-8090C2444BB6"
    public static let uuid = UUID(uuidString: uuidString)!
}

/// Resolves the RFCOMM channel from the device's SDP cache after asking the
/// system to refresh it. IOBluetooth's target callback is delivered through a
/// legacy run-loop path that is not reliable for a SwiftUI menu-bar agent, but
/// `getLastServicesUpdate` and `getServiceRecord(for:)` are updated by the
/// same completed SDP request. Polling that documented cache makes discovery
/// deterministic without retaining an unsafe late Objective-C callback target.
private final class RFCOMMServiceDiscovery: NSObject {
    private let lock = NSLock()
    private let device: IOBluetoothDevice
    private let serviceUUID: IOBluetoothSDPUUID
    private var completion: ((Result<BluetoothRFCOMMChannelID, Error>) -> Void)?
    private var timeout: DispatchWorkItem?
    private var poll: DispatchSourceTimer?
    private var servicesBeforeQuery: Date?
    private var queryStartedAt: Date?
    private var delivered = false
    private var cancelled = false

    init(
        device: IOBluetoothDevice,
        serviceUUID: UUID,
        completion: @escaping (Result<BluetoothRFCOMMChannelID, Error>) -> Void
    ) throws {
        guard let bluetoothUUID = Self.makeBluetoothUUID(serviceUUID) else {
            throw TransportError.bluetoothUnavailable("SideCursor Bluetooth service UUID is invalid")
        }
        self.device = device
        self.serviceUUID = bluetoothUUID
        self.completion = completion
    }

    func start() {
        lock.lock()
        guard !cancelled, !delivered else {
            lock.unlock()
            return
        }
        servicesBeforeQuery = device.getLastServicesUpdate()
        queryStartedAt = Date()
        lock.unlock()

        // No target means no fragile delegate callback. The system still
        // performs the asynchronous SDP request and refreshes `services`.
        let status = device.performSDPQuery(nil, uuids: [serviceUUID])
        guard status == 0 else {
            deliver(
                .failure(TransportError.bluetoothUnavailable("could not query the Windows SideCursor Bluetooth service (status \(status))"))
            )
            return
        }

        let poll = DispatchSource.makeTimerSource(queue: .main)
        poll.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(150), leeway: .milliseconds(25))
        poll.setEventHandler { [weak self] in
            self?.resolveServiceRecordWhenFresh()
        }
        lock.lock()
        if cancelled || delivered {
            lock.unlock()
            poll.cancel()
            return
        }
        self.poll = poll
        lock.unlock()
        poll.resume()

        let timeout = DispatchWorkItem { [weak self] in
            self?.deliver(
                .failure(TransportError.bluetoothUnavailable("Windows did not advertise the SideCursor Bluetooth service within 8 seconds"))
            )
        }
        lock.lock()
        if cancelled || delivered {
            lock.unlock()
            timeout.cancel()
            return
        }
        self.timeout = timeout
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        completion = nil
        timeout?.cancel()
        timeout = nil
        poll?.cancel()
        poll = nil
        lock.unlock()
    }

    private func resolveServiceRecordWhenFresh() {
        let observedUpdate = device.getLastServicesUpdate()

        lock.lock()
        let shouldResolve: Bool
        if cancelled || delivered {
            shouldResolve = false
        } else if let observedUpdate {
            // A fresh timestamp proves the current SDP request populated the
            // cache. The small tolerance covers Bluetooth timestamps that are
            // quantized to whole seconds on some macOS releases.
            if let before = servicesBeforeQuery, observedUpdate > before {
                shouldResolve = true
            } else if let started = queryStartedAt,
                      observedUpdate >= started.addingTimeInterval(-1) {
                shouldResolve = true
            } else {
                shouldResolve = false
            }
        } else {
            shouldResolve = false
        }
        lock.unlock()
        guard shouldResolve else { return }

        guard let serviceRecord = device.getServiceRecord(for: serviceUUID) else {
            // The SDP refresh completed but the expected UUID was absent.
            deliver(.failure(TransportError.bluetoothUnavailable("Windows is paired but is not advertising the SideCursor Bluetooth service")))
            return
        }

        var channel: BluetoothRFCOMMChannelID = 0
        let channelStatus = serviceRecord.getRFCOMMChannelID(&channel)
        guard channelStatus == 0, channel > 0 else {
            deliver(
                .failure(TransportError.bluetoothUnavailable("Windows advertised SideCursor without an RFCOMM channel (status \(channelStatus))"))
            )
            return
        }
        deliver(.success(channel))
    }

    private func deliver(_ result: Result<BluetoothRFCOMMChannelID, Error>) {
        let callback: ((Result<BluetoothRFCOMMChannelID, Error>) -> Void)?
        lock.lock()
        timeout?.cancel()
        timeout = nil
        poll?.cancel()
        poll = nil
        if delivered {
            callback = nil
        } else {
            delivered = true
            callback = completion
            completion = nil
        }
        lock.unlock()
        callback?(result)
    }

    private static func makeBluetoothUUID(_ uuid: UUID) -> IOBluetoothSDPUUID? {
        var rawUUID = uuid.uuid
        let data = withUnsafeBytes(of: &rawUUID) { Data($0) }
        return IOBluetoothSDPUUID(data: data)
    }
}

/// RFCOMM is a manual fallback. This adapter first performs an explicit SDP
/// service discovery against the paired Windows device, then opens only the
/// channel that Windows is currently advertising. It never silently retries
/// or switches to TCP.
public final class BluetoothRFCOMMByteStream: NSObject, RawByteStream, IOBluetoothRFCOMMChannelDelegate {
    private let address: String
    private let serviceUUID: UUID
    private let queue = DispatchQueue(label: "com.yalinalagul.sidecursor.bluetooth")
    private var device: IOBluetoothDevice?
    private var channel: IOBluetoothRFCOMMChannel?
    private var serviceDiscovery: RFCOMMServiceDiscovery?
    private var incoming = Data()
    private var pendingRead: ((Result<Data, Error>) -> Void)?
    private var pendingReadLength = 0
    private var onTerminal: ((Error?) -> Void)?
    private var didTerminal = false

    public init(address: String, serviceUUID: UUID = SideCursorBluetoothService.uuid) {
        self.address = address
        self.serviceUUID = serviceUUID
    }

    public func start(
        onReady: @escaping (Result<Void, Error>) -> Void,
        onTerminal: @escaping (Error?) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            self.onTerminal = onTerminal
            guard let device = IOBluetoothDevice(addressString: self.address) else {
                onReady(.failure(TransportError.bluetoothUnavailable("invalid paired-device address")))
                return
            }
            self.device = device
            if !device.isConnected() {
                let openStatus = device.openConnection()
                guard openStatus == 0 else {
                    onReady(.failure(TransportError.bluetoothUnavailable("could not connect to the paired device (status \(openStatus))")))
                    return
                }
            }
            do {
                let discovery = try RFCOMMServiceDiscovery(device: device, serviceUUID: self.serviceUUID) { [weak self] result in
                    self?.queue.async {
                        guard let self, !self.didTerminal else { return }
                        self.serviceDiscovery = nil
                        switch result {
                        case let .success(channelID):
                            self.openChannel(on: device, channelID: channelID, onReady: onReady)
                        case let .failure(error):
                            onReady(.failure(error))
                        }
                    }
                }
                self.serviceDiscovery = discovery
                // IOBluetooth delivers its asynchronous SDP completion through
                // a CFRunLoop. A private DispatchQueue has no long-lived run
                // loop, so starting the query there makes a successful query
                // appear to time out. The application main thread owns the
                // AppKit run loop for the lifetime of the menu-bar agent.
                DispatchQueue.main.async {
                    discovery.start()
                }
            } catch {
                onReady(.failure(error))
            }
        }
    }

    public func send(_ data: Data, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self, let channel = self.channel, channel.isOpen() else {
                completion(.failure(TransportError.disconnected))
                return
            }
            let mtu = max(1, Int(channel.getMTU()))
            var offset = 0
            while offset < data.count {
                let end = min(data.count, offset + mtu)
                var chunk = data.subdata(in: offset ..< end)
                let status = chunk.withUnsafeMutableBytes { bytes in
                    channel.writeSync(bytes.baseAddress, length: UInt16(bytes.count))
                }
                guard status == 0 else {
                    let error = TransportError.io("RFCOMM write failed (status \(status))")
                    completion(.failure(error))
                    self.finish(error)
                    return
                }
                offset = end
            }
            completion(.success(()))
        }
    }

    public func receiveExactly(_ count: Int, completion: @escaping (Result<Data, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.pendingRead == nil else {
                completion(.failure(TransportError.streamBusy))
                return
            }
            self.pendingRead = completion
            self.pendingReadLength = count
            self.fulfillReadIfPossible()
        }
    }

    public func cancel() {
        queue.async { [weak self] in
            guard let self else { return }
            self.serviceDiscovery?.cancel()
            self.channel?.setDelegate(nil)
            self.channel?.close()
            self.device?.closeConnection()
            self.channel = nil
            self.device = nil
            self.finish(nil)
        }
    }

    public func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        guard let dataPointer, dataLength > 0 else { return }
        let data = Data(bytes: dataPointer, count: dataLength)
        queue.async { [weak self] in
            self?.incoming.append(data)
            self?.fulfillReadIfPossible()
        }
    }

    public func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        queue.async { [weak self] in self?.finish(TransportError.disconnected) }
    }

    private func fulfillReadIfPossible() {
        guard let completion = pendingRead, incoming.count >= pendingReadLength else { return }
        let result = incoming.prefix(pendingReadLength)
        incoming.removeFirst(pendingReadLength)
        pendingRead = nil
        pendingReadLength = 0
        completion(.success(Data(result)))
    }

    private func openChannel(
        on device: IOBluetoothDevice,
        channelID: BluetoothRFCOMMChannelID,
        onReady: @escaping (Result<Void, Error>) -> Void
    ) {
        // The synchronous opener registers its delegate with IOBluetooth's
        // run-loop machinery before it returns. Calling it from our private
        // DispatchQueue produces kIOReturnError even when SDP has just
        // resolved a valid channel. Run it on AppKit's main run loop instead.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.openChannel(on: device, channelID: channelID, onReady: onReady)
            }
            return
        }

        var openedChannel: IOBluetoothRFCOMMChannel?
        let status = device.openRFCOMMChannelSync(&openedChannel, withChannelID: channelID, delegate: self)
        guard status == 0, let openedChannel, openedChannel.isOpen() else {
            onReady(.failure(TransportError.bluetoothUnavailable("Windows SideCursor RFCOMM channel \(channelID) could not be opened (status \(status))")))
            return
        }
        openedChannel.setDelegate(self)
        channel = openedChannel
        onReady(.success(()))
    }

    private func finish(_ error: Error?) {
        guard !didTerminal else { return }
        didTerminal = true
        if let pendingRead {
            self.pendingRead = nil
            pendingRead(.failure(error ?? TransportError.disconnected))
        }
        onTerminal?(error)
    }
}
