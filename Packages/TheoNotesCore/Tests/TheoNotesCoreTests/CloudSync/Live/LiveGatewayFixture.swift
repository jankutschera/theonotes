// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CloudKit
import Foundation
@testable import TheoNotesCore

/// A CloudKit record archive captured from the real service (live run 2026-10-30, Entity `e.note.arch`, change tag "3"). A change tag cannot
/// be forged locally, and the gateway's cache and `saved` outcomes need one, so the unit tests decode this.
enum LiveGatewayFixture {
    static let zoneName = "TheoNotesTest-94FC3617-525C-4134-9E19-C39592CC722A"
    static let archive = Data(base64Encoded: [
        "YnBsaXN0MDDUAQIDBAUGB2ZYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlct8QLwgJCgsMDQ4PEBESExQV",
        "FhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg3Ojc3OD43Nzc4ODc3NzhISTc3Nzc3Tzc3Nzg3N1Y3NzhaPjg3OF83YWI3ODdfEBZUb21ic3Rv",
        "bmVkUHVibGljS2V5SURzXxAZSGFzVXBkYXRlZFBhcmVudFJlZmVyZW5jZV8QE0NoYWluUHJvdGVjdGlvbkRhdGFdS25vd25Ub1NlcnZlcllCYXNlVG9rZW5f",
        "EBFEaXNwbGF5ZWRIb3N0bmFtZV8QEFdhbnRzQ2hhaW5QQ1NLZXlbUmVjb3JkQ3RpbWVaUm91dGluZ0tleV8QElByb3RlY3Rpb25EYXRhRXRhZ15FeHBpcmF0",
        "aW9uRGF0ZV8QGU1lcmdlYWJsZVZhbHVlRGVsdGFSZWNvcmRfEBpOZWVkc1JvbGxBbmRDb3VudGVyU2lnbktleV8QJlByZXZpb3VzUHJvdGVjdGlvbkRhdGFF",
        "dGFnRnJvbVVuaXRUZXN0XxASQ29uZmxpY3RMb3NlckV0YWdzXxAaUHJldmlvdXNQcm90ZWN0aW9uRGF0YUV0YWdfEBRIYXNVcGRhdGVkRXhwaXJhdGlvblpS",
        "ZWNvcmRUeXBlXxATQ3JlYXRvclVzZXJSZWNvcmRJRF8QD1BhcmVudFJlZmVyZW5jZVlTaGFyZUV0YWdYUENTS2V5SURcWm9uZWlzaEtleUlEXxAgTXV0YWJs",
        "ZUVuY3J5cHRlZFB1YmxpY1NoYXJpbmdLZXlURVRhZ18QFlByZXZpb3VzU2hhcmVSZWZlcmVuY2VfEBBNb2RpZmllZEJ5RGV2aWNlXlByb3RlY3Rpb25EYXRh",
        "XxARVXNlTGlnaHR3ZWlnaHRQQ1NeU2hhcmVSZWZlcmVuY2VfEBFVcGRhdGVkRXhwaXJhdGlvbl8QFW1vZGlmaWNhdGlvblRpbWVzdGFtcF8QFkNoYWluUGFy",
        "ZW50UHVibGljS2V5SURTVVJMV0V4cGlyZWRfEBhMYXN0TW9kaWZpZWRVc2VyUmVjb3JkSURbUmVjb3JkTXRpbWVfEBVXYW50c1B1YmxpY1NoYXJpbmdLZXlf",
        "EBZab25lUHJvdGVjdGlvbkRhdGFFdGFnWVdhc0NhY2hlZF8QEWNyZWF0aW9uVGltZXN0YW1wXxAPQ2hhaW5Qcml2YXRlS2V5WlBlcm1pc3Npb25YUmVjb3Jk",
        "SURcQWxsUENTS2V5SURzXxAYSGFzVXBkYXRlZFNoYXJlUmVmZXJlbmNlXxAXUHJldmlvdXNQYXJlbnRSZWZlcmVuY2WAAAiAAAmAAIAACIAWgACAAIAACAiA",
        "AIAAgAAIgAGAGIAAgACAAIAAgACAHoAAgACAAAiAAIAAgBKAAIAACIAcgBYIgAAIgAmAABABgAKAAAiAAK8QH2doaXBxe3x9g4aMkJSYnJ2gpKissLO2ur3B",
        "wsfIzM1VJG51bGxWRW50aXR502prbG1ub1YkY2xhc3NaUmVjb3JkTmFtZVZab25lSUSACIADgARbZS5ub3RlLmFyY2jVcnN0dWp2N3h5el8QEGRhdGFiYXNl",
        "U2NvcGVLZXlfEBFhbm9ueW1vdXNDS1VzZXJJRFlvd25lck5hbWVYWm9uZU5hbWUQAIAAgAaABYAHXxAyVGhlb05vdGVzVGVzdC05NEZDMzYxNy01MjVDLTQx",
        "MzQtOUUxOS1DMzk1OTJDQzcyMkFfEBBfX2RlZmF1bHRPd25lcl9f0n5/gIFaJGNsYXNzbmFtZVgkY2xhc3Nlc15DS1JlY29yZFpvbmVJRKKAglhOU09iamVj",
        "dNJ+f4SFWkNLUmVjb3JkSUSihILTaoeIiYqLVHRpbWVWZG9tYWlugBGADIAK0mqNjm9ccmVjb3JkWm9uZUlEgAuABNJ+f5GSXxAhQ0tTZXJ2ZXJUaW1lc3Rh",
        "bXBSZWNvcmRab25lRG9tYWluopOCXxAhQ0tTZXJ2ZXJUaW1lc3RhbXBSZWNvcmRab25lRG9tYWlu0pVqlpdXdmVyc2lvboANgBDSapmam1l0aW1lc3RhbXCA",
        "D4AOEAPSfn+en1lDS1ZlcnNpb26inoLSfn+hol8QFUNLU2VydmVyVGltZXN0YW1wVGltZaKjgl8QFUNLU2VydmVyVGltZXN0YW1wVGltZdJ+f6WmXxARQ0tT",
        "ZXJ2ZXJUaW1lc3RhbXCip4JfEBFDS1NlcnZlclRpbWVzdGFtcNNqh4iJqquAEYAUgBPSaq2Ob1xyZWNvcmRab25lSUSAC4AE0pVqsZeAFYAQ0mqZmpuAD4AO",
        "0rdquLlXTlMudGltZSNByEpVwPTdL4AX0n5/u7xWTlNEYXRloruC02prbG2/wIAIgBmAGl8QEF9fZGVmYXVsdE93bmVyX1/VcnN0dWp2N3jFeoAAgAaAG4AH",
        "XF9kZWZhdWx0Wm9uZdNqa2xtysCACIAdgBpfEBBfX2RlZmF1bHRPd25lcl9fUTMACAARABoAJAApADIANwBJAKoAwwDfAPUBAwENASEBNAFAAUsBYAFvAYsB",
        "qAHRAeYCAwIaAiUCOwJNAlcCYAJtApAClQKuAsEC0ALkAvMDBwMfAzgDPANEA18DawODA5wDpgO6A8wD1wPgA+0ECAQiBCQEJQQnBCgEKgQsBC0ELwQxBDME",
        "NQQ2BDcEOQQ7BD0EPgRABEIERARGBEgESgRMBE4EUARSBFQEVQRXBFkEWwRdBF8EYARiBGQEZQRnBGgEagRsBG4EcARyBHMEdQSXBJ0EpASrBLIEvQTEBMYE",
        "yATKBNYE4QT0BQgFEgUbBR0FHwUhBSMFJQVaBW0FcgV9BYYFlQWYBaEFpgWxBbQFuwXABccFyQXLBc0F0gXfBeEF4wXoBgwGDwYzBjgGQAZCBkQGSQZTBlUG",
        "VwZZBl4GaAZrBnAGiAaLBqMGqAa8Br8G0wbaBtwG3gbgBuUG8gb0BvYG+wb9Bv8HBAcGBwgHDQcVBx4HIAclBywHLwc2BzgHOgc8B08HWgdcB14HYAdiB28H",
        "dgd4B3oHfAePAAAAAAAAAgEAAAAAAAAAzgAAAAAAAAAAAAAAAAAAB5E="
    ].joined())!

    static var configuration: CloudKitConfiguration { CloudKitConfiguration(containerIdentifier: "iCloud.example.test", zoneName: zoneName) }

    /// A server record of the fixture's name with change tag "3".
    static func record() throws -> CKRecord { try CloudRecordMapping.record(fromArchive: archive) }
    static var recordID: CKRecord.ID { try! record().recordID }
}
