//
//  CodesignCheck.swift
//
//  Created by Erik Berglund on 2018-10-01.
//  Copyright © 2018 Erik Berglund. All rights reserved.
//

import Foundation
import Security

let kSecCSDefaultFlags = 0

enum CodesignCheckError: Error {
    case message(String)
}

struct CodesignCheck {

    // MARK: - Compare Functions

    public static func codeSigningMatches(pid: pid_t) throws -> Bool {
        let selfCertificates = try self.codeSigningCertificatesForSelf()
        // Ad-hoc or unsigned helper: [] == [] would accept any ad-hoc process, so trust nobody
        guard !selfCertificates.isEmpty else { return false }
        return try selfCertificates == self.codeSigningCertificates(forPID: pid)
    }

    // MARK: - Client Requirement

    /// Requirement every client must satisfy: the Pearcleaner app, signed by the same team as this helper.
    /// The team is read from the helper's own signature, so a personal build pins its own team.
    /// nil when the helper has no team identifier (ad-hoc build): then no client is accepted.
    public static let clientRequirement: String? = {
        guard let teamID = teamIdentifierForSelf() else { return nil }
        return "anchor apple generic and identifier \"com.alienator88.Pearcleaner\" and certificate leaf[subject.OU] = \"\(teamID)\""
    }()

    /// Team identifier from the helper's own code signature, or nil when ad-hoc signed or unsigned
    public static func teamIdentifierForSelf() -> String? {
        guard let secStaticCode = try? secStaticCodeSelf(),
              let info = try? secCodeInfo(forStaticCode: secStaticCode),
              let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String else { return nil }
        // Only a well-formed team ID may go into a requirement string (a malformed requirement raises an exception)
        guard teamID.count == 10, teamID.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else { return nil }
        return teamID
    }

    // MARK: - Public Functions

    public static func codeSigningCertificatesForSelf() throws -> [SecCertificate] {
        guard let secStaticCode = try secStaticCodeSelf() else { return [] }
        return try codeSigningCertificates(forStaticCode: secStaticCode)
    }

    public static func codeSigningCertificates(forPID pid: pid_t) throws -> [SecCertificate] {
        guard let secStaticCode = try secStaticCode(forPID: pid) else { return [] }
        return try codeSigningCertificates(forStaticCode: secStaticCode)
    }

    public static func codeSigningCertificates(forURL url: URL) throws -> [SecCertificate] {
        guard let secStaticCode = try secStaticCode(forURL: url) else { return [] }
        return try codeSigningCertificates(forStaticCode: secStaticCode)
    }

    // MARK: - Private Functions

    private static func executeSecFunction(_ secFunction: () -> (OSStatus) ) throws {
        let osStatus = secFunction()
        guard osStatus == errSecSuccess else {
            throw CodesignCheckError.message(String(describing: SecCopyErrorMessageString(osStatus, nil)))
        }
    }

    private static func secStaticCodeSelf() throws -> SecStaticCode? {
        var secCodeSelf: SecCode?
        try executeSecFunction { SecCodeCopySelf(SecCSFlags(rawValue: 0), &secCodeSelf) }
        guard let secCode = secCodeSelf else {
            throw CodesignCheckError.message("SecCode returned empty from SecCodeCopySelf")
        }
        return try secStaticCode(forSecCode: secCode)
    }

    private static func secStaticCode(forPID pid: pid_t) throws -> SecStaticCode? {
        var secCodePID: SecCode?
        try executeSecFunction { SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &secCodePID) }
        guard let secCode = secCodePID else {
            throw CodesignCheckError.message("SecCode returned empty from SecCodeCopyGuestWithAttributes")
        }
        return try secStaticCode(forSecCode: secCode)
    }

    private static func secStaticCode(forURL url: URL) throws -> SecStaticCode? {
        var secStaticCodePath: SecStaticCode?
        try executeSecFunction { SecStaticCodeCreateWithPath(url as CFURL, [], &secStaticCodePath) }
        guard let secStaticCode = secStaticCodePath else {
            throw CodesignCheckError.message("SecStaticCode returned empty from SecStaticCodeCreateWithPath")
        }
        return secStaticCode
    }

    private static func secStaticCode(forSecCode secCode: SecCode) throws -> SecStaticCode? {
        var secStaticCodeCopy: SecStaticCode?
        try executeSecFunction { SecCodeCopyStaticCode(secCode, [], &secStaticCodeCopy) }
        guard let secStaticCode = secStaticCodeCopy else {
            throw CodesignCheckError.message("SecStaticCode returned empty from SecCodeCopyStaticCode")
        }
        return secStaticCode
    }

    private static func isValid(secStaticCode: SecStaticCode) throws {
        try executeSecFunction { SecStaticCodeCheckValidity(secStaticCode, SecCSFlags(rawValue: kSecCSDoNotValidateResources | kSecCSCheckNestedCode), nil) }
    }

    private static func secCodeInfo(forStaticCode secStaticCode: SecStaticCode) throws -> [String: Any]? {
        try isValid(secStaticCode: secStaticCode)
        var secCodeInfoCFDict:  CFDictionary?
        try executeSecFunction { SecCodeCopySigningInformation(secStaticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &secCodeInfoCFDict) }
        guard let secCodeInfo = secCodeInfoCFDict as? [String: Any] else {
            throw CodesignCheckError.message("CFDictionary returned empty from SecCodeCopySigningInformation")
        }
        return secCodeInfo
    }

    private static func codeSigningCertificates(forStaticCode secStaticCode: SecStaticCode) throws -> [SecCertificate] {
        guard
            let secCodeInfo = try secCodeInfo(forStaticCode: secStaticCode),
            let secCertificates = secCodeInfo[kSecCodeInfoCertificates as String] as? [SecCertificate] else { return [] }
        return secCertificates
    }
}
