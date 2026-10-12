//
//  HelperToolManager.swift
//  Pearcleaner
//
//  Created by Alin Lupascu on 3/14/25.
//

import ServiceManagement
import Security
import AlinFoundation

extension Notification.Name {
    static let helperRequired = Notification.Name("helperRequired")
}

@objc(HelperToolProtocol)
public protocol HelperToolProtocol {
    func runCommand(command: String, withReply reply: @escaping (Bool, String) -> Void)
    func runThinning(atPath: String, withReply reply: @escaping (Bool, String) -> Void)
    func runBundleThinning(bundlePath: String, withReply reply: @escaping (Bool, String, [String: UInt64]) -> Void)
}

enum HelperToolAction {
    case none      // Only check status
    case install   // Install the helper tool
    case uninstall // Uninstall the helper tool
    case reinstall // Uninstall then reinstall (fixes desync)
}

/// Resumes a continuation at most once (XPC reply, XPC error handler and a timeout can all race)
private final class OneShotContinuation<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

/// Team identifier from this process's own code signature, or nil when ad-hoc signed or unsigned
private func teamIdentifierForSelf() -> String? {
    var code: SecCode?
    guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else { return nil }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let teamID = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String else { return nil }
    // Only a well-formed team ID may go into a requirement string (a malformed requirement raises an exception)
    guard teamID.count == 10, teamID.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else { return nil }
    return teamID
}

/// macOS 27 launchd no longer loads launchd plists that carry com.apple.quarantine (release note 166415497).
/// Clears the attribute from our own embedded plists and executables without privileges and ignores failures
/// (a root-owned bundle needs `xattr -dr com.apple.quarantine` by hand). Skipped under App Translocation (read-only mount).
@discardableResult
func stripOwnLaunchdQuarantine() -> Bool {
    let bundlePath = Bundle.main.bundlePath
    guard !bundlePath.contains("/AppTranslocation/") else { return false }
    let contentsPath = (bundlePath as NSString).appendingPathComponent("Contents")
    let relativePaths = [
        "Library/LaunchDaemons/com.alienator88.Pearcleaner.PearcleanerHelper.plist",
        "Library/LaunchAgents/com.alienator88.PearcleanerSentinel.plist",
        "MacOS/PearcleanerHelper",
        "MacOS/PearcleanerSentinel"
    ]
    var stripped = false
    for relativePath in relativePaths {
        let path = (contentsPath as NSString).appendingPathComponent(relativePath)
        if removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW) == 0 {
            stripped = true
        }
    }
    if stripped {
        printOS("Removed quarantine attribute from embedded launchd items")
    }
    return stripped
}

class HelperToolManager: ObservableObject {
    static let shared = HelperToolManager()
    private var helperConnection: NSXPCConnection?
    private var didAttemptAutoRecovery = false // one automatic reinstall per launch or per explicit install
    private let recoveryLock = NSLock()
    let helperToolIdentifier = "com.alienator88.Pearcleaner.PearcleanerHelper"

    /// Code signing requirement the helper must satisfy: our helper tool, signed by the same team as this app.
    /// The helper is a command-line tool without an Info.plist, so its signing identifier is "PearcleanerHelper", not its bundle id.
    /// nil when this app has no team identifier (ad-hoc signing); the helper is then never trusted.
    private static let helperRequirement: String? = {
        guard let teamID = teamIdentifierForSelf() else { return nil }
        return "identifier \"PearcleanerHelper\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
    }()
    @Published var isHelperToolInstalled: Bool = false
    @Published var message: String = String(localized: "Checking...")
    @Published var isInitialCheckComplete: Bool = false
    var status: String {
        return isHelperToolInstalled ? String(localized:"Enabled") : String(localized:"Disabled")
    }

    var shouldShowHelperBadge: Bool {
        return isInitialCheckComplete && !isHelperToolInstalled
    }

    // Trigger overlay when operation fails due to missing helper
    func triggerHelperRequiredAlert() {
        NotificationCenter.default.post(name: .helperRequired, object: nil)
    }

    init() {
        Task {
            await manageHelperTool()
        }
    }

