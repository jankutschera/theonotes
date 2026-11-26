# Frozen crypto and protocol labels

Twelve strings in the code still say `baerchen`. They are not a name. They are byte strings that
went into encrypted data and signatures, and they stay as they are for as long as that data exists.
The product rename (stage 2) leaves them alone on purpose.

One source in the apps: `ProtocolLabels` in `Packages/*/Sources/*/Crypto/ProtocolLabels.swift`. The private
sync server (not part of this repository) keeps its own copy and checks it against
`Fixtures/sync/protocol-v1.json`. `IdentityPinsTests` pins the Swift bytes and decrypts the checked-in
vectors. No other file may spell a label: use the constant.

## The twelve labels

| `ProtocolLabels` member | Bytes | Where it is used | What breaks if it changes |
|---|---|---|---|
| `envelope` | `baerchen-envelope-v1` | AAD of the wrapped vault key in `CryptoEnvelope` (library database, backups, synced key envelope) | every locked note: the vault key no longer unwraps |
| `journal` | `baerchen-journal-v1` | first element of the AAD of every edit-journal base and entry on disk | unsaved edits of locked notes cannot be read back |
| `syncCipher` | `baerchen-sync:1` | prefix of the cipher context `<label>:<account>:<type>:<entity>:1` of every sync payload | every payload already on the Worker or in CloudKit |
| `account` | `baerchen-account:1` | HKDF `info` of the account keys and prefix of their per-purpose cipher contexts | the key bundle, so all devices lose the account keys |
| `transfer` | `baerchen-transfer:1` | transcript prefix of a device-to-device key transfer | pairing a new device |
| `transferKey` | `baerchen-transfer-key:1` | HKDF shared info of the transfer key | pairing a new device |
| `transferWords` | `baerchen-transfer-words:1` | HKDF info of the confirmation words | the words no longer match on the two devices |
| `deviceName` | `baerchen-device-name:1` | cipher context of an encrypted device name | the device list shows unreadable names |
| `conflict` | `baerchen-conflict:1` | hash input of the deterministic id of a conflict copy | two devices stop agreeing on the id, so one conflict becomes two notes |
| `request` | `baerchen-request:1` | first line of the signed request transcript; the Worker rebuilds it (`auth.ts`) | every signed request is rejected (`invalid_signature`) |
| `recovery` | `baerchen-recovery:1` | first line of the recovery-enrolment transcript; the Worker rebuilds it (`keys.ts`) | recovery of the account on a new device |
| `semanticID` | `baerchen-semantic-id:1` | hash input of content-addressed entity ids | the same item gets a new id on every device, so it is duplicated |

Two of the rows look harmless and are not: `conflict` and `semanticID` only feed a hash, so nothing
fails loudly. The damage shows as duplicates after the next sync.

## Why they are frozen

- AAD and HKDF inputs are part of the ciphertext's contract. AES-GCM refuses data whose AAD differs by
  one byte; HKDF derives a different key. There is no "rename and migrate quietly": the old bytes are
  needed to read the old data, so a rename always means reading both.
- Some data is not ours to rewrite: backups Jan made earlier, the encrypted copies on the Worker and in
  other devices, and the journal of a note that is open right now.
- A label is an opaque value. Nobody sees it, so it does not carry the working title to a user, and the
  public source code showing it does not change what the product is called.
- The frozen strings also appear inside fixtures (`Fixtures/crypto/v1`, `Fixtures/sync/*`) and in the
  name-guard ledger (`scripts/name-guard.json`, `until: never`).

## Rules

1. Never edit a label, and never add a thirteenth `baerchen-*` label. A change to one of the twelve is a
   change to data on disk and needs a ruling that names the migration; the pins fail first.
2. A new format uses neutral labels from its first byte (`theonotes-<purpose>:2`, for example). The `:2`
   suffix is the version marker; `:1` stays assigned to the old labels and is never reused.
3. Every new label gets one constant per side, a row in the table above and a vector in `Fixtures`.
4. CloudKit sync is a new format and follows rule 2 for anything it introduces. It reuses the
   frozen `syncCipher` and `semanticID` only where it has to read or write the same payloads as the
   Cloudflare sync.

## Dual-read design for a future format

When a `:2` format exists, the reader decides by the format marker stored with the data, never by trying
labels until one decrypts (that would turn a corrupt file into a silent fallback):

1. Data carries its format: `payloadFormat` on sync mutations, `version` on the envelope and the journal
   records, the `:1` or `:2` in the cipher context.
2. The reader maps the marker to a label set (`1` to the twelve frozen labels, `2` to the neutral ones) and
   fails with a clear error for an unknown marker.
3. Writers keep writing `:1` until every device that shares the data can read `:2` (the Worker has to be able to report the
   minimum client protocol), then switch the new writes. Existing `:1` data is read forever and rewritten
   to `:2` only when it changes anyway.
4. The Worker verifies signatures with the transcript label named in the request, so an old client and a
   new client work side by side during the switch.

Nothing in this document is implemented yet beyond the constants; it is the shape the next format has to
follow.
