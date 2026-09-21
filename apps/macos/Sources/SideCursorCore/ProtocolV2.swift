import CryptoKit
import Foundation
import Security

public enum ProtocolV2 {
    public static let version = 2
    public static let maximumHandshakeBytes = 16 * 1024
    public static let maximumFrameBytes = 2 * 1024 * 1024
    public static let maximumClipboardBytes = 1_048_576
}

public enum ProtocolError: Error, Equatable, LocalizedError {
    case invalidPairingSecret
    case invalidBase64
    case invalidHandshake
    case authenticationFailed
    case frameTooLarge
    case malformedFrame
    case unexpectedSequence(expected: UInt64, actual: UInt64)
    case malformedMessage
    case randomGenerationFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidPairingSecret: return "The pairing code must contain exactly 32 bytes."
        case .invalidBase64: return "The pairing code is not valid base64url data."
        case .invalidHandshake: return "The peer sent an invalid SideCursor v2 handshake."
        case .authenticationFailed: return "The peer could not prove the pairing code."
        case .frameTooLarge: return "The peer sent a frame larger than SideCursor allows."
        case .malformedFrame: return "The encrypted frame is malformed."
        case let .unexpectedSequence(expected, actual):
            return "Encrypted frame sequence \(actual) was received; expected \(expected)."
        case .malformedMessage: return "The peer sent an invalid SideCursor message."
        case let .randomGenerationFailed(status): return "Secure random generation failed (\(status))."
        }
    }
}

public struct HandshakeEnvelope: Codable, Equatable {
    public let v: Int
    public let kind: String
    public let pub: String?
    public let nonce: String?
    public let proof: String?

    public init(v: Int = ProtocolV2.version, kind: String, pub: String? = nil, nonce: String? = nil, proof: String? = nil) {
        self.v = v
        self.kind = kind
        self.pub = pub
        self.nonce = nonce
        self.proof = proof
    }
}

public struct InputSource: Codable, Equatable {
    public let display: String
    public let width: Int
    public let height: Int

    public init(display: String, width: Int, height: Int) {
        self.display = display
        self.width = width
        self.height = height
    }
}

public struct EnterRequest: Codable, Equatable {
    public let id: UUID
    public let y: Double
    public let source: InputSource

    public init(id: UUID, y: Double, source: InputSource) {
        self.id = id
        self.y = min(1, max(0, y))
        self.source = source
    }
}

public enum MouseButton: String, Codable, Equatable {
    case left
    case right
    case middle
}

public enum NativeInputEvent: Equatable {
    case pointer(dx: Int, dy: Int)
    case button(button: MouseButton, down: Bool)
    case scroll(horizontal: Int, vertical: Int)
    case key(vk: Int, down: Bool, extended: Bool)
}

extension NativeInputEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case dx
        case dy
        case button
        case down
        case horizontal
        case vertical
        case vk
        case extended
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "pointer":
            self = .pointer(
                dx: try container.decode(Int.self, forKey: .dx),
                dy: try container.decode(Int.self, forKey: .dy)
            )
        case "button":
            self = .button(
                button: try container.decode(MouseButton.self, forKey: .button),
                down: try container.decode(Bool.self, forKey: .down)
            )
        case "scroll":
            self = .scroll(
                horizontal: try container.decode(Int.self, forKey: .horizontal),
                vertical: try container.decode(Int.self, forKey: .vertical)
            )
        case "key":
            self = .key(
                vk: try container.decode(Int.self, forKey: .vk),
                down: try container.decode(Bool.self, forKey: .down),
                extended: try container.decodeIfPresent(Bool.self, forKey: .extended) ?? false
            )
        default:
            throw ProtocolError.malformedMessage
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .pointer(dx, dy):
            try container.encode("pointer", forKey: .kind)
            try container.encode(dx, forKey: .dx)
            try container.encode(dy, forKey: .dy)
        case let .button(button, down):
            try container.encode("button", forKey: .kind)
            try container.encode(button, forKey: .button)
            try container.encode(down, forKey: .down)
        case let .scroll(horizontal, vertical):
            try container.encode("scroll", forKey: .kind)
            try container.encode(horizontal, forKey: .horizontal)
            try container.encode(vertical, forKey: .vertical)
        case let .key(vk, down, extended):
            try container.encode("key", forKey: .kind)
            try container.encode(vk, forKey: .vk)
            try container.encode(down, forKey: .down)
            try container.encode(extended, forKey: .extended)
        }
    }
}

/// The JSON form intentionally matches `shared/protocol.md` byte-for-byte at
/// the field level.  The encrypted framing is handled separately below.
public enum ProtocolMessage: Equatable {
    case enterRequest(EnterRequest)
    case enterAck(id: UUID)
    case enterReject(id: UUID, reason: String)
    case input(NativeInputEvent)
    case command(name: String)
    case returnRequest(id: UUID, y: Double)
    case returnAck(id: UUID)
    case releaseAll(reason: String)
    case clipboard(origin: String, text: String)
    case ping(sentAtMs: Int64)
    case pong(sentAtMs: Int64)
}