    // Function to manage the helper tool installation/uninstallation
    // isAutoRecovery: reinstall triggered by a failed health check, never opens System Settings
    func manageHelperTool(action: HelperToolAction = .none, isAutoRecovery: Bool = false) async {
        let plistName = "\(helperToolIdentifier).plist"
        let service = SMAppService.daemon(plistName: plistName)
        var occurredError: NSError?

        // macOS 27 launchd refuses quarantined plists, clear ours before probing or registering
        if action != .uninstall {
            stripOwnLaunchdQuarantine()
        }

        // An explicit install by the user re-arms the single automatic recovery attempt
        if action == .install {
            setAutoRecoveryAttempted(false)
        }

        // Perform install/uninstall actions if specified
        switch action {
        case .install:
            // Pre-check before registering
            switch service.status {
            case .requiresApproval:
                updateOnMain {
                    self.message = String(localized: "Registered but requires enabling in System Settings > Login Items.")
                }
                SMAppService.openSystemSettingsLoginItems()
            case .enabled:
                // Verify the helper actually works (same desync check as .none action)
                let isRoot = await helperRespondsAsRoot()

                if !isRoot {
                    // Desync detected - helper claims enabled but doesn't work
                    printOS("Helper desync detected during install attempt, attempting auto-recovery...")

                    // Reinstall once, then report the helper as not responding
                    await recoverOrReportUnresponsive()
                    return // Exit early, recovery has published the status
                }

                // Helper verified working
                updateOnMain {
                    self.message = String(localized: "Service is already enabled.")
                }
            default:
                do {
                    try service.register()
                    if service.status == .requiresApproval {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                } catch let nsError as NSError {
                    occurredError = nsError
                    if nsError.code == 1 { // Operation not permitted
                        updateOnMain {
                            self.message = String(localized: "Permission required. Enable in System Settings > Login Items.")
                        }
                        SMAppService.openSystemSettingsLoginItems()
                    } else {
                        updateOnMain {
                            self.message = String(localized: "Installation failed: \(nsError.localizedDescription)")
                        }
                        printOS("Failed to register helper: \(nsError.localizedDescription)")
                    }

                }
            }

        case .uninstall:
            do {
                try await service.unregister()
                // Close any existing connection
                helperConnection?.invalidate()
                helperConnection = nil
            } catch let nsError as NSError {
                occurredError = nsError
                printOS("Failed to unregister helper: \(nsError.localizedDescription)")
            }

        case .reinstall:
            // Uninstall first
            do {
                try await service.unregister()
                helperConnection?.invalidate()
                helperConnection = nil
            } catch let nsError as NSError {
                printOS("Reinstall: Failed to unregister: \(nsError.localizedDescription)")
            }

            // Small delay to ensure launchd processes the unregister
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds

            // Then install
            do {
                try service.register()
                if service.status == .requiresApproval && !isAutoRecovery {
                    SMAppService.openSystemSettingsLoginItems()
                }
            } catch let nsError as NSError {
                occurredError = nsError
                printOS("Reinstall: Failed to register: \(nsError.localizedDescription)")
            }

        case .none:
            break
        }

        // nil means a recovery path already published the final status
        guard let isResponding = await updateStatusMessages(with: service, occurredError: occurredError) else { return }
        updateOnMain {
            self.isHelperToolInstalled = isResponding
            self.isInitialCheckComplete = true
        }
    }

    /// Asks the helper for `whoami` with a short timeout; true only when it answers as root
    /// Uses its own short-lived connection: XPC delivers messages in order, so a probe on the shared connection
    /// would queue behind a long running operation, and dropping that connection on timeout would kill the operation
    private func helperRespondsAsRoot() async -> Bool {
        let result: (Bool, String)
        if let connection = makeConnection() {
            connection.resume()
            result = await send("whoami", on: connection, timeout: 5)
            connection.invalidate()
        } else {
            result = (false, "XPC: Connection not available")
        }
        let isRoot = result.0 && result.1.trimmingCharacters(in: .whitespacesAndNewlines) == "root"
        if !isRoot {
            printOS("Helper health check failed: \(result.1)")
        }
        return isRoot
    }

    /// Reinstalls the helper at most once (per launch or per explicit install), then reports it as not responding
    /// instead of looping unregister/register forever
    private func recoverOrReportUnresponsive() async {
        // Check-and-set before any await, launch and didBecomeActive checks can race
        let alreadyAttempted = setAutoRecoveryAttempted(true)

        // A reinstall cannot help an ad-hoc build: we never connect to an unauthenticated helper
        guard !alreadyAttempted, Self.helperRequirement != nil else {
            markNotResponding()
            return
        }

        updateOnMain {
            self.message = String(localized: "Service desynced, attempting recovery...")
        }
        await manageHelperTool(action: .reinstall, isAutoRecovery: true)
    }

    /// Sets the auto-recovery flag and returns its previous value (synchronous so the lock is never held across an await)
    @discardableResult
    private func setAutoRecoveryAttempted(_ attempted: Bool) -> Bool {
        recoveryLock.lock()
        defer { recoveryLock.unlock() }
        let previous = didAttemptAutoRecovery
        didAttemptAutoRecovery = attempted
        return previous
    }

    /// Helper is registered but does not answer: stop retrying and tell the user what to do
    private func markNotResponding() {
        let reason: String
        if Self.helperRequirement == nil {
            reason = String(localized: "Helper is registered but this build has no signing team, so it will not be trusted. Sign Pearcleaner with an Apple Development or Developer ID certificate.")
        } else if #available(macOS 27, *) {
            reason = String(localized: "Helper is registered but not responding. On macOS 27 this is usually the quarantine attribute on the app: quit Pearcleaner, run xattr -dr com.apple.quarantine on Pearcleaner.app, relaunch and toggle the helper off and on. If it persists, use the Reset BTM button in the toolbar.")
        } else {
            reason = String(localized: "Helper is registered but not responding. Toggle the helper off and on. If it persists, use the Reset BTM button in the toolbar.")
        }
        printOS("Helper: \(reason)")
        updateOnMain {
            self.isHelperToolInstalled = false
            self.isInitialCheckComplete = true
            self.message = reason
        }
    }

