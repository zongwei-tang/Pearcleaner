//
//  UndoManager.swift
//  Pearcleaner
//
//  Created by Alin Lupascu on 2/24/25.
//

import Foundation
import SwiftUI
import AlinFoundation

class FileManagerUndo {
    // MARK: - Singleton Instance
    static let shared = FileManagerUndo()

    // Private initializer to enforce singleton pattern
    private init() {}

    // NSUndoManager instance to handle undo/redo actions
    let undoManager = UndoManager()

    /// Set on the main thread together with AppState.trashError: true when macOS refused access to some items
    private(set) var lastErrorNeedsFullDiskAccess = false

    // MARK: - Path Validation
    /// Validates that a path is safe to delete (not a critical system path or app folder)
    private func validatePath(_ path: String) -> Bool {
        // Normalize path
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path

        // Block empty paths
        guard !normalizedPath.trimmingCharacters(in: .whitespaces).isEmpty else {
            printOS("⚠️ Blocked deletion: Empty path")
            return false
        }

        // Combine critical system paths + user app folder paths into single set
        let criticalSystemPaths = [
            "/",
            "/Applications",
            "/Library",
            "/System",
            "/usr",
            "/bin",
            "/sbin",
            "/etc",
            "/var",
            "/private",
            "/opt",
            NSHomeDirectory()
        ]

        let userAppPaths = FolderSettingsManager.shared.folderPaths
        let blockedPaths = Set(criticalSystemPaths + userAppPaths)

        // Block if path exactly matches any blocked path
        if blockedPaths.contains(normalizedPath) {
            printOS("⚠️ Blocked deletion: Protected path '\(normalizedPath)'")
            return false
        }

        return true
    }

