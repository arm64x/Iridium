//
//  AgentWrapper.swift
//  iridium
//
//  Created by Lakr Aream on 2022/1/7.
//

import AppListProto
import AuxiliaryExecute
import Foundation
import MachO
import PropertyWrapper
import SPIndicator
import UIKit
import ZipArchive

private let binaryName = "AuxiliaryAgent"

class Agent {
    var binaryLocation: URL!

    var foulTFP0: URL {
        Bundle.main.bundleURL.appendingPathComponent("fouldecrypt.tfp0")
    }

    var foulKRW: URL {
        Bundle.main.bundleURL.appendingPathComponent("fouldecrypt.krw")
    }

    var foulKERNRW: URL {
        Bundle.main.bundleURL.appendingPathComponent("fouldecrypt.kernrw")
    }

    enum FoulOption: String {
        case tfp0
        case krw
        case kernrw
        case unspecified
    }

    @UserDefaultsWrapper(key: "wiki.qaq.iridium", defaultValue: "unspecified")
    var _foulOptionStore: String

    var foulOption: FoulOption {
        get {
            FoulOption(rawValue: _foulOptionStore) ?? .unspecified
        }
        set {
            _foulOptionStore = newValue.rawValue
            debugPrint("setting new backend \(_foulOptionStore)")
        }
    }

    static let shared = Agent()
    private init() {
        binaryLocation = nil
        defer {
            if let binary = binaryLocation {
                debugPrint("found binary at \(binary)")
            } else {
                #if DEBUG
                    debugPrint("binary for auxiliary agent was not found, ignored due to debug build")
                    binaryLocation = URL(fileURLWithPath: "/\(UUID().uuidString)")
                #else
                    fatalError("could not find auxiliary agent on system")
                #endif
            }
        }
        debugPrint("building binary location")
        repeat {
            let bundleAgent = Bundle
                .main
                .url(forAuxiliaryExecutable: binaryName)
            if let bundle = bundleAgent {
                binaryLocation = bundle
                break
            }

            let binarySearchPath = [
                "/usr/libexec",
                "/usr/local/bin",
                "/usr/bin",
                "/bin",
                "/var/jb/Applications",
                "/var/jb/bin"
            ]
            var binaryLookupTable = [String: URL]()
            for path in binarySearchPath {
                if let items = try? FileManager
                    .default
                    .contentsOfDirectory(atPath: path)
                {
                    for item in items {
                        let url = URL(fileURLWithPath: path)
                            .appendingPathComponent(item)
                        binaryLookupTable[item] = url
                    }
                }
            }
            if let location = binaryLookupTable[binaryName] {
                binaryLocation = location
                break
            }

        } while false
    }

    public func agentPermissionValidate() -> Bool {
        guard let binaryLocation = binaryLocation else {
            return false
        }
        let recipe = AuxiliaryExecute.spawn(
            command: binaryLocation.path,
            args: ["exec", "whoami"],
            timeout: 60
        )
        return recipe
            .stdout
            .trimmingCharacters(in: .whitespacesAndNewlines) == "root"
    }

    public func generateAppList() -> [AppListElement] {
        guard let binaryLocation = binaryLocation else {
            return []
        }
        let recipe = AuxiliaryExecute.spawn(
            command: binaryLocation.path,
            args: ["list"],
            timeout: 60
        )
        var result = [AppListElement]()
        if let apps = AppListTransfer.decode(jsonString: recipe.stdout) {
            result = apps.applications
        }
        return result
            .filter { !$0.bundleIdentifier.hasPrefix("com.apple.") }
            .sorted { $0.localizedName < $1.localizedName }
    }

