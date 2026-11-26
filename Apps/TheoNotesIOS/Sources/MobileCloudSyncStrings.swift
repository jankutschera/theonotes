// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation

/// Every word the Settings ▸ iCloud page and its two sheets show on the iPhone and iPad, in one place, so that a wording decision is
/// one edit. It follows the Mac's `CloudSyncStrings` where the sentence still fits ("this Mac" becomes "this device"; the
/// Keychain sentence says "Settings"). The words are plain: no "CloudKit", "zone", "record", "token", "quarantine", and the 24
/// words are always "recovery words" (never "recovery key", never "revoke": replacing them locks nobody out).
/// `MobileCloudSyncStringsTests` pins that nothing here uses a banned word and that no sentence names a Mac.
enum MobileCloudSyncStrings {
    // MARK: page and switch

    static let pageTitle = "iCloud"
    static let switchLabel = "Sync with iCloud"
    static let switchHelpOff = """
        Off until you turn it on. Theo Notes then saves a backup of the notes on this device, keeps your notes in your own iCloud and \
        brings them to your other devices. Your notes are encrypted on this device before they leave it.
        """
    static let switchHelpOn = "Your notes stay on this device, and a copy is kept in step through your own iCloud."
    static let savingBackupFirst = "Saving a backup first"
    static let workingLabel = "Working on iCloud sync"
    static let lastSyncLabel = "Last sync"

    /// A library that syncs through the private server shows this instead of the switch (Jan’s builds only).
    static let privateServerLibrary = "This library syncs through your private server"
    /// A build that lacks iCloud sync or the private-server sync cannot move the library.
    static let privateServerDetail = "This version of Theo Notes cannot move it to iCloud."

    // MARK: move this library to iCloud

    static let moveDetail = "You can move it to iCloud. The notes on this device stay as they are. Move each of your devices, one after the other, and do not change notes in between."
    static let moveButton = "Move This Library to iCloud…"
    static let moveTitle = "Move This Library to iCloud?"
    /// Two short paragraphs: what happens, then what the person must do (design r3). The last sync and the backup are on the progress line.
    static let moveMessage = """
        This device stops using your private server and switches to iCloud. A backup is saved first. The notes here stay as they are, \
        and nothing is deleted from the server.

        Move your other devices right after this one. Until all have moved, do not change, delete or trash notes on any of them.
        """
    static let moveConfirm = "Move to iCloud"
    static let moveProgress = "Syncing with your private server one last time and saving a backup"
    /// Stays in the sync settings after a move until the owner dismisses it: a bold title, then the step in secondary text.
    static let moveNoticeTitle = "Move Your Other Devices Now"
    static let moveOtherDevicesNotice = "On each device, open Settings ▸ iCloud and choose Move This Library to iCloud. Until all have moved, do not change, delete or trash notes on any of them, because such changes can come back or turn into a second copy."
    /// Next to the notice while iCloud sync is not running after a move (design r3): a bold title, then the rest in secondary text.
    static let moveSyncOffTitle = "iCloud Sync Is Off"
    static let moveSyncOff = "This device does not sync with your other devices. The notes here are safe. Turn on Sync with iCloud below to finish the move."
    static let moveSyncBlockedTitle = "iCloud Sync Could Not Start Yet"
    static let moveSyncBlocked = "This device does not sync with your other devices. The notes here are safe. What stops it, and what to do, is shown below."
    static let moveNoticeDismiss = "Dismiss"
    static let moveNotConnected = "This device is not connected to your private server, so it cannot sync one last time. Connect it in the Sync settings, then try again. Nothing was moved."
    static let movePaused = "Sync with your private server is paused. Resume it in the Sync settings, then try again. Nothing was moved."
    static let moveOffline = "Your private server could not be reached. Nothing was moved: your other devices may have changes this device has not received yet. Try again when you are online."
    static let moveFirstSyncUnfinished = "This library’s first sync with your private server has not finished. Nothing was moved."
    static let moveBusy = "Something is still being saved or synced. Nothing was moved. Try again in a moment."
    static func moveUnavailable(notes: [String], moreNotes: Int, canMoveWithout: Bool = false) -> String {
        let quoted = notes.map { "“" + $0 + "”" }
        let list: String
        if moreNotes > 0 { list = quoted.joined(separator: ", ") + " and \(moreNotes) more" }
        else if quoted.count > 1 { list = quoted.dropLast().joined(separator: ", ") + " and " + quoted.last! }
        else { list = quoted.first ?? "" }
        if canMoveWithout {
            return ([missingFilesTitle, missingFilesCount(notes.count + moreNotes)] + notes
                + (moreNotes > 0 ? [missingFilesMore(moreNotes)] : []) + [missingFilesWithout, nothingMovedYet]).joined(separator: "\n")
        }
        return "Some attachment files are missing on this device, so they can never reach your private server. Notes: " + list
            + ". Put the file back or remove the attachment from the note, then move again. Nothing was moved."
    }
    /// The card when the missing files may be left behind, the same words on the Mac: a bold title, then short
    /// secondary lines, one note title per line.
    static let missingFilesTitle = "Some Attachments Are Missing"
    static func missingFilesCount(_ notes: Int) -> String {
        notes == 1 ? "1 note links to one or more files that never reached this device or your private server:"
            : "\(notes) notes link to files that never reached this device or your private server:"
    }
    static func missingFilesMore(_ count: Int) -> String { "and \(count) more" }
    static let missingFilesWithout = "You can move without these files. The notes move as they are and keep showing the missing file."
    static let nothingMovedYet = "Nothing has been moved yet."
    static let moveWithoutFilesButton = "Move to iCloud Without These Files…"
    /// The normal confirmation plus one sentence.
    static let moveWithoutFilesMessage = moveMessage + "\n\nThe missing attachment files stay missing."
    static func moveUnsent(_ count: Int) -> String {
        (count == 1 ? "1 change on this device has" : "\(count) changes on this device have") + " not reached your private server yet. Nothing was moved. Try again in a moment."
    }
    static func moveUnreceived(_ count: Int) -> String {
        (count == 1 ? "1 change from your other devices is" : "\(count) changes from your other devices are")
            + " not on this device yet. Some may wait for your note password or a file. Nothing was moved."
    }
    /// A separate recovery library (made while reconciling different note vaults) never syncs with iCloud.
    static let libraryNeverSyncs = "This is a separate recovery library, so it never syncs with iCloud. Return to your original library to use iCloud."
    static let notInThisBuild = "iCloud sync is not part of this version of Theo Notes. Your notes stay on this device."

