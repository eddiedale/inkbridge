// `inkbridge link` / `inkbridge unlink`: add or remove an inkbridge command.

import Foundation

/// Where each link made is noted, so unlink finds them all, whatever prefix
/// was used and wherever the project folder has moved since.
let linksFile = configDir + "/links"

/// Handles `link [--prefix DIR]` and `unlink`. Returns false for anything else.
func runLinkCommand(_ args: [String]) -> Bool {
    guard let command = args.first, command == "link" || command == "unlink" else { return false }
    var prefix = "/usr/local"
    if let i = args.firstIndex(of: "--prefix"), i + 1 < args.count {
        prefix = (args[i + 1] as NSString).expandingTildeInPath
    }
    let fm = FileManager.default
    let path = prefix + "/bin/inkbridge"
    var recorded = ((try? String(contentsOfFile: linksFile, encoding: .utf8)) ?? "")
        .split(separator: "\n").map(String.init)

    /// True if `p` is a symlink to an inkbridge program, so it is ours to replace or remove.
    func isOurLink(_ p: String) -> Bool {
        (try? fm.destinationOfSymbolicLink(atPath: p))?.hasSuffix("/inkbridge") == true
    }

    if command == "link" {
        // A link rather than a copy, so a later ./build updates the command too.
        let target = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
        if fm.fileExists(atPath: path) || isOurLink(path) {
            guard isOurLink(path) else {
                print("\(path) exists and is not an inkbridge link; leaving it alone.")
                exit(1)
            }
            try? fm.removeItem(atPath: path)
        }
        do {
            try fm.createDirectory(atPath: prefix + "/bin", withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: path, withDestinationPath: target)
        } catch {
            print("Could not create \(path): \(error.localizedDescription)")
            print("Try `sudo ./inkbridge link`, or `./inkbridge link --prefix ~/.local` if ~/.local/bin is on your PATH.")
            exit(1)
        }
        if !recorded.contains(path) {
            recorded.append(path)
            try? fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
            try? (recorded.joined(separator: "\n") + "\n").write(toFile: linksFile, atomically: true, encoding: .utf8)
        }
        print("Linked \(path) -> \(target). Run inkbridge from anywhere.")
    } else {
        var removed = 0
        for p in Set(recorded + [path]) where isOurLink(p) {
            if (try? fm.removeItem(atPath: p)) != nil {
                print("Removed \(p)")
                removed += 1
            } else {
                print("Could not remove \(p); try with sudo.")
            }
        }
        try? fm.removeItem(atPath: linksFile)
        if removed == 0 { print("No inkbridge links found.") }
    }
    return true
}
