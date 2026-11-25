// Offline, synthetic fixture provenance. Never linked into TheoNotesCore or run by tests.
// Run from the repository root: swift Fixtures/crypto/v1/generate.swift
import CommonCrypto
import CryptoKit
import Foundation

func bytes(_ start: Int, _ count: Int) -> Data {
    Data((start..<(start + count)).map { UInt8(truncatingIfNeeded: $0) })
}
func seal(_ plain: Data, key: Data, nonce: Data, aad: Data) throws -> Data {
    try AES.GCM.seal(plain, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: nonce),
                     authenticating: aad).combined!
}
func be(_ value: Int) -> Data {
    withUnsafeBytes(of: UInt32(value).bigEndian) { Data($0) }
}
func digest(_ value: Data) -> String { Data(SHA256.hash(data: value)).base64EncodedString() }

let vault = bytes(0, 32), salt = bytes(160, 16), password = "café synthetic 🔐"
let iterations = 1_000
let passwordBytes = Array(password.precomposedStringWithCanonicalMapping.utf8)
var derived = [UInt8](repeating: 0, count: 32)
let status = salt.withUnsafeBytes { s in
    passwordBytes.withUnsafeBytes { p in
        CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), p.bindMemory(to: Int8.self).baseAddress,
                            passwordBytes.count, s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations), &derived, 32)
    }
}
precondition(status == kCCSuccess)
let wrappedVault = try seal(vault, key: Data(derived), nonce: bytes(16, 12), aad: Data("baerchen-envelope-v1".utf8))
let envelope: [String: Any] = ["version": 1, "kdf": "pbkdf2-sha256", "salt": salt.base64EncodedString(),
                               "iterations": iterations, "wrappedVaultKey": wrappedVault.base64EncodedString()]

let noteId = "synthetic-note-01", blob = "synthetic-attachment-01.bch"
let payload = #"{"version":1,"text":"Synthetic note 漢字 👩‍👩‍👧","attachments":{"diagram.png":"synthetic-attachment-01.bch"},"attachmentIDs":{"diagram.png":"synthetic-attachment-01"}}"#
let noteKey = bytes(32, 32), noteAAD = Data(("BNC1" + noteId).utf8)
let bnc = try Data("BNC1".utf8)
    + seal(noteKey, key: vault, nonce: bytes(48, 12), aad: noteAAD)
    + seal(Data(payload.utf8), key: noteKey, nonce: bytes(64, 12), aad: noteAAD)

let fileKey = bytes(64, 32), prefix = bytes(112, 8)
let header = try Data("BCH1".utf8) + prefix
    + seal(fileKey, key: vault, nonce: bytes(96, 12), aad: Data("BCH1".utf8) + prefix + Data(blob.utf8))
var chunks: [[String: Any]] = []
for size in [0, 17, 65_536, 65_553] {
    let plain = bytes(0, size)
    var encrypted = header
    let count = max(1, (size + 65_535) / 65_536)
    for index in 0..<count {
        let chunk = Data(plain.dropFirst(index * 65_536).prefix(65_536))
        let box = try seal(chunk, key: fileKey, nonce: prefix + be(index),
                           aad: header + be(index) + Data([index == count - 1 ? 1 : 0]))
        encrypted += box.dropFirst(12)
    }
    chunks.append(["size": size, "sealed": encrypted.base64EncodedString()])
}

let baseJSON = #"{"v":1,"storeRevision":7,"baseText":"Synthetic base 漢字"}"#
let entryJSON = [#"{"v":1,"txId":"synthetic-tx-1","baseRevision":7,"changeSet":[[0,"Synthetic edit 👩‍👩‍👧"]]}"#,
                 #"{"v":1,"txId":"synthetic-tx-2","baseRevision":7,"changeSet":[[0,"Second edit"]]}"#]
let baseAAD = try JSONEncoder().encode(["baerchen-journal-v1", noteId, "base"])
let base = try Data(("BJB1:" + seal(Data(baseJSON.utf8), key: vault, nonce: bytes(128, 12), aad: baseAAD).base64EncodedString()).utf8)
var lines: [String] = [], entryAAD: [String] = [], previous = ""
for (index, plain) in entryJSON.enumerated() {
    let aad = try JSONEncoder().encode(["baerchen-journal-v1", noteId, "entry:\(digest(base)):\(index):\(previous)"])
    let line = try "BJE1:" + seal(Data(plain.utf8), key: vault, nonce: bytes(144 + index * 16, 12), aad: aad).base64EncodedString()
    lines.append(line)
    entryAAD.append(String(decoding: aad, as: UTF8.self))
    previous = digest(Data(line.utf8))
}
let fixture: [String: Any] = [
    "vaultKey": vault.base64EncodedString(), "password": password,
    "derivedKey": Data(derived).base64EncodedString(), "envelope": envelope,
    "noteId": noteId, "blobName": blob, "payloadJSON": payload, "bnc1": bnc.base64EncodedString(),
    "bch1": chunks, "baseJSON": baseJSON, "entryJSON": entryJSON,
    "bjb1": String(decoding: base, as: UTF8.self), "bje1": lines,
    "baseAAD": String(decoding: baseAAD, as: UTF8.self), "entryAAD": entryAAD,
    "unsupportedBaseVersion": try "BJB1:" + seal(Data(baseJSON.replacingOccurrences(of: #""v":1"#, with: #""v":2"#).utf8),
        key: vault, nonce: bytes(192, 12), aad: baseAAD).base64EncodedString(),
    "unsupportedEntryVersion": try "BJE1:" + seal(Data(entryJSON[0].replacingOccurrences(of: #""v":1"#, with: #""v":2"#).utf8),
        key: vault, nonce: bytes(208, 12), aad: Data(entryAAD[0].utf8)).base64EncodedString()]
let output = try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
try (output + Data([10])).write(to: URL(fileURLWithPath: "Fixtures/crypto/v1/canonical.json"))
