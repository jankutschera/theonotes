# Canonical crypto v1 compatibility freeze

These are owned, synthetic compatibility vectors for the formats at `53ecae2`.
They freeze the existing core; they introduce no migration, envelope identifier,
context label, journal subkey, or new runtime crypto implementation.

`canonical.json` is the checked-in expectation consumed by
`CanonicalCryptoV1Tests` and `CanonicalJournalV1Tests`. Tests never generate their
own golden expectations. `generate.swift` is a standalone offline provenance
tool using only CryptoKit/CommonCrypto/Foundation. It does not import or call
TheoNotesCore. From the repository root, `swift Fixtures/crypto/v1/generate.swift`
reproduces the file. Regeneration is an explicit review action, never a test step.
JSON object key order is not a wire-format promise.

All passwords, identifiers, filenames, text, keys, salts, nonce bytes and
attachment contents are invented here. No library, Keychain, device or user data
was used. Known fixed keys/nonces are exclusively test material. The BCH vectors
deliberately share a header across boundary cases to isolate framing: this nonce
reuse is unsafe for real encryption and must never enter production. Production
writers retain their secure randomness and are tested through semantic decoding,
without any injected entropy seam.

## Primitive and envelope

- AES-256-GCM, 12-byte nonce, 16-byte tag. A combined box is
  `nonce || ciphertext || tag`; a wrapped 32-byte key is therefore 60 bytes.
- PBKDF2-HMAC-SHA256 produces 32 bytes from NFC-normalized UTF-8 password bytes.
  The fixture pins a 16-byte salt, 1,000 iterations, derived key and wrapped vault
  key. Only the existing internal `testIterationRange` admits that test envelope.
- Production create/rewrap uses 600,000 iterations. Existing public readers accept
  100,000 through 10,000,000; this freeze does not alter that compatibility range.
- `CryptoEnvelope` JSON fields are exactly `version` (1), `kdf`
  (`pbkdf2-sha256`), `salt` (base64), `iterations`, `wrappedVaultKey` (base64).
  The wrapped key AAD is the UTF-8 literal `baerchen-envelope-v1`.
- The envelope carries the actual 32-byte vault key, unchanged by password
  rewrapping. Bad authentication maps to `wrongPassword`; invalid parameters or
  combined framing map to `malformed`.

## BNC1: note body

`BNC1 || wrappedNoteKey[60] || combinedBodyBox[28 + plaintextLength]`.
Both GCM operations use AAD `UTF8("BNC1") || UTF8(rawNoteId)`.
There is no `note:` prefix. The body uses a fresh 32-byte note key wrapped directly
under the supplied vault key. The golden plaintext is the existing
`LockedNotePayload(version, text, attachments, attachmentIDs)` JSON, including a
synthetic real filename inside the ciphertext. Wrong context or authenticated
bytes map to `tampered`; unknown magic or too-short framing maps to `malformed`.

## BCH1: attachments

The 72-byte header is `BCH1 || noncePrefix[8] || wrappedFileKey[60]`.
The file key is wrapped under the supplied vault key with AAD
`UTF8("BCH1") || noncePrefix || UTF8("<attachmentId>.bch")`.
The context includes `.bch`; there is no `attachment:` prefix.

Plaintext chunks are at most 65,536 bytes. Each on-disk chunk contains ciphertext
and its 16-byte tag, with no stored nonce or length. Counter starts at zero.
The nonce is `noncePrefix || UInt32BE(counter)`; AAD is
`header || UInt32BE(counter) || finalByte`, with finalByte 0 or 1. Empty input
still has one final, empty chunk. An exact chunk boundary has a full final chunk,
not an extra empty chunk. The fixtures pin sizes 0, 17, 65,536 and 65,553.

Missing final chunks are `truncated`; tag/context/chunk-order authentication
failures are `tampered`. Unknown/truncated headers are `malformed`. Failed
decoding does not replace an existing destination and removes its temp file.

## BJB1/BJE1: protected edit journal

- Base file: `BJB1:` followed by standard base64 of a combined GCM box, no newline.
- Entries: each `BJE1:` followed by standard base64 of a combined GCM box, then LF.
  Base/entry plaintexts are the existing `JournalBase` and `JournalEntry` JSON,
  with inner `v = 1` and CodeMirror-array ChangeSet encoding.
- Both use the **supplied vault key directly**, with no HKDF or other journal key.
- AAD is the UTF-8 JSONEncoder encoding of this three-string array:
  `["baerchen-journal-v1", rawNoteId, kind]`. Preserve the default JSON string
  escaping, including escaped `/` in base64 digest strings. Exact AAD bytes are
  included in the fixtures.
- Base kind is `base`. Entry kind is
  `entry:<baseDigest>:<zeroBasedIndex>:<previousDigest>`. Digests are standard
  base64 SHA-256 of the complete prefixed base/entry bytes **excluding LF**.
  The first previousDigest is the empty string. BaseDigest includes `BJB1:`.
- Two fixed entries pin chain order and previous/base binding. Writer tests also
  append onto the fixed chain, and independently open fresh writer bytes with
  the literal framing and CryptoKit primitives.
- Wrong note/key, changed complete records, invalid base64 or reordered/duplicated
  entries fail without mutating recovery files. Missing keys are `keyRequired`;
  unknown protected prefixes are `plaintextInEncryptedJournal` (current behavior).
  Authenticated inner `v = 2` fixtures pin `unsupportedVersion(2)` for both kinds.
  Existing encrypted-journal tests retain torn-unacknowledged-tail recovery and
  base-generation rejection coverage.

Compatibility tests supplement the existing randomness, round-trip, corruption
and recovery suites. They intentionally avoid public API or production changes.