    func deleteFiles(at urls: [URL], isCLI: Bool = false, bundleName: String? = nil) -> Bool {
        // Filter out invalid/dangerous paths before deletion
        let validURLs = urls.filter { validatePath($0.path) }

        // If no valid paths remain, return early
        guard !validURLs.isEmpty else {
            printOS("⚠️ All paths were blocked - no files deleted")
            return false
        }

        // Log if any paths were filtered out
        if validURLs.count < urls.count {
            printOS("⚠️ Filtered out \(urls.count - validURLs.count) dangerous path(s)")
        }
        let trashPath = (NSHomeDirectory() as NSString).appendingPathComponent(".Trash")
        let dispatchSemaphore = DispatchSemaphore(value: 0)  // Semaphore to make it synchronous
        var finalStatus = false  // Store the final success/failure status

        var tempFilePairs: [(trashURL: URL, originalURL: URL)] = []
        var seenFileNames: [String: Int] = [:]

        // Moving an item also needs write access to the folder it is in
        let hasProtectedFiles = validURLs.contains { $0.isProtected || $0.deletingLastPathComponent().isProtected }

        // Create bundle folder name with app name and timestamp
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = dateFormatter.string(from: Date())

        let folderName: String
        if let customBundleName = bundleName {
            folderName = customBundleName
        } else if !AppState.shared.appInfo.appName.isEmpty {
            folderName = AppState.shared.appInfo.appName
        } else {
            // Fallback for plugins: use the first file's name or "Mixed Files"
            if let firstFile = validURLs.first {
                folderName = firstFile.deletingPathExtension().lastPathComponent
            } else {
                folderName = "Mixed Files"
            }
        }

        let bundleFolderName = "\(folderName)_\(timestamp)"
        let bundleFolderPath = (trashPath as NSString).appendingPathComponent(bundleFolderName)
        let bundleFolderURL = URL(fileURLWithPath: bundleFolderPath)

        // Create the bundle folder first
        let createFolderCommand = "/bin/mkdir -p \(bundleFolderPath.shellQuoted)"

        let mvCommands = validURLs.map { file -> String in
            let baseName = file.lastPathComponent
            var count = seenFileNames[baseName] ?? 0
            var finalName = baseName

            // Check for duplicate names within the bundle folder
            repeat {
                if count > 0 {
                    finalName = "\(baseName)-\(count)"
                }
                count += 1
            } while FileManager.default.fileExists(atPath: (bundleFolderPath as NSString).appendingPathComponent(finalName))

            seenFileNames[baseName] = count

            let destinationURL = bundleFolderURL.appendingPathComponent(finalName)
            tempFilePairs.append((trashURL: destinationURL, originalURL: file))

            return "/bin/mv \(file.path.shellQuoted) \(destinationURL.path.shellQuoted)"
        }

        let filePairs = tempFilePairs

        // Create the bundle folder as the user, so moves retried without privileges can still land in it
        try? FileManager.default.createDirectory(atPath: bundleFolderPath, withIntermediateDirectories: true)

        let outcome = executeFileCommands(mvCommands, before: createFolderCommand, isCLI: isCLI, hasProtectedFiles: hasProtectedFiles)

        // Only the moves that really happened can be undone
        let movedPairs = filePairs.indices.filter { !outcome.failed.contains($0) }.map { filePairs[$0] }

        if !movedPairs.isEmpty {
            undoManager.registerUndo(withTarget: self) { target in
                let result = target.restoreFiles(filePairs: movedPairs)
                if !result {
                    printOS("Trash Error: Could not restore files.")
                }
            }
            undoManager.setActionName("Delete File")

            // Record in persistent history
            Task { @MainActor in
                UndoHistoryManager.shared.addRecord(
                    appName: folderName,
                    bundleFolderPath: bundleFolderPath,
                    filePairs: movedPairs.map { ($0.originalURL.path, $0.trashURL.path) }
                )
            }

            // Play trash sound after successful deletion
            if !isCLI {
                playTrashSound()
            }
        } else {
            // Nothing was moved: do not leave an empty bundle folder in the Trash (rmdir only removes empty folders)
            rmdir(bundleFolderPath)
        }

        // A source that no longer exists (e.g. removed by the app itself while quitting) is gone, not a failure; it has nothing to undo.
        // attributesOfItem does not follow symlinks, and a TCC denial reports no permission, so those stay failures
        let vanishedIndexes: Set<Int> = outcome.cancelled ? [] : outcome.failed.filter { index in
            do {
                _ = try FileManager.default.attributesOfItem(atPath: filePairs[index].originalURL.path)
                return false
            } catch let error as CocoaError {
                return error.code == .fileReadNoSuchFile
            } catch {
                return false
            }
        }
        for index in vanishedIndexes.sorted() {
            printOS("Trash: already gone, skipped: \(filePairs[index].originalURL.path)")
        }
        let failedIndexes = outcome.failed.subtracting(vanishedIndexes)

        if failedIndexes.isEmpty {
            finalStatus = true
        } else {
            reportFailure(outcome, notMoved: failedIndexes.sorted().map { filePairs[$0].originalURL.path }, isRestore: false)
            finalStatus = false
        }

        dispatchSemaphore.signal()

        dispatchSemaphore.wait()
        return finalStatus
    }

