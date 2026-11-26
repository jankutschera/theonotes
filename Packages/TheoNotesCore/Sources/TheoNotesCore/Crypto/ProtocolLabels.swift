// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

/// The twelve frozen crypto and protocol labels. They are opaque byte strings, not a name
/// they are the AAD of locked-note envelopes and edit journals already on disk, the HKDF `info` and salt of the
/// sync account keys, and part of the request-signature transcript the sync Worker verifies. Changing one byte
/// makes existing data undecryptable or every signature fail, so they are never renamed with the product.
///
/// The private sync server (not part of this repository) keeps its own copy. `IdentityPinsTests` pins the bytes
/// here and `Fixtures/sync/protocol-v1.json` holds them for any other implementation. A new format (`:2`, CloudKit sync) uses
/// neutral labels from day one and keeps reading `:1`; see `docs/crypto-labels.md`.
public enum ProtocolLabels {
    /// AAD of the wrapped vault key in `CryptoEnvelope`.
    public static let envelope = "baerchen-envelope-v1"
    /// First element of the AAD array of every edit-journal base and entry.
    public static let journal = "baerchen-journal-v1"
    /// Prefix of the sync cipher context `<label>:<account>:<type>:<entity>:1`.
    public static let syncCipher = "baerchen-sync:1"
    /// Prefix of the account key derivation info and of the per-purpose cipher contexts.
    public static let account = "baerchen-account:1"
    /// Prefix of the device-transfer transcript.
    public static let transfer = "baerchen-transfer:1"
    /// HKDF shared info of the device-transfer key.
    public static let transferKey = "baerchen-transfer-key:1"
    /// HKDF info of the transfer confirmation words.
    public static let transferWords = "baerchen-transfer-words:1"
    /// Prefix of the cipher context of an encrypted device name.
    public static let deviceName = "baerchen-device-name:1"
    /// Prefix of the hash input of a deterministic conflict-copy id.
    public static let conflict = "baerchen-conflict:1"
    /// First line of the signed request transcript (client and Worker).
    public static let request = "baerchen-request:1"
    /// First line of the recovery-enrolment signature transcript (client and Worker).
    public static let recovery = "baerchen-recovery:1"
    /// Prefix of the hash input of a semantic (content-addressed) entity id.
    public static let semanticID = "baerchen-semantic-id:1"
}