    // Function to open Settings > Login Items
    func openSMSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // Function to run privileged commands
    func runCommand(_ command: String, skipHelperCheck: Bool = false) async -> (Bool, String) {
        if !skipHelperCheck && !isHelperToolInstalled {
            return (false, "XPC: Helper tool is not installed")
        }

        guard let connection = getConnection() else {
            return (false, "XPC: Connection not available")
        }

        return await send(command, on: connection)
    }

    /// Sends one command over the given connection. Reply, XPC error and the optional timeout race; the first one wins
    private func send(_ command: String, on connection: NSXPCConnection, timeout: TimeInterval? = nil) async -> (Bool, String) {
        return await withCheckedContinuation { continuation in
            let once = OneShotContinuation(continuation)

            if let timeout {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    once.resume(returning: (false, "XPC: Helper did not respond within \(Int(timeout)) seconds"))
                }
            }

            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                once.resume(returning: (false, "XPC: Connection error: \(error.localizedDescription)"))
            }) as? HelperToolProtocol else {
                once.resume(returning: (false, "XPC: Failed to get remote object"))
                return
            }

            proxy.runCommand(command: command, withReply: { success, output in
                once.resume(returning: (success, output))
            })
        }
    }

    // Function to run privileged thinning on apps owned by root
    func runThinning(atPath path: String) async -> (Bool, String) {
        guard let connection = getConnection() else {
            return (false, "XPC: No helper connection")
        }

        return await withCheckedContinuation { continuation in
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(returning: (false, "XPC: Error: \(error.localizedDescription)"))
            }) as? HelperToolProtocol else {
                continuation.resume(returning: (false, "XPC: Proxy failure"))
                return
            }

            proxy.runThinning(atPath: path) { success, output in
                continuation.resume(returning: (success, output))
            }
        }
    }
    
    // Function to run privileged bundle thinning on entire app bundles
    func runBundleThinning(bundlePath path: String) async -> (Bool, String, [String: UInt64]) {
        guard let connection = getConnection() else {
            return (false, "XPC: No helper connection", [:])
        }

        return await withCheckedContinuation { continuation in
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(returning: (false, "XPC: Error: \(error.localizedDescription)", [:]))
            }) as? HelperToolProtocol else {
                continuation.resume(returning: (false, "XPC: Proxy failure", [:]))
                return
            }

            proxy.runBundleThinning(bundlePath: path) { success, output, sizes in
                continuation.resume(returning: (success, output, sizes))
            }
        }
    }


    /// New, not yet resumed connection to the helper, pinned to our own helper's code signature
    private func makeConnection() -> NSXPCConnection? {
        // Never talk to a root helper we cannot authenticate (ad-hoc build without a team identifier)
        guard let requirement = Self.helperRequirement else {
            return nil
        }
        let connection = NSXPCConnection(machServiceName: helperToolIdentifier, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperToolProtocol.self)
        // Only our own helper, signed by the same team as this app, may answer
        connection.setCodeSigningRequirement(requirement)
        return connection
    }

    // Create/reuse XPC connection
    private func getConnection() -> NSXPCConnection? {
        if let connection = helperConnection {
            return connection
        }
        guard let connection = makeConnection() else {
            return nil
        }
        connection.invalidationHandler = { [weak self] in
            self?.helperConnection = nil
        }
        connection.resume()
        helperConnection = connection
        return connection
    }



    // Helper to update helper status messages
    // Returns whether the helper is usable, or nil when a recovery path already published the status
    func updateStatusMessages(with service: SMAppService, occurredError: NSError?) async -> Bool? {
        if let nsError = occurredError {
            switch nsError.code {
            case kSMErrorAlreadyRegistered:
                updateOnMain {
                    self.message = String(localized: "Service is already registered and enabled.")
                }
            case kSMErrorLaunchDeniedByUser:
                updateOnMain {
                    self.message = String(localized: "User denied permission. Enable in System Settings > Login Items.")
                }
            case kSMErrorInvalidSignature:
                updateOnMain {
                    self.message = String(localized: "Invalid signature, ensure proper signing on the application and helper tool.")
                }
            case 1:
                updateOnMain {
                    self.message = String(localized: "Authorization required in Settings > Login Items > \(Bundle.main.name).app.")
                }
            default:
                updateOnMain {
                    self.message = String(localized: "Operation failed: \(nsError.localizedDescription)")
                }
            }
            return service.status == .enabled
        } else {
            switch service.status {
            case .notRegistered:
                updateOnMain {
                    self.message = String(localized: "Service hasn't been registered. You may register it now.")
                }
            case .enabled:
                let isRoot = await helperRespondsAsRoot()

                if !isRoot {
                    // Desync detected - reinstall once, then report as not responding (no loop)
                    await recoverOrReportUnresponsive()

                    return nil // Exit early, recovery has published the status
                }

                updateOnMain {
                    self.message = String(localized: "Service successfully registered and eligible to run.")
                }
                return true
            case .requiresApproval:
                updateOnMain {
                    self.message = String(localized: "Service registered but requires user approval in Settings > Login Items > \(Bundle.main.name).app.")
                }
            case .notFound:
                updateOnMain {
                    self.message = String(localized: "Service is not installed.")
                }
            @unknown default:
                updateOnMain {
                    self.message = String(localized: "Unknown service status (\(service.status.rawValue)).")
                }
            }
            return false
        }
    }

    // MARK: - Nuclear Reset

    /// Nuclear reset: Reset BTM (Background Task Management) database to clear desynced helper registrations
    /// This is a last-resort fix for when SMAppService becomes desynced during development
    /// PREREQUISITE: User must manually disable helper in System Settings > Login Items first in certain cases
    /// Uses AlinFoundation's performPrivilegedCommands() which prompts for password
    func nuclearResetHelper() async -> Bool {
        printOS("Starting nuclear reset of helper tool...")

        updateOnMain {
            self.message = String(localized: "Resetting BTM database...")
        }

        // Execute sfltool resetbtm to clear Background Task Management database
        // NOTE: This only works if user has disabled the service in System Settings first
        let (success, output) = performPrivilegedCommands(commands: "sfltool resetbtm")

        if success {
            printOS("BTM reset succeeded")

            // Invalidate XPC connection
            helperConnection?.invalidate()
            helperConnection = nil

            updateOnMain {
                self.message = String(localized: "BTM reset complete. Please reinstall helper.")
                self.isHelperToolInstalled = false
            }

            return true
        } else {
            printOS("BTM reset failed: \(output)")
            updateOnMain {
                self.message = String(localized: "BTM reset failed: \(output)")
            }
            return false
        }
    }
}