    // MARK: status

    /// What the status line says. The words of `CloudSyncState.message` are used where they already say the right thing; the Keychain
    /// sentence names the iPhone's Settings app, and the key failures that need a sentence of their own are written here.
    static func status(for state: CloudSyncState) -> String {
        switch state {
        case .keychainUnavailable:
            return "Theo Notes cannot reach iCloud Keychain. Check that iCloud Keychain is turned on in Settings."
        case .failed(let kind):
            switch kind {
            case "keyBundleUnreadable":
                return "The key that opens your iCloud copy could not be read. Nothing was changed. Theo Notes will try again, and an update may help."
            case "keyRollback":
                return "The key in iCloud is older than the one this device already trusts, so sync stopped to keep your notes safe. Nothing was changed."
            case "keyMismatch", "keys":
                return "The key on this device does not match the one in iCloud, so sync stopped to keep your notes safe. Nothing was changed. Enter your recovery words, or turn sync off and on again."
            case "keyBundleMissing":
                return "The key that opens your iCloud copy is missing from iCloud. Nothing was changed on this device."
            default:
                return CloudSyncState.message(for: state)
            }
        default:
            return CloudSyncState.message(for: state)
        }
    }

    /// The short name shown next to the status icon.
    static func headline(for state: CloudSyncState) -> String {
        switch state {
        case .off: "Off"
        case .notAvailableInThisBuild: "Not available"
        case .signedOutOfICloud: "Not signed in to iCloud"
        case .restricted: "iCloud is restricted"
        case .waitingForICloud, .waitingForKeychain: "Waiting"
        case .keychainUnavailable: "iCloud Keychain is off"
        case .needsRecoveryKey: "Recovery words needed"
        case .recoveryNotSaved: "Recovery words not saved"
        case .needsNotePassword: "Note password needed"
        case .accountChanged: "Different iCloud account"
        case .zoneRemoved: "iCloud copy removed"
        case .itemsMissingInCloud: "Some notes are missing in iCloud"
        case .quotaFull: "iCloud storage is full"
        case .offline: "Offline"
        case .syncing: "Syncing"
        case .upToDate: "Up to date"
        case .paused: "Paused"
        case .needsAppUpdate: "Update needed"
        case .itemsUnreadable: "Some items cannot be read yet"
        case .failed(let kind): kind == "journalKeyUnavailable" ? "Waiting for notes key" : (kind.hasPrefix("vaultPartial:") ? "Some protected notes need another password" : "Stopped to keep your notes safe")
        }
    }

