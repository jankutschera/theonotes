// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

/// The persisted identity strings that still carry the working title (REN2-R46). Every source file that needs
/// one of them reads it here, so the cutover (task B7) and the later removal (B8) touch one file.
///
/// `bundleRoot` is mirrored by `config/identity.env` (`THEONOTES_BUNDLE_ROOT`), which project.yml feeds to every
/// bundle id, UTType and URL type; `IdentityPinsTests` and `scripts/check-identities.sh` fail when they differ.
/// The twelve crypto and protocol labels are not here: they never change and live in `ProtocolLabels`.
public enum LegacyNames {
    /// Folder in Application Support that held the library before the rename (`Baerchen`).
    public static let libraryFolder = "Baerchen"
    /// SQLite file name inside a library folder.
    public static let databaseFile = "Baerchen.sqlite"
    /// File extension of a full library backup, without the dot.
    public static let backupExtension = "baerchen-backup"
    /// Type identifier of the first release's backup file, imported so old backups open (Info.plist `UTImportedTypeDeclarations`).
    /// A literal, not derived from `bundleRoot`: it names the OLD bundle root and must not follow the cutover (B7, REN2-R57).
    public static let backupUTI = "com.truebrewbirdie.baerchen.backup"
    /// Root of the production bundle id, the Keychain services and the exported types.
    public static let bundleRoot = "com.truebrewbirdie.theonotes"
    /// Old URL scheme; `theonotes` is the current one. The dev build's old scheme is `urlScheme + "-dev"`.
    public static let urlScheme = "baerchen"
    /// Old name of the data-folder environment variable; `THEONOTES_DATA_DIR` wins when both are set.
    public static let dataDirEnvironment = "BAERCHEN_DATA_DIR"
    /// Old theme ids (also the names of the bundled theme files) and the id each one becomes.
    public static let themeIDs: [String: String] = ["baerchen-red": "theo-red", "baerchen-dark": "theo-dark"]

    /// Default light and dark theme ids as stored today; the keys of `themeIDs`.
    public static let lightThemeID = "baerchen-red"
    public static let darkThemeID = "baerchen-dark"
    /// Exported type identifiers of the two drag payloads of the Mac app (Info.plist).
    public static let noteIDsUTI = bundleRoot + ".note-ids"
    public static let tagPathUTI = bundleRoot + ".tag-path"
    /// The bundle root before the Mac and iOS identity cutovers.
    public static let preCutoverBundleRoot = "com.truebrewbirdie.baerchen"
    /// Keychain service of the sync session and keys (`KeychainSyncStore`).
    public static let syncKeychainService = bundleRoot + ".sync"
    /// Keychain service of the Touch ID copy of the note vault key (`KeychainVaultKeyCache`, Mac app).
    public static let vaultKeychainService = bundleRoot + ".note-vault"
}
