// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

/// REL-R20 ... REL-R29: the Apple team is one parameter (`THEONOTES_TEAM_ID`), read at runtime from the
/// signed binary or the Info.plist instead of a literal, so moving to the publishing team changes one line.
/// The values pinned for today's team stay in `AppIdentityTests`.
@Suite struct AppIdentityTeamTests {
    private let publishing = "ABCDE12345"

    @Test func theTeamIsReadFromTheSignedApplicationIdentifier() {
        let team = AppIdentity.teamPrefix(
            signedApplicationIdentifier: publishing + ".com.truebrewbirdie.theonotes",
            infoDictionary: ["THEONOTES_TeamID": "ZZZZZ99999"])
        #expect(team == publishing)
    }

    @Test func theTeamFallsBackToTheInfoPlistForAnAdHocBuild() {
        let team = AppIdentity.teamPrefix(
            signedApplicationIdentifier: nil,
            infoDictionary: ["THEONOTES_TeamID": publishing])
        #expect(team == publishing)
    }

    @Test func theTeamFallsBackToTodaysValueWhenNothingIsSigned() {
        #expect(AppIdentity.teamPrefix(signedApplicationIdentifier: nil, infoDictionary: nil) == "Q446J364FH")
        #expect(AppIdentity.teamPrefix(signedApplicationIdentifier: nil, infoDictionary: [:]) == "Q446J364FH")
    }

    @Test func aValueThatIsNotATeamIdIsIgnored() {
        // An unsubstituted build setting, an empty string, a wrong length or lower case must never become the
        // prefix of an App Group or keychain access group.
        for bad in ["$(THEONOTES_TEAM_ID)", "", "SHORT", "abcde12345", "ABCDE12345X", "ABCDE-2345"] {
            #expect(AppIdentity.teamPrefix(signedApplicationIdentifier: nil, infoDictionary: ["THEONOTES_TeamID": bad]) == "Q446J364FH", "\(bad)")
            #expect(AppIdentity.teamPrefix(signedApplicationIdentifier: bad + ".com.x", infoDictionary: ["THEONOTES_TeamID": publishing]) == publishing, "\(bad)")
        }
        #expect(AppIdentity.teamPrefix(signedApplicationIdentifier: "nodot", infoDictionary: nil) == "Q446J364FH")
        #expect(AppIdentity.teamPrefix(signedApplicationIdentifier: 42, infoDictionary: ["THEONOTES_TeamID": 7]) == "Q446J364FH")
    }

    @Test func theAppGroupFollowsTheTeam() {
        #expect(AppIdentity.production.appGroupIdentifier(team: publishing) == publishing + ".com.truebrewbirdie.notes")
        #expect(AppIdentity.dev.appGroupIdentifier(team: publishing) == publishing + ".com.truebrewbirdie.notes.dev")
    }

    @Test func theKeychainAccessGroupFollowsTheTeam() {
        #expect(AppIdentity.production.keychainAccessGroup(team: publishing) == publishing + ".com.truebrewbirdie.theonotes")
        #expect(AppIdentity.dev.keychainAccessGroup(team: publishing) == publishing + ".com.truebrewbirdie.theonotes.dev")
    }

    @Test func theProcessWideValuesUseTheResolvedTeam() {
        // In `swift test` nothing is signed and there is no app Info.plist, so the resolved team is today's.
        #expect(AppIdentity.teamPrefix == "Q446J364FH")
        for identity in AppIdentity.allCases {
            #expect(identity.appGroupIdentifier == identity.appGroupIdentifier(team: AppIdentity.teamPrefix))
            #expect(identity.keychainAccessGroup == identity.keychainAccessGroup(team: AppIdentity.teamPrefix))
        }
    }
}