    // MARK: waiting for iCloud Keychain

    /// G0 A6: one Keychain item never reached the second device. While the key has not arrived the person can type the recovery words
    /// instead (the coordinator offers the route after ten minutes; the page shows it from the first moment of the wait).
    static let keychainWaitTitle = "Waiting for iCloud Keychain"
    static let keychainWaitDetail = """
        The key that opens your iCloud copy is on its way from your other device through iCloud Keychain. This usually takes a few \
        minutes. If it has not arrived after ten minutes, type your recovery words instead.
        """

    // MARK: actions

    static let stopSyncing = "Stop syncing"
    static let stopSyncingDetail = "Stops syncing on this device. Nothing is deleted, not here and not in iCloud, and other devices keep syncing."
    static let deleteCopy = "Delete my iCloud copy…"
    static let deleteCopyTitle = "Delete your iCloud copy?"
    static let deleteCopyButton = "Delete iCloud Copy"
    static let deleteCopyMessage = """
        This deletes the copy of your notes that Theo Notes keeps in your iCloud, including every attachment in it, and stops syncing on this device. \
        The notes on this device stay exactly as they are. Your other devices keep their own notes but stop syncing until you upload again.
        """
    static let deleteCopyDone = "Your iCloud copy was deleted. The notes on this device are untouched."

    static let advanced = "Advanced"
    static let removeKey = "Remove the iCloud key from all my devices…"
    static let removeKeyTitle = "Ask iCloud Keychain to remove the key from all your devices?"
    static let removeKeyButton = "Remove the Key"
    /// Honest about what this does: it asks iCloud Keychain, which removes the key where it is reachable.
    static func removeKeyMessage(recoverySaved: Bool) -> String {
        let base = """
            This stops syncing on this device and asks iCloud Keychain to remove the key that opens your iCloud copy from all your devices. \
            A device that is offline removes it when it next connects. A device where Theo Notes is open right now may still hold the key until \
            it restarts. Your iCloud copy is not deleted and the notes on your devices stay. A device without the key needs your recovery words \
            to open the copy again.
            """
        return recoverySaved ? base : base + " You have not saved recovery words, so a device that has lost the key could not open the copy again."
    }
    static let removeKeyDone = "Theo Notes asked iCloud Keychain to remove the key. Other devices may take a while, or until they restart, to let go of it. Your notes here are untouched."

    static let useRecoveryWords = "Use recovery words"
    static let useRecoveryWordsDetail = "Type the 24 recovery words you saved, in order, separated by spaces."
    static let useRecoveryWordsField = "24 recovery words"
    static let useRecoveryWordsButton = "Unlock Synced Notes"
    static let recoveryWordsWrong = "Those words do not open your synced notes. Check all 24 words and their order."

    static let notePasswordPrompt = "Enter your note password to start syncing. This library has protected notes."
    static let notePasswordField = "Note password"
    static let notePasswordButton = "Continue"
    static let notePasswordWrong = "That is not the note password. Nothing was synced."

    static let uploadAgain = "Upload again"
    static let uploadAgainDetail = "Makes a new copy of the notes on this device in your iCloud. Notes that other devices changed in the meantime are merged, not replaced."
    static let uploadThemAgain = "Upload them again"
    static let uploadThemAgainDetail = "Puts the notes that went missing in iCloud back from this device. Nothing on this device is changed or deleted."

    static let openSettings = "Open Settings"
    static let syncNow = "Sync now"

    // MARK: recovery words

