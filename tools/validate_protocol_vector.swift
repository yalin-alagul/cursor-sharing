#!/usr/bin/env swift
import CryptoKit
import Foundation

struct FrameVector: Decodable {
    let sequence: UInt64
    let nonce: String
    let plaintext: String
    let combined: String
}

struct InteropVector: Decodable {
    let pairingSecret: String
    let serverPrivate: String
    let clientPrivate: String
    let serverPublic: String
    let clientPublic: String
    let serverNonce: String
    let clientNonce: String
    let pairProof: String
    let sharedSecret: String
    let sessionKey: String
    let acceptProof: String
    let frame: FrameVector
}

enum ValidationError: Error, CustomStringConvertible {
    case malformed(String)
    case mismatch(String)

    var description: String {
        switch self {
        case .malformed(let message), .mismatch(let message): return message
        }
    }
}

func base64URLDecode(_ value: String) throws -> Data {
    let padded = value.replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
        .padding(toLength: ((value.count + 3) / 4) * 4, withPad: "=", startingAt: 0)
    guard let data = Data(base64Encoded: padded) else {
        throw ValidationError.malformed("invalid base64url value")
    }
    return data
}

func equal(_ actual: Data, _ expected: String, _ label: String) throws {
    let expectedData = try base64URLDecode(expected)
    guard actual == expectedData else {
        throw ValidationError.mismatch("mismatch: \(label)")
    }
}

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let rootURL = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let fixtureURL = rootURL.appendingPathComponent("shared/interop-vectors.json")

do {
    let vector = try JSONDecoder().decode(InteropVector.self, from: Data(contentsOf: fixtureURL))
    let secret = try base64URLDecode(vector.pairingSecret)
    let server = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: base64URLDecode(vector.serverPrivate))
    let client = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: base64URLDecode(vector.clientPrivate))
    let serverPublic = server.publicKey.rawRepresentation
    let clientPublic = client.publicKey.rawRepresentation
    try equal(serverPublic, vector.serverPublic, "server public key")
    try equal(clientPublic, vector.clientPublic, "client public key")

    let serverNonce = try base64URLDecode(vector.serverNonce)
    let clientNonce = try base64URLDecode(vector.clientNonce)
    let transcript = serverPublic + clientPublic + serverNonce + clientNonce
    let pairProof = Data(HMAC<SHA256>.authenticationCode(for: transcript, using: SymmetricKey(data: secret)))
    try equal(pairProof, vector.pairProof, "pair proof")

    let sharedSecret = try server.sharedSecretFromKeyAgreement(with: client.publicKey)
    let rawSharedSecret = sharedSecret.withUnsafeBytes { Data($0) }
    try equal(rawSharedSecret, vector.sharedSecret, "shared secret")

    let salt = Data(SHA256.hash(data: serverNonce + clientNonce))
    let sessionKey = sharedSecret.hkdfDerivedSymmetricKey(
        using: SHA256.self,
        salt: salt,
        sharedInfo: Data("SideCursor/v2".utf8) + secret,
        outputByteCount: 32
    )
    let rawSessionKey = sessionKey.withUnsafeBytes { Data($0) }
    try equal(rawSessionKey, vector.sessionKey, "session key")
    let acceptProof = Data(HMAC<SHA256>.authenticationCode(for: Data("accept".utf8), using: sessionKey))
    try equal(acceptProof, vector.acceptProof, "accept proof")

    var sequence = vector.frame.sequence.bigEndian
    let aad = withUnsafeBytes(of: &sequence) { Data($0) }
    let sealed = try ChaChaPoly.SealedBox(combined: base64URLDecode(vector.frame.combined))
    let plaintext = try ChaChaPoly.open(sealed, using: sessionKey, authenticating: aad)
    guard plaintext == Data(vector.frame.plaintext.utf8) else {
        throw ValidationError.mismatch("mismatch: encrypted frame")
    }
    let expectedNonce = try base64URLDecode(vector.frame.nonce)
    guard sealed.nonce.withUnsafeBytes({ Data($0) }) == expectedNonce else {
        throw ValidationError.mismatch("mismatch: frame nonce")
    }
    print("SideCursor v2 interoperability vector: OK")
} catch {
    fputs("SideCursor v2 interoperability vector: FAILED — \(error)\n", stderr)
    exit(1)
}