extension ProtocolMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case id
        case y
        case source
        case reason
        case event
        case name
        case origin
        case text
        case sentAtMs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "enter_request":
            self = .enterRequest(EnterRequest(
                id: try container.decode(UUID.self, forKey: .id),
                y: try container.decode(Double.self, forKey: .y),
                source: try container.decode(InputSource.self, forKey: .source)
            ))
        case "enter_ack":
            self = .enterAck(id: try container.decode(UUID.self, forKey: .id))
        case "enter_reject":
            self = .enterReject(
                id: try container.decode(UUID.self, forKey: .id),
                reason: try container.decode(String.self, forKey: .reason)
            )
        case "input":
            self = .input(try container.decode(NativeInputEvent.self, forKey: .event))
        case "command":
            self = .command(name: try container.decode(String.self, forKey: .name))
        case "return_request":
            self = .returnRequest(
                id: try container.decode(UUID.self, forKey: .id),
                y: try container.decode(Double.self, forKey: .y)
            )
        case "return_ack":
            self = .returnAck(id: try container.decode(UUID.self, forKey: .id))
        case "release_all":
            self = .releaseAll(reason: try container.decode(String.self, forKey: .reason))
        case "clipboard":
            self = .clipboard(
                origin: try container.decode(String.self, forKey: .origin),
                text: try container.decode(String.self, forKey: .text)
            )
        case "ping":
            self = .ping(sentAtMs: try container.decode(Int64.self, forKey: .sentAtMs))
        case "pong":
            self = .pong(sentAtMs: try container.decode(Int64.self, forKey: .sentAtMs))
        default:
            throw ProtocolError.malformedMessage
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .enterRequest(request):
            try container.encode("enter_request", forKey: .type)
            try container.encode(request.id, forKey: .id)
            try container.encode(request.y, forKey: .y)
            try container.encode(request.source, forKey: .source)
        case let .enterAck(id):
            try container.encode("enter_ack", forKey: .type)
            try container.encode(id, forKey: .id)
        case let .enterReject(id, reason):
            try container.encode("enter_reject", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(reason, forKey: .reason)
        case let .input(event):
            try container.encode("input", forKey: .type)
            try container.encode(event, forKey: .event)
        case let .command(name):
            try container.encode("command", forKey: .type)
            try container.encode(name, forKey: .name)
        case let .returnRequest(id, y):
            try container.encode("return_request", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(min(1, max(0, y)), forKey: .y)
        case let .returnAck(id):
            try container.encode("return_ack", forKey: .type)
            try container.encode(id, forKey: .id)
        case let .releaseAll(reason):
            try container.encode("release_all", forKey: .type)
            try container.encode(reason, forKey: .reason)
        case let .clipboard(origin, text):
            guard text.lengthOfBytes(using: .utf8) <= ProtocolV2.maximumClipboardBytes else {
                throw ProtocolError.frameTooLarge
            }
            try container.encode("clipboard", forKey: .type)
            try container.encode(origin, forKey: .origin)
            try container.encode(text, forKey: .text)
        case let .ping(sentAtMs):
            try container.encode("ping", forKey: .type)
            try container.encode(sentAtMs, forKey: .sentAtMs)
        case let .pong(sentAtMs):
            try container.encode("pong", forKey: .type)
            try container.encode(sentAtMs, forKey: .sentAtMs)
        }
    }
}

public struct ServerHandshake {
    private let pairingSecret: Data
    private let privateKey: Curve25519.KeyAgreement.PrivateKey
    private let publicKey: Data
    private let nonce: Data

    public let hello: HandshakeEnvelope

    public init(pairingSecret: Data) throws {
        guard pairingSecret.count == 32 else { throw ProtocolError.invalidPairingSecret }
        self.pairingSecret = pairingSecret
        privateKey = Curve25519.KeyAgreement.PrivateKey()
        publicKey = privateKey.publicKey.rawRepresentation
        nonce = try SecureRandom.bytes(count: 16)
        hello = HandshakeEnvelope(
            kind: "hello",
            pub: publicKey.base64URLEncodedString(),
            nonce: nonce.base64URLEncodedString()
        )
    }