    func restoreFiles(filePairs: [(trashURL: URL, originalURL: URL)], isCLI: Bool = false) -> Bool {
        let dispatchSemaphore = DispatchSemaphore(value: 0)
        var finalStatus = true

        let hasProtectedFiles = filePairs.contains {
            $0.originalURL.deletingLastPathComponent().isProtected || $0.trashURL.isProtected
        }

        let commands = filePairs.map {
            "/bin/mv \($0.trashURL.path.shellQuoted) \($0.originalURL.path.shellQuoted)"
        }

        // Determine the bundle folder to clean up after restore
        var bundleFolderToRemove: String? = nil
        if let firstFilePair = filePairs.first {
            let bundleFolder = firstFilePair.trashURL.deletingLastPathComponent()
            // Only remove if it looks like our generated bundle folder (contains underscore for timestamp)
            if bundleFolder.lastPathComponent.contains("_") {
                bundleFolderToRemove = bundleFolder.path
            }
        }

        // Add bundle folder cleanup command if we have one to remove (it only succeeds once the folder is empty)
        let cleanupCommand = bundleFolderToRemove.map { "/bin/rmdir \($0.shellQuoted)" }

        let outcome = executeFileCommands(commands, after: cleanupCommand, isCLI: isCLI, hasProtectedFiles: hasProtectedFiles, isRestore: true)

        if outcome.failed.isEmpty {
            // Remove from persistent history after successful restore
            if let bundleFolder = bundleFolderToRemove {
                Task { @MainActor in
                    UndoHistoryManager.shared.removeRecord(bundleFolderPath: bundleFolder)
                }
            }

            finalStatus = true
        } else {
            // Keep the items that were not restored in history, so they can still be restored later
            if let bundleFolder = bundleFolderToRemove, outcome.failed.count < filePairs.count {
                let remainingPairs = outcome.failed.sorted().map { (filePairs[$0].originalURL.path, filePairs[$0].trashURL.path) }
                Task { @MainActor in
                    UndoHistoryManager.shared.updateRecord(bundleFolderPath: bundleFolder, filePairs: remainingPairs)
                }
            }
            reportFailure(outcome, notMoved: outcome.failed.sorted().map { filePairs[$0].trashURL.path }, isRestore: true)
            finalStatus = false
        }

        dispatchSemaphore.signal()
        dispatchSemaphore.wait()
        return finalStatus
    }

    /// Outcome of a batch of moves: the indexes of the moves that did not happen, and whether the user cancelled the password prompt
    private struct FileCommandsResult {
        var failed: Set<Int> = []
        var cancelled = false
        var output = ""
    }

    // Helper function to perform shell commands based on available privileges
    // Each move reports its own failure in the output, since a " ; " chain only returns the status of its last command.
    // Every chain exits 0 once it ran, so runSUCommand never re-runs half-done moves through the password prompt.
    private func executeFileCommands(_ moves: [String], before: String? = nil, after: String? = nil, isCLI: Bool, hasProtectedFiles: Bool, isRestore: Bool = false) -> FileCommandsResult {
        guard !moves.isEmpty else { return FileCommandsResult() }

        let token = UUID().uuidString
        let failMarker = "PCFAIL-\(token):"
        let doneMarker = "PCDONE-\(token)"
        func script(for indexes: [Int]) -> String {
            var parts = before.map { ["\($0) 2>&1"] } ?? []
            parts += indexes.map { "\(moves[$0]) 2>&1 || echo \(failMarker)\($0)" }
            if let after = after {
                parts.append("\(after) 2>/dev/null || true")
            }
            parts.append("echo \(doneMarker)")
            return parts.joined(separator: " ; ")
        }
        func failures(in output: String, for indexes: [Int]) -> Set<Int> {
            let lines = output.split(whereSeparator: \.isNewline)
            // Without the completion marker the script did not run to the end, so none of its moves count as done
            guard lines.contains(where: { $0 == doneMarker }) else { return Set(indexes) }
            return Set(lines.compactMap { line in
                line.hasPrefix(failMarker) ? Int(line.dropFirst(failMarker.count)) : nil
            })
        }

        var result = FileCommandsResult()
        let allIndexes = Array(moves.indices)

        if hasProtectedFiles {
            // Authorize before touching anything, so a cancelled password prompt leaves every file in place
            let privileged = runPrivilegedCommand(script(for: allIndexes), isRestore: isRestore)
            result.output = privileged.output

            if isAuthorizationRefused(privileged.output) {
                result.failed = Set(allIndexes)
                result.cancelled = true
                return result
            }

            guard privileged.success else {
                // Never fall back after a cancel. The CLI may have no GUI session for the prompt, but works directly when run as root
                if isCLI {
                    let direct = runDirectShellCommand(command: script(for: allIndexes))
                    result.output += "\n" + direct.1
                    result.failed = failures(in: direct.1, for: allIndexes)
                } else {
                    result.failed = Set(allIndexes)
                }
                return result
            }

            result.failed = failures(in: privileged.output, for: allIndexes)

            // macOS can deny the helper access to other apps' data while this app is allowed (Full Disk Access): retry those here
            if !result.failed.isEmpty && isPermissionError(privileged.output) {
                let retryIndexes = result.failed.sorted()
                let direct = runDirectShellCommand(command: script(for: retryIndexes))
                result.output += "\n" + direct.1
                result.failed.formIntersection(failures(in: direct.1, for: retryIndexes))
            }
        } else {
            // Everything is writable by the user: move without privileges, and escalate only the moves refused for lack of permission
            let direct = runDirectShellCommand(command: script(for: allIndexes))
            result.output = direct.1
            result.failed = failures(in: direct.1, for: allIndexes)

            if !result.failed.isEmpty && isPermissionError(direct.1) {
                let retryIndexes = result.failed.sorted()
                let privileged = runPrivilegedCommand(script(for: retryIndexes), isRestore: isRestore)
                result.output += "\n" + privileged.output
                if privileged.success {
                    result.failed.formIntersection(failures(in: privileged.output, for: retryIndexes))
                } else {
                    result.cancelled = isAuthorizationRefused(privileged.output)
                }
            }
        }

        return result
    }