    public func decryptApplication(with app: AppListElement, output: @escaping (String) -> Void) -> URL? {
        #if DEBUG
            if Thread.isMainThread {
                fatalError(
                    """
                    this function should not be called from main thread
                    because we are asking for user interaction later if failure occurred
                    """
                )
            }
        #endif

        var possibleFailure = false
        var wasInterrupted = false

        let originalBundleLocation = app.bundleURL
        output("TARGET:\n\(originalBundleLocation.path)\n")
        guard let binaryLocation = binaryLocation else {
            output("\n\nAuxiliary Binary Not Found\n\n")
            return nil
        }
        defer {
            if !wasInterrupted {
                output("\n\n")
                output(
                    """
                    Resign and install may still need additional patch to package payload. You are on your own making those patches.
                    """
                )
                output("\n\n")
                if possibleFailure {
                    output("\n\n==========\n\n")
                    output("Invalid recipe was detected from backend!\n")
                    output("Use this package with caution!\n")
                    output("\n\n==========\n\n")
                }
            }
            output("\n\n[Process Completed]\n\n")
        }

        // MARK: - STEP 1 - Make a copy of the bundle container

        let zipContainer = documentsDirectory
            .appendingPathComponent("Temporary")
            .appendingPathComponent(UUID().uuidString)
        let processBundleContainer = zipContainer
            .appendingPathComponent("Payload")
        let processBundleLocation = processBundleContainer
            .appendingPathComponent(originalBundleLocation.lastPathComponent)
        try? FileManager.default.createDirectory(
            at: processBundleContainer,
            withIntermediateDirectories: true,
            attributes: nil
        )
        defer {
            output("\n[*] Cleaning temporary directory...\n")
            let recipe = AuxiliaryExecute.spawn(
                command: binaryLocation.path,
                args: ["delete", zipContainer.path],
                timeout: 60
            )
            output(recipe.stdout)
            output(recipe.stderr)
        }
        repeat {
            let recipe = AuxiliaryExecute.spawn(
                command: binaryLocation.path,
                args: ["copy", originalBundleLocation.path, processBundleLocation.path],
                timeout: 60
            )
            output(recipe.stdout)
            output(recipe.stderr)
        } while false

        // MARK: - STEP 2 - Enumerate entire app bundle to find all mach objects

        output("\nSearching for mach objects...\n")

        var binaries = [(URL, URL)]() // the orig binary is at .0 and we decrypt it to .1
        repeat {
            let enumerator = FileManager
                .default
                .enumerator(atPath: processBundleLocation.path)
            repeat {
                guard let objectPath = enumerator?
                    .nextObject() as? String
                else {
                    // nothing left from the enumerator
                    break
                }
                // data might be large
                autoreleasepool {
                    let currentObjectFullPath = processBundleLocation
                        .appendingPathComponent(objectPath)
                    guard let data = try? Data(contentsOf: currentObjectFullPath) else {
                        return
                    }
                    let magic = data.magic
                    if magic == MH_MAGIC_64 || magic == FAT_MAGIC_64 {
                        output("[*] \(objectPath)\n")
                        binaries.append(
                            (
                                originalBundleLocation.appendingPathComponent(objectPath),
                                currentObjectFullPath
                            )
                        )
                    }
                }
            } while true
        } while false

        // MARK: - STEP 3 - Decide which fouldecrypt should be used

        let foulBinary = foulOptionToUrl(with: foulOption)
        output("\n\n[*] Selecting backend \(foulBinary.path)\n\n")
        for (origBinary, destBinary) in binaries {
            output("\n[*] Calling decryption on \(origBinary.lastPathComponent)\n")
            let recipe = AuxiliaryExecute.spawn(
                command: binaryLocation.path,
                args: [
                    "exec",
                    foulBinary.path,
                    "-v",
                    origBinary.path,
                    destBinary.path,
                ],
                timeout: 60
            )
            // no longer output them, too noising on normal return
            output("\n[*] Recipe: \(recipe.exitCode)\n")
            if recipe.exitCode != 0 || recipe.error != nil {
                possibleFailure = true
                if let error = recipe.error {
                    output("\n[*] AuxiliaryExecute Error: \(error.localizedDescription)")
                }
                output("\n[*] stdout\n")
                output(recipe.stdout)
                output("\n[*] stderr\n")
                output(recipe.stderr)
            }
        }

        // MARK: - STEP 3.5 - Fail if ever recipe none 0 but ask for that

        if possibleFailure {
            var shouldExit = true
            let sem = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                let alert = UIAlertController(title: "⚠️", message: "Error occurred during decryption", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Ignore", style: .destructive, handler: { _ in
                    shouldExit = false
                    sem.signal()
                }))
                alert.addAction(UIAlertAction(title: "Exit", style: .cancel, handler: { _ in
                    shouldExit = true
                    sem.signal()
                }))
                guard let controller = UIApplication
                    .shared
                    .windows
                    .first?
                    .topMostViewController
                else {
                    shouldExit = false
                    sem.signal()
                    return
                }
                controller.present(alert, animated: true, completion: nil)
            }
            sem.wait()
            if shouldExit {
                output("\n\n[*] Package process interrupted\n")
                wasInterrupted = true
                return nil
            }
        }

        // MARK: - STEP 4 - Create installer file

        let fileName = "\(app.localizedName).\(app.bundleIdentifier).(\(app.shortVersion)).ipa"
        var invalidCharacters = CharacterSet(charactersIn: ":/")
        invalidCharacters.formUnion(.newlines)
        invalidCharacters.formUnion(.illegalCharacters)
        invalidCharacters.formUnion(.controlCharacters)
        let newFilename = fileName
            .components(separatedBy: invalidCharacters)
            .joined(separator: "")
        let zipOutputDir = documentsDirectory
            .appendingPathComponent("Packages")
        try? FileManager.default.createDirectory(
            at: zipOutputDir,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let zipTarget = zipOutputDir
            .appendingPathComponent(newFilename)
        try? FileManager.default.removeItem(at: zipTarget)

        var currentProgress = [String]()
        output("\n\n[*] Creating archive at \(zipTarget.path)\n\n")

        let requiredDot = 25 // 4 percent each lol
        output(
            [String](repeating: ".", count: requiredDot)
                .joined(separator: "")
        )
        output(" [100%]\n")
        SSZipArchive.createZipFile(
            atPath: zipTarget.path,
            withContentsOfDirectory: zipContainer.path,
            keepParentDirectory: false,
            compressionLevel: 0,
            password: nil,
            aes: false
        ) { entryNumber, total in
            let percent = Double(entryNumber) / Double(total)
            let currentDot = Int(percent * Double(requiredDot))
            while currentDot > currentProgress.count {
                currentProgress.append("=")
                output("=")
            }
        }
        output(" ++++++\n")

        output("\n\n")

        return zipTarget
    }

    func foulOptionToUrl(with: FoulOption) -> URL {
        switch with {
        case .tfp0:
            return foulTFP0
        case .krw:
            return foulKRW
        case .kernrw:
            return foulKERNRW
        case .unspecified:
            let get = decideUnspecifiedFoulBackend()
            if get == .unspecified {
                fatalError("malformed control flow")
            }
            return foulOptionToUrl(with: get)
        }
    }

    func decideUnspecifiedFoulBackend() -> FoulOption {
        if #available(iOS 14.0, *) {
            if FileManager.default.fileExists(atPath: "/.installed_taurine") {
                return .kernrw
            }
            return .krw
        } else {
            return .tfp0
        }
    }

    func clearDocuments() {
        let urls = [
            documentsDirectory
                .appendingPathComponent("Temporary"),
            documentsDirectory
                .appendingPathComponent("Packages"),
        ]
        for url in urls {
            let recipe = AuxiliaryExecute.spawn(
                command: binaryLocation.path,
                args: ["delete", url.path],
                timeout: 60
            )
            debugPrint(recipe)
        }
        SPIndicator.present(
            title: "Packages Cleared",
            preset: .done,
            haptic: .success
        )
    }
}

private extension Data {
    typealias SizeType = UInt32
    var magic: SizeType? {
        guard count >= MemoryLayout<SizeType>.size else { return nil }
        return withUnsafeBytes { $0.load(as: SizeType.self) }
    }
}