    public func accept(_ pair: HandshakeEnvelope) throws -> (accept: HandshakeEnvelope, sessionKey: SymmetricKey) {
        guard pair.v == ProtocolV2.version,
              pair.kind == "pair",
              let clientPublicString = pair.pub,
              let clientNonceString = pair.nonce,
              let proofString = pair.proof,
              let clientPublic = Data(base64URL: clientPublicString),
              let clientNonce = Data(base64URL: clientNonceString),
              let proof = Data(base64URL: proofString),
              clientPublic.count == 32,
              clientNonce.count == 16
        else {
            throw ProtocolError.invalidHandshake
        }

        let expectedProof = ProtocolCrypto.hmac(
            key: SymmetricKey(data: pairingSecret),
            data: publicKey + clientPublic + nonce + clientNonce
        )
        guard ProtocolCrypto.secureEqual(expectedProof, proof) else {
            throw ProtocolError.authenticationFailed
        }

        let peerKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: clientPublic)
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: peerKey)
        let sessionKey = ProtocolCrypto.deriveSessionKey(
            sharedSecret: sharedSecret,
            pairingSecret: pairingSecret,
            serverNonce: nonce,
            clientNonce: clientNonce
        )
        let acceptProof = ProtocolCrypto.hmac(key: sessionKey, data: Data("accept".utf8))
        return (
            HandshakeEnvelope(kind: "accept", proof: acceptProof.base64URLEncodedString()),
            sessionKey
        )
    }
}

/// Used by tests and by a future native Windows client to keep the handshake
/// transcript unambiguous across platforms.
public struct ClientHandshake {
    private let pairingSecret: Data
    private let serverPublic: Data
    private let serverNonce: Data
    private let privateKey: Curve25519.KeyAgreement.PrivateKey
    private let publicKey: Data
    private let nonce: Data

    public init(hello: HandshakeEnvelope, pairingSecret: Data) throws {
        guard pairingSecret.count == 32,
              hello.v == ProtocolV2.version,
              hello.kind == "hello",
              let serverPublicString = hello.pub,
              let serverNonceString = hello.nonce,
              let serverPublic = Data(base64URL: serverPublicString),
              let serverNonce = Data(base64URL: serverNonceString),
              serverPublic.count == 32,
              serverNonce.count == 16
        else {
            throw ProtocolError.invalidHandshake
        }
        self.pairingSecret = pairingSecret
        self.serverPublic = serverPublic
        self.serverNonce = serverNonce
        privateKey = Curve25519.KeyAgreement.PrivateKey()
        publicKey = privateKey.publicKey.rawRepresentation
        nonce = try SecureRandom.bytes(count: 16)
    }

    public func makePairMessage() -> HandshakeEnvelope {
        let proof = ProtocolCrypto.hmac(
            key: SymmetricKey(data: pairingSecret),
            data: serverPublic + publicKey + serverNonce + nonce
        )
        return HandshakeEnvelope(
            kind: "pair",
            pub: publicKey.base64URLEncodedString(),
            nonce: nonce.base64URLEncodedString(),
            proof: proof.base64URLEncodedString()
        )
    }

    public func complete(_ accept: HandshakeEnvelope) throws -> SymmetricKey {
        guard accept.v == ProtocolV2.version,
              accept.kind == "accept",
              let proofString = accept.proof,
              let proof = Data(base64URL: proofString)
        else {
            throw ProtocolError.invalidHandshake
        }
        let serverKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: serverPublic)
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: serverKey)
        let sessionKey = ProtocolCrypto.deriveSessionKey(
            sharedSecret: sharedSecret,
            pairingSecret: pairingSecret,
            serverNonce: serverNonce,
            clientNonce: nonce
        )
        let expected = ProtocolCrypto.hmac(key: sessionKey, data: Data("accept".utf8))
        guard ProtocolCrypto.secureEqual(expected, proof) else {
            throw ProtocolError.authenticationFailed
        }
        return sessionKey
    }
}

/// Stateful ChaCha20-Poly1305 encoder/decoder.  Sequence numbers are in the
/// authenticated data and must advance by one, preventing replay and re-order.
public struct EncryptedFrameCodec {
    private let sessionKey: SymmetricKey
    private let noncePrefix: Data
    private var nextOutboundSequence: UInt64 = 0
    private var lastInboundSequence: UInt64 = 0

    public init(sessionKey: SymmetricKey) {
        self.sessionKey = sessionKey
        // A 4-byte random prefix scopes this connection's nonce space; the
        // monotonic sequence fills the remaining 8 bytes. This keeps every
        // nonce unique without a CSPRNG syscall on each frame, which matters at
        // pointer-motion rates.
        var generator = SystemRandomNumberGenerator()
        self.noncePrefix = Data.uint32BE(UInt32(truncatingIfNeeded: generator.next()))
    }

