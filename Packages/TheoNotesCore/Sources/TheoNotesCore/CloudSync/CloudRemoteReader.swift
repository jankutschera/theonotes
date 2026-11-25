// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// Opens a sealed payload and validates it per entity type (class (c) of the E0 record: a copy of the per-type switch of
/// `SyncPayloadReader.read`, fed from plain values instead of a `SyncEntity`). The tombstone is not a wire flag here; it is the
/// kind byte inside the plaintext (CK-R17), which `CloudPayloadSealer.open` splits off.
///
/// Drift guard: `CloudRemoteReaderDifferentialTests` opens the same payloads through this reader and through the Cloudflare
/// original, valid and every invalid shape, and requires equal outcomes. A later fix to one reader that does not reach the other
/// fails that test.
struct CloudRemoteReader: Sendable {
    let sealer: CloudPayloadSealer

    /// - Throws: `CryptoError.tampered` (authentication failure, including a payload sealed for another entity or account),
    ///   `SyncProtocolError.invalidPayload` / `.unsupportedVersion` / `.responseTooLarge`, or a decoding error.
    /// `blobRefs: nil` skips the check that an attachment snapshot's blob is listed (used for an ancestor, which was validated
    /// when it was applied or sent and whose reference list the base pair does not keep).
    func read(sealed: Data, type: SyncEntityType, entityId: String, blobRefs: [String]?) throws -> SyncRemoteValue {
        let opened = try sealer.open(sealed, type: type, entityID: entityId)
        let plain: Data
        switch opened {
        case .deleted: return .deleted
        case .live(let body): plain = body
        }
        switch type {
        case .note:
            let value = try SyncPayloadCodec.decode(SyncNotePayload.self, from: plain)
            try value.validate()
            guard value.id == entityId else { throw SyncProtocolError.invalidPayload }
            guard (value.attachmentSnapshots ?? [:]).values.allSatisfy({ blobRefs?.contains($0.blobHash) ?? true }) else { throw SyncProtocolError.invalidPayload }
            for tag in value.directTags + value.pinnedTags { _ = try NoteStore.tagToken(tag) }
            return .note(value)
        case .attachment:
            let value = try SyncPayloadCodec.decode(SyncAttachmentPayload.self, from: plain)
            try value.validate()
            guard value.id == entityId, blobRefs?.contains(value.blobHash) ?? true else { throw SyncProtocolError.invalidPayload }
            return .attachment(value)
        case .tagPreference:
            let value = try SyncPayloadCodec.decode(SyncTagPreferencePayload.self, from: plain)
            guard value.version == 1 else { throw SyncProtocolError.unsupportedVersion }
            _ = try NoteStore.tagToken(value.path)
            return .tag(value)
        case .setting:
            let value = try SyncPayloadCodec.decode(SyncSettingPayload.self, from: plain)
            try value.validate()
            return .setting(value)
        case .externalRef:
            let value = try SyncPayloadCodec.decode(SyncExternalRefPayload.self, from: plain)
            guard value.version == 1, !value.source.isEmpty, !value.externalId.isEmpty,
                  value.source.utf8.count <= 1024, value.externalId.utf8.count <= 4096 else { throw SyncProtocolError.invalidPayload }
            if let id = value.noteId { try SyncWire.validateID(id) }
            return .externalRef(value)
        case .keyBundle:
            let value = try SyncPayloadCodec.decode(SyncLockEnvelopePayload.self, from: plain)
            let envelope = try JSONDecoder().decode(CryptoEnvelope.self, from: value.envelope)
            guard value.version == 1, envelope.version == 1, envelope.kdf == CryptoEnvelope.kdfName,
                  CryptoEnvelope.publicIterationRange.contains(envelope.iterations), envelope.salt.count == 16,
                  envelope.wrappedVaultKey.count == 60 else { throw SyncProtocolError.invalidPayload }
            return .lockEnvelope(value.envelope)
        }
    }
}

extension SyncRemoteValue {
    /// The same content, by the rule the merge itself uses for notes and by the canonical payload encoding for everything else.
    /// Used to prove that a version of another incarnation is exactly the version this device already holds.
    func sameContent(as other: SyncRemoteValue) -> Bool {
        func encoded<T: Encodable>(_ value: T) -> Data { (try? SyncPayloadCodec.encoder().encode(value)) ?? Data() }
        switch (self, other) {
        case (.deleted, .deleted): return true
        // The whole payload, attachment ids, names and snapshots included: the merge's own equality ignores the pins.
        case (.note(let a), .note(let b)): return encoded(a) == encoded(b)
        case (.attachment(let a), .attachment(let b)): return encoded(a) == encoded(b)
        case (.tag(let a), .tag(let b)): return encoded(a) == encoded(b)
        case (.setting(let a), .setting(let b)): return encoded(a) == encoded(b)
        case (.externalRef(let a), .externalRef(let b)): return encoded(a) == encoded(b)
        case (.lockEnvelope(let a), .lockEnvelope(let b)): return a == b
        default: return false
        }
    }
}
