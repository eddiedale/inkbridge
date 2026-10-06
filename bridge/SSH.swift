// SSH to the tablet: process spawning, connection check and key setup.

import Foundation

let home = FileManager.default.homeDirectoryForCurrentUser.path
let keyChoiceFile = configDir + "/ssh-key"     // private key path chosen at setup
let skipKeyFile = configDir + "/no-ssh-key"    // user declined key setup

// The shared control socket (one per host) means the password is asked once
// per 10 minutes, and the stream reuses the connection made by connect().
var sshOptions: [String] = {
    var options = ["-o", "ConnectTimeout=5", "-o", "ServerAliveInterval=2", "-o", "ControlMaster=auto",
                   "-o", "ControlPath=~/.ssh/inkbridge-%C", "-o", "ControlPersist=10m"]
    if let key = try? String(contentsOfFile: keyChoiceFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
        options += ["-i", key]
    }
    return options
}()

/// Starts ssh with posix_spawn rather than Process: Process detaches the child
/// from the terminal, so ssh could not open /dev/tty to ask for the password.
/// `stdin`/`stdout` are file descriptors to hand over, or nil for /dev/null
/// and the terminal respectively.
func spawnSSH(_ args: [String], stdin: Int32?, stdout: Int32?, quiet: Bool = false) -> pid_t? {
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    if let fd = stdin { posix_spawn_file_actions_adddup2(&actions, fd, 0) }
    else { posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0) }
    if let fd = stdout { posix_spawn_file_actions_adddup2(&actions, fd, 1) }
    if quiet {
        if stdout == nil { posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0) }
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
    }
    var argv = (["ssh"] + args).map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    var pid: pid_t = 0
    let err = posix_spawn(&pid, "/usr/bin/ssh", &actions, nil, &argv, environ)
    guard err == 0 else {
        print("Could not start ssh: \(String(cString: strerror(err)))")
        return nil
    }
    return pid
}

func wait(_ pid: pid_t) -> Int32 {
    var status: Int32 = 0
    waitpid(pid, &status, 0)
    return (status >> 8) & 0xff
}

/// Opens the shared connection, asking for the password if needed, so that
/// nothing prompts once the TUI has taken over the terminal.
func connect() -> Bool {
    guard let pid = spawnSSH(sshOptions + ["root@\(host)", "true"], stdin: nil, stdout: nil) else { return false }
    return wait(pid) == 0
}

/// Shell command that stops evtest processes reading our pen or touch device,
/// leaving others alone (xovi-tripletap runs its own evtest on the power button).
func stopOurEvtests() -> String {
    "for p in $(pidof evtest); do tr '\\0' ' ' < /proc/$p/cmdline 2>/dev/null | "
        + "grep -q -e /dev/input/\(device) -e /dev/input/\(touchDevice) && kill $p; done; true"
}

/// Ends evtest on the tablet, releasing the pen and touch grabs. Needed on quit:
/// the stream runs through the shared connection, which outlives our ssh client,
/// so the remote session does not get a hangup.
func stopRemote() {
    if let pid = spawnSSH(["-o", "BatchMode=yes"] + sshOptions + ["root@\(host)", stopOurEvtests()],
                          stdin: nil, stdout: nil, quiet: true) {
        _ = wait(pid)
    }
}

// MARK: Key setup

/// If key login does not work yet, offer once to install a public key on the
/// tablet (an existing one, or a new key just for the tablet), so later runs
/// need no password. The choice, or a "no", is remembered in ~/.config/inkbridge.
func offerKeySetup() {
    let fm = FileManager.default
    // Not interactive, declined before, or a key is already set up. If that key
    // stops working, the connect step reports it rather than offering a new one.
    guard isatty(0) != 0, !fm.fileExists(atPath: skipKeyFile),
          !fm.fileExists(atPath: keyChoiceFile) else { return }

    // Key login (or a live shared connection) already works: nothing to do.
    if let pid = spawnSSH(["-o", "BatchMode=yes"] + sshOptions + ["root@\(host)", "true"],
                          stdin: nil, stdout: nil, quiet: true), wait(pid) == 0 { return }

    let sshDir = "\(home)/.ssh"
    let newKey = "\(sshDir)/id_ed25519_inkbridge"
    let existing = ((try? fm.contentsOfDirectory(atPath: sshDir)) ?? [])
        .filter { $0.hasSuffix(".pub") && $0 != "id_ed25519_inkbridge.pub" }.sorted()

    print("Set up an SSH key so you won't need the tablet password?")
    for (i, name) in existing.enumerated() { print("  \(i + 1)) use ~/.ssh/\(name)") }
    print("  n) create a new key just for the tablet (~/.ssh/id_ed25519_inkbridge)")
    print("  s) skip, and don't ask again")
    print("Choice (Enter to skip for now): ", terminator: "")
    let answer = (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()

    try? fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
    let privateKey: String
    if answer == "s" {
        fm.createFile(atPath: skipKeyFile, contents: nil)
        print("OK, not asking again. Delete \(skipKeyFile) to be asked again.")
        return
    } else if answer == "n" {
        if !fm.fileExists(atPath: newKey) {
            let keygen = Process()
            keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            keygen.arguments = ["-q", "-t", "ed25519", "-N", "", "-C", "inkbridge", "-f", newKey]
            guard (try? keygen.run()) != nil else { print("Could not run ssh-keygen."); return }
            keygen.waitUntilExit()
            guard keygen.terminationStatus == 0 else { print("ssh-keygen failed."); return }
        }
        privateKey = newKey
    } else if let n = Int(answer), existing.indices.contains(n - 1) {
        privateKey = "\(sshDir)/" + existing[n - 1].dropLast(4)
    } else {
        return
    }
    guard let key = try? String(contentsOfFile: privateKey + ".pub", encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines) else {
        print("Could not read \(privateKey).pub")
        return
    }

    // The key goes in over stdin; append it unless it is already there.
    let install = "umask 077; mkdir -p ~/.ssh; read K; "
        + "grep -qxF \"$K\" ~/.ssh/authorized_keys 2>/dev/null || echo \"$K\" >> ~/.ssh/authorized_keys"
    var input: [Int32] = [0, 0]
    pipe(&input)
    _ = fcntl(input[1], F_SETFD, FD_CLOEXEC)
    print("Enter the tablet password once to install the key.")
    guard let pid = spawnSSH(sshOptions + ["root@\(host)", install], stdin: input[0], stdout: nil) else { return }
    close(input[0])
    _ = (key + "\n").withCString { write(input[1], $0, strlen($0)) }
    close(input[1])
    guard wait(pid) == 0 else {
        print("Could not install the key; continuing with the password.")
        return
    }
    try? privateKey.write(toFile: keyChoiceFile, atomically: true, encoding: .utf8)
    sshOptions += ["-i", privateKey]
    print("Key installed; no password needed from now on.")
}