    static let recoverySection = "Recovery words"
    static let recoverySavedLine = "Saved. You can use them to get your notes back if you lose every device."
    static let recoveryNotSavedLine = "Not saved yet. Without them, your notes in iCloud cannot be recovered if you lose all your devices and iCloud Keychain."
    static let createRecoveryWords = "Create recovery words…"
    static let replaceRecoveryWords = "Replace recovery words…"
    /// One sentence that devices already set up keep working, and one that this does not lock anybody out.
    static let replaceRecoveryDetail = "Devices that are already set up keep working. Replacing the words does not lock out anyone who already has the old ones."
    static let recoveryReplaced = "Your new recovery words are saved. The old ones are no longer the ones to keep."
    static let recoveryChangedElsewhere = "Another device changed the recovery words first. Use the newest words from that device."

    /// Shown when this device and another set up iCloud sync at the same moment and this one lost.
    static let lostSetupRaceDismiss = "OK"
    static let lostSetupRaceTitle = "Another device set up first"
    static let lostSetupRace = """
        Another of your devices set up iCloud sync at the same moment. The recovery words you just saved belong to a setup that was dropped and protect \
        nothing. Use the recovery words shown on the other device.
        """

    // MARK: vault conversion

    /// `CloudVaultConversionError.syncMustBeOff` (changing which note password protects a library is not possible while sync is on).
    static let turnSyncOffFirst = "Turn iCloud sync off first. Changing the note password or converting protected notes cannot happen while sync is on. Turn sync off, make the change, then turn it back on."

    // MARK: sheet: recovery words

    static let sheetTitle = "Save your recovery words"
    static let sheetSetupIntro = """
        These 24 words get your notes back if you lose every device. Write them down and keep them somewhere safe and separate from this device. \
        Theo Notes never stores them.
        """
    static let sheetLaterIntro = "These 24 words get your notes back if you lose every device. Write them down and keep them somewhere safe and separate from this device."
    static let sheetCopy = "Copy words"
    static let sheetCopied = "Copied. The clipboard is cleared in a minute."
    static let sheetCheckTitle = "Check that you saved them"
    static func sheetCheckPrompt(position: Int) -> String { "Word \(position)" }
    static let sheetCheckIntro = "Type three of the words to show you wrote them down."
    static let sheetSave = "Save recovery words"
    static let sheetWrongWords = "One of the words is not right. Check your copy and try again."
    static let sheetSkipHeader = "Or set them up later"
    static let sheetRiskSentence = "If I lose all my devices and iCloud Keychain, my notes in iCloud cannot be recovered"
    static let sheetSkip = "Skip for now"
    static let sheetCancel = "Cancel"
    static let sheetCancelSetup = "Cancel and keep sync off"
    static let sheetShowWords = "Show the words"
    static let sheetHideWords = "Hide the words"
    static func sheetWordAccessibility(position: Int, word: String) -> String { "Word \(position), \(word)" }
    static let sheetWordsHidden = "The words are hidden while Theo Notes is in the background."

    // MARK: sheet: account changed

    static let accountChangedTitle = "A different iCloud account"
    static let accountChangedMessage = """
        This device is now signed in to a different iCloud account than the one these notes sync with. Sync is paused so that your notes do not end \
        up in the wrong account.
        """
    static let keepOffline = "Keep this library offline"
    static let keepOfflineDetail = "Your notes stay on this device and nothing is sent to the new account. You can turn sync on again whenever you like."
    static let syncWithNewAccount = "Sync with the new iCloud account"
    static let syncWithNewAccountDetail = "Saves a backup, then starts a fresh sync with the new account. The old account’s copy is not touched."
    static let accountChangedContinue = "Decide later"

    // MARK: errors

    static let ownedElsewhere = "Theo Notes is already syncing this library in another window or process. Close it there first."
    static let backupFailed = "The backup of the notes on this device could not be checked, so nothing was changed. Try again."
    static let cannotDeleteCopy = "The iCloud copy could not be deleted right now. Sync is off on this device and nothing was lost. Try again when you are online."
    static let accountNotCurrent = "This device is signed in to a different iCloud account than the one these notes sync with, so nothing was changed in iCloud."
    static let uploadAgainNeedsKey = "This device no longer has the verified key it needs to make the copy again, so nothing was changed. Your notes here are safe. Use Delete my iCloud copy, then turn sync on again to start a new copy."
    static let genericProblem = "Something went wrong. Nothing was lost; try again in a moment."

    /// The banned words, for the test and for anyone adding a string. (The two that the copy guard looks for are written in pieces.)
    static let bannedWords = ["cloudkit", "zone", "record", "token", "quarantine", "adh" + "d", "adh" + "s", "revoke", "recovery key"]