    // Runs commands through the helper tool or Authorization Services (password prompt) and waits for the result
    private func runPrivilegedCommand(_ command: String, isRestore: Bool) -> (success: Bool, output: String) {
        let semaphore = DispatchSemaphore(value: 0)
        var result: (success: Bool, output: String) = (false, "")

        Task {
            result = try! await runSUCommand(
                command,
                errorContext: isRestore ? "Undo restore operation failed" : "Undo delete operation failed",
                throwOnFailure: false
            )
            semaphore.signal()
        }
        semaphore.wait()

        return result
    }

    // Logs the items that were not moved and raises the trash error banner, unless the user cancelled the password prompt
    private func reportFailure(_ result: FileCommandsResult, notMoved paths: [String], isRestore: Bool) {
        let label = isRestore ? "Restore Error" : "Trash Error"
        if result.cancelled {
            printOS(isRestore ? "Restore cancelled at the authorization prompt" : "Deletion cancelled at the authorization prompt")
        } else {
            printOS("\(label): \(result.output)")
        }
        for path in paths {
            printOS("\(label): not moved: \(path)")
        }
        guard !result.cancelled else { return }

        // macOS 27 denies access to other apps' data containers without asking; Full Disk Access allows it
        var needsFullDiskAccess = false
        if #available(macOS 27, *) {
            needsFullDiskAccess = result.output.lowercased().contains("operation not permitted")
        }
        if needsFullDiskAccess {
            printOS("\(label): macOS blocked access to some items. Grant Pearcleaner Full Disk Access in System Settings > Privacy & Security > Full Disk Access, then try again.")
        }

        updateOnMain {
            self.lastErrorNeedsFullDiskAccess = needsFullDiskAccess
            AppState.shared.trashError = true
        }
    }

    private func isPermissionError(_ output: String) -> Bool {
        let lowercased = output.lowercased()
        return lowercased.contains("permission denied") || lowercased.contains("operation not permitted")
    }

    // Helper to run direct non-privileged shell commands
    private func runDirectShellCommand(command: String) -> (Bool, String) {
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", command]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        task.launch()

        // Read before waiting: a full pipe would otherwise block the shell and this wait forever
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        let output = String(data: data, encoding: .utf8) ?? ""

        if isPermissionError(output) {
            return (false, output)
        }

        return (task.terminationStatus == 0, output)
    }

}

extension URL {
    var isProtected: Bool {
        !FileManager.default.isWritableFile(atPath: self.path)
    }
}
