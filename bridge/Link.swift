// `inkbridge link` / `inkbridge unlink`: add or remove an `inkbridge` command,
// a link in <prefix>/bin to this program. `make` runs `link --from-make`,
// which asks first and remembers the answer.

import Foundation

/// Where each link made is noted, so unlink finds them all, whatever prefix
/// was used and wherever the project folder has moved since.
let linksFile = configDir + "/links"
/// Present when the user said no to the command, or removed it with unlink,
/// so `make` does not ask again or quietly add it back.
let noLinkFile = configDir + "/no-link"

/// Handles `link [--prefix DIR] [--from-make]` and `unlink`. Returns false
/// for anything else.
func runLinkCommand(_ args: [String]) -> Bool {
    guard let command = args.first, command == "link" || command == "unlink" else { return false }
    var prefix = "/usr/local"
    if let i = args.firstIndex(of: "--prefix"), i + 1 < args.count {
        prefix = (args[i + 1] as NSString).expandingTildeInPath
    }
    let fromMake = args.contains("--from-make")
    let fm = FileManager.default
    let path = prefix + "/bin/inkbridge"
    // A link rather than a copy, so a later `make` updates the command too.
    let target = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    var recorded = ((try? String(contentsOfFile: linksFile, encoding: .utf8)) ?? "")
        .split(separator: "\n").map(String.init)
    try? fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)

    func destination(_ p: String) -> String? { try? fm.destinationOfSymbolicLink(atPath: p) }
    /// True if `p` is a symlink to an inkbridge program, so it is ours to replace or remove.
    func isOurLink(_ p: String) -> Bool { destination(p)?.hasSuffix("/inkbridge") == true }

    if command == "unlink" {
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
        fm.createFile(atPath: noLinkFile, contents: nil)
        print(removed == 0 ? "No inkbridge command found."
                           : "The inkbridge command is gone. `make` will not add it back; `./inkbridge link` does.")
        return true
    }

    if fromMake {
        // Already pointing at this build: the rebuild is all there was to do.
        if recorded.contains(where: { destination($0) == target }) || destination(path) == target {
            print("Updated: the inkbridge command now runs the new build.")
            return true
        }
        if fm.fileExists(atPath: noLinkFile) {
            print("Built. Start it with ./inkbridge in this folder, or run ./inkbridge link to add the inkbridge command.")
            return true
        }
        guard isatty(0) != 0 else {
            print("Built. Run ./inkbridge link to add the inkbridge command.")
            return true
        }
        if isOurLink(path), let old = destination(path) {
            print("The inkbridge command runs another copy (\((old as NSString).deletingLastPathComponent)). "
                  + "Point it to this one? [Y/n] ", terminator: "")
        } else {
            print("Add an inkbridge command, so you can start it from any folder? [Y/n] ", terminator: "")
        }
        let answer = (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        guard answer.isEmpty || answer.hasPrefix("y") else {
            fm.createFile(atPath: noLinkFile, contents: nil)
            print("OK. Start it with ./inkbridge in this folder. Run ./inkbridge link any time to add the command.")
            return true
        }
    }

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
        try? (recorded.joined(separator: "\n") + "\n").write(toFile: linksFile, atomically: true, encoding: .utf8)
    }
    try? fm.removeItem(atPath: noLinkFile)
    print("Linked: run inkbridge from any folder. (inkbridge unlink removes it.)")
    return true
}