    /// Every constant above, for the tests that scan the wording.
    static var all: [String] {
        let fixed = [
            pageTitle, switchLabel, switchHelpOff, switchHelpOn, savingBackupFirst, workingLabel, lastSyncLabel, privateServerLibrary,
            privateServerDetail, libraryNeverSyncs, notInThisBuild, keychainWaitTitle, keychainWaitDetail, stopSyncing, stopSyncingDetail,
            deleteCopy, deleteCopyTitle, deleteCopyButton, deleteCopyMessage, deleteCopyDone, advanced, removeKey, removeKeyTitle,
            removeKeyButton, removeKeyDone, lostSetupRaceDismiss, sheetWordAccessibility(position: 1, word: "word"),
            useRecoveryWords, useRecoveryWordsDetail, useRecoveryWordsField, useRecoveryWordsButton, recoveryWordsWrong, notePasswordPrompt,
            notePasswordField, notePasswordButton, notePasswordWrong, uploadAgain, uploadAgainDetail, uploadThemAgain, uploadThemAgainDetail,
            openSettings, syncNow, recoverySection, recoverySavedLine, recoveryNotSavedLine, createRecoveryWords, replaceRecoveryWords,
            replaceRecoveryDetail, recoveryReplaced, recoveryChangedElsewhere, lostSetupRaceTitle, lostSetupRace, turnSyncOffFirst, sheetTitle,
            sheetSetupIntro, sheetLaterIntro, sheetCopy, sheetCopied, sheetCheckTitle, sheetCheckIntro, sheetSave, sheetWrongWords, sheetSkipHeader,
            sheetRiskSentence, sheetSkip, sheetCancel, sheetCancelSetup, sheetShowWords, sheetHideWords, sheetWordsHidden, accountChangedTitle,
            accountChangedMessage, keepOffline, keepOfflineDetail, syncWithNewAccount, syncWithNewAccountDetail, accountChangedContinue,
            genericProblem, accountNotCurrent, uploadAgainNeedsKey, ownedElsewhere, backupFailed, cannotDeleteCopy,
            removeKeyMessage(recoverySaved: true), removeKeyMessage(recoverySaved: false), sheetCheckPrompt(position: 1),
            moveDetail, moveButton, moveTitle, moveMessage, moveConfirm, moveProgress, moveNoticeTitle, moveOtherDevicesNotice, moveSyncOffTitle, moveSyncOff, moveSyncBlockedTitle, moveSyncBlocked, moveNoticeDismiss, moveNotConnected, movePaused, moveOffline,
            moveFirstSyncUnfinished, moveBusy, moveUnsent(1), moveUnsent(3), moveUnreceived(1), moveUnreceived(2), moveUnavailable(notes: ["A"], moreNotes: 0), moveUnavailable(notes: ["A", "B"], moreNotes: 3), moveUnavailable(notes: ["A"], moreNotes: 0, canMoveWithout: true), moveUnavailable(notes: ["A", "B", "C", "D", "E"], moreNotes: 1, canMoveWithout: true), moveWithoutFilesButton, moveWithoutFilesMessage,
        ]
        let states: [CloudSyncState] = [
            .off, .notAvailableInThisBuild, .signedOutOfICloud, .restricted, .waitingForICloud, .waitingForKeychain, .keychainUnavailable,
            .needsRecoveryKey, .recoveryNotSaved, .needsNotePassword, .accountChanged(previousHash: "x"), .zoneRemoved(reason: .deleted),
            .zoneRemoved(reason: .encryptedDataReset), .itemsMissingInCloud(count: 1), .itemsMissingInCloud(count: 3), .quotaFull,
            .offline(retryAt: nil), .syncing, .upToDate(lastSync: nil), .paused, .needsAppUpdate, .itemsUnreadable(count: 1),
            .itemsUnreadable(count: 2), .failed(kind: "other"), .failed(kind: "keyBundleUnreadable"), .failed(kind: "keyRollback"),
            .failed(kind: "keyMismatch"), .failed(kind: "keys"), .failed(kind: "keyBundleMissing"),
        ]
        return fixed + states.flatMap { [status(for: $0), headline(for: $0)] }
    }
}