    /// Returns the bytes after the uint32 big-endian length prefix.
    public mutating func seal(_ message: ProtocolMessage) throws -> Data {
        let plaintext = try JSONEncoder().encode(message)
        guard plaintext.count <= ProtocolV2.maximumFrameBytes else { throw ProtocolError.frameTooLarge }
        guard nextOutboundSequence < UInt64.max else { throw ProtocolError.malformedFrame }
        nextOutboundSequence += 1
        let sequence = nextOutboundSequence
        let sequenceData = Data.uint64BE(sequence)
        let nonceData = noncePrefix + sequenceData
        let nonce = try ChaChaPoly.Nonce(data: nonceData)
        let sealed = try ChaChaPoly.seal(
            plaintext,
            using: sessionKey,
            nonce: nonce,
            authenticating: sequenceData
        )

        var body = Data()
        body.append(sequenceData)
        body.append(nonceData)
        body.append(sealed.ciphertext)
        body.append(sealed.tag)
        guard body.count <= ProtocolV2.maximumFrameBytes else { throw ProtocolError.frameTooLarge }
        return body
    }

    public mutating func open(_ body: Data) throws -> ProtocolMessage {
        guard body.count >= 8 + 12 + 16, body.count <= ProtocolV2.maximumFrameBytes else {
            throw ProtocolError.malformedFrame
        }
        let sequence = try body.uint64BE(at: 0)
        let expected = lastInboundSequence + 1
        guard sequence == expected else {
            throw ProtocolError.unexpectedSequence(expected: expected, actual: sequence)
        }
        let sequenceData = Data.uint64BE(sequence)
        let nonceData = body.subdata(in: 8 ..< 20)
        let encrypted = body.subdata(in: 20 ..< body.count)
        guard encrypted.count >= 16 else { throw ProtocolError.malformedFrame }
        let ciphertext = encrypted.dropLast(16)
        let tag = encrypted.suffix(16)
        let sealed = try ChaChaPoly.SealedBox(
            nonce: ChaChaPoly.Nonce(data: nonceData),
            ciphertext: ciphertext,
            tag: tag
        )
        let plaintext = try ChaChaPoly.open(sealed, using: sessionKey, authenticating: sequenceData)
        let message: ProtocolMessage
        do {
            message = try JSONDecoder().decode(ProtocolMessage.self, from: plaintext)
        } catch let error as ProtocolError {
            throw error
        } catch {
            throw ProtocolError.malformedMessage
        }
        lastInboundSequence = sequence
        return message
    }

    public static func lengthPrefixed(_ body: Data) throws -> Data {
        guard body.count <= ProtocolV2.maximumFrameBytes, body.count <= Int(UInt32.max) else {
            throw ProtocolError.frameTooLarge
        }
        return Data.uint32BE(UInt32(body.count)) + body
    }

    public static func length(from header: Data) throws -> Int {
        guard header.count == 4 else { throw ProtocolError.malformedFrame }
        let length = try header.uint32BE(at: 0)
        guard length <= UInt32(ProtocolV2.maximumFrameBytes) else { throw ProtocolError.frameTooLarge }
        return Int(length)
    }
}

public enum ProtocolCrypto {
    static func hmac(key: SymmetricKey, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
    }

    static func deriveSessionKey(
        sharedSecret: SharedSecret,
        pairingSecret: Data,
        serverNonce: Data,
        clientNonce: Data
    ) -> SymmetricKey {
        let salt = Data(SHA256.hash(data: serverNonce + clientNonce))
        var info = Data("SideCursor/v2".utf8)
        info.append(pairingSecret)
        return sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: info,
            outputByteCount: 32
        )
    }

    static func secureEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }
}

private enum SecureRandom {
    static func bytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else { throw ProtocolError.randomGenerationFailed(status) }
        return Data(bytes)
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL value: String) {
        var padded = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = padded.count % 4
        if remainder != 0 {
            padded.append(String(repeating: "=", count: 4 - remainder))
        }
        self.init(base64Encoded: padded)
    }

    static func uint32BE(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ])
    }

    static func uint64BE(_ value: UInt64) -> Data {
        Data([
            UInt8((value >> 56) & 0xff), UInt8((value >> 48) & 0xff),
            UInt8((value >> 40) & 0xff), UInt8((value >> 32) & 0xff),
            UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff), UInt8(value & 0xff),
        ])
    }

    func uint32BE(at offset: Int) throws -> UInt32 {
        guard offset >= 0, count >= offset + 4 else { throw ProtocolError.malformedFrame }
        return (UInt32(self[offset]) << 24)
            | (UInt32(self[offset + 1]) << 16)
            | (UInt32(self[offset + 2]) << 8)
            | UInt32(self[offset + 3])
    }

    func uint64BE(at offset: Int) throws -> UInt64 {
        guard offset >= 0, count >= offset + 8 else { throw ProtocolError.malformedFrame }
        var value: UInt64 = 0
        for index in 0 ..< 8 {
            value = (value << 8) | UInt64(self[offset + index])
        }
        return value
    }
}
