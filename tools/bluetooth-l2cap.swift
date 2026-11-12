// Mac side of the BLE SSH ProxyCommand. Standard output carries only SSH bytes.
import CoreBluetooth
import Darwin
import Foundation

private let serviceUUID = CBUUID(string: "76ec1d74-84ab-4bef-8b80-1b646d28b235")
private let psm: CBL2CAPPSM = 129

private func diagnose(_ message: String) {
    FileHandle.standardError.write(Data("inkbridge-ble: \(message)\n".utf8))
}

private func errorDetails(_ error: Error?) -> String {
    guard let error = error as NSError? else { return "" }
    return ": \(error.localizedDescription) (\(error.domain) \(error.code))"
}

private enum Mode {
    case scan
    case connect(UUID?)
}

private final class Bridge: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, StreamDelegate {
    private let mode: Mode
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var channel: CBL2CAPChannel?
    private var inputSource: DispatchSourceRead?
    private var timer: Timer?
    private var result: Int32?
    private var discovered = Set<UUID>()

    private var outbound = [UInt8](repeating: 0, count: 16_384)
    private var outboundStart = 0
    private var outboundEnd = 0
    private var inbound = [UInt8](repeating: 0, count: 16_384)

    init(mode: Mode) {
        self.mode = mode
    }

    func run() -> Int32 {
        let timeout: TimeInterval
        switch mode {
        case .scan: timeout = 8
        case .connect: timeout = 15
        }
        timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            self?.timedOut()
        }
        central = CBCentralManager(delegate: self, queue: nil)
        CFRunLoopRun()
        return result ?? 1
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            central.scanForPeripherals(withServices: [serviceUUID], options: nil)
        case .poweredOff:
            finish("Bluetooth is off")
        case .unauthorized:
            finish("allow Bluetooth access in System Settings > Privacy & Security > Bluetooth")
        case .unsupported:
            finish("Bluetooth Low Energy is unavailable on this Mac")
        case .resetting where peripheral != nil:
            finish("the Bluetooth controller reset")
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover device: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        switch mode {
        case .scan:
            guard discovered.insert(device.identifier).inserted else { return }
            let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? device.name ?? "Inkbridge"
            print("\(device.identifier.uuidString)\t\(name)")
        case .connect(let identifier):
            guard peripheral == nil, identifier == nil || device.identifier == identifier else { return }
            peripheral = device
            device.delegate = self
            central.stopScan()
            central.connect(device, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.openL2CAPChannel(psm)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        finish("could not connect to the tablet\(errorDetails(error))")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if error != nil {
            finish("Bluetooth disconnected\(errorDetails(error))")
        } else {
            finish(channel == nil ? "Bluetooth disconnected before the SSH channel opened" : nil)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard result == nil else { return }
        guard let channel, let input = channel.inputStream, let output = channel.outputStream, error == nil else {
            finish("could not open Bluetooth L2CAP channel \(psm)\(errorDetails(error))")
            return
        }
        self.channel = channel
        timer?.invalidate()
        for stream in [input as Stream, output] {
            stream.delegate = self
            stream.schedule(in: .main, forMode: .default)
            stream.open()
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
        source.setEventHandler { [weak self] in self?.readSSH() }
        inputSource = source
        source.activate()
    }

    func stream(_ stream: Stream, handle event: Stream.Event) {
        switch event {
        case .hasBytesAvailable:
            readBluetooth()
        case .hasSpaceAvailable:
            writeBluetooth()
        case .errorOccurred:
            finish("Bluetooth stream failed\(errorDetails(stream.streamError))")
        case .endEncountered:
            finish()
        default:
            break
        }
    }

    private func readSSH() {
        guard let inputSource, outboundStart == outboundEnd, result == nil else { return }
        let count = outbound.withUnsafeMutableBytes { buffer in
            var count: Int
            repeat {
                count = read(STDIN_FILENO, buffer.baseAddress!, buffer.count)
            } while count < 0 && errno == EINTR
            return count
        }
        if count == 0 {
            finish()
        } else if count < 0 {
            finish("could not read SSH input: \(String(cString: strerror(errno)))")
        } else {
            outboundStart = 0
            outboundEnd = count
            inputSource.suspend()
            writeBluetooth()
        }
    }

    private func writeBluetooth() {
        guard let stream = channel?.outputStream, outboundStart < outboundEnd, result == nil else { return }
        while outboundStart < outboundEnd, stream.hasSpaceAvailable {
            let count = outbound.withUnsafeBufferPointer { buffer in
                stream.write(buffer.baseAddress! + outboundStart, maxLength: outboundEnd - outboundStart)
            }
            if count < 0 {
                finish("could not write to Bluetooth\(errorDetails(stream.streamError))")
                return
            }
            if count == 0 { return }
            outboundStart += count
        }
        if outboundStart == outboundEnd { inputSource?.resume() }
    }

    private func readBluetooth() {
        guard let stream = channel?.inputStream, result == nil else { return }
        while stream.hasBytesAvailable {
            let count = inbound.withUnsafeMutableBufferPointer { buffer in
                stream.read(buffer.baseAddress!, maxLength: buffer.count)
            }
            if count < 0 {
                finish("could not read from Bluetooth\(errorDetails(stream.streamError))")
                return
            }
            if count == 0 { return }

            let writeError = inbound.withUnsafeBytes { buffer -> Int32? in
                var offset = 0
                while offset < count {
                    let written = write(STDOUT_FILENO, buffer.baseAddress! + offset, count - offset)
                    if written > 0 {
                        offset += written
                    } else if written == 0 {
                        return EIO
                    } else if errno != EINTR {
                        return errno
                    }
                }
                return nil
            }
            if let writeError {
                finish(writeError == EPIPE ? nil : "could not write SSH output: \(String(cString: strerror(writeError)))")
                return
            }
        }
    }

    private func timedOut() {
        if case .scan = mode {
            finish(discovered.isEmpty ? "no Inkbridge BLE service found" : nil)
        } else if peripheral == nil {
            finish("timed out looking for the Inkbridge BLE service")
        } else {
            finish("timed out opening Bluetooth L2CAP channel \(psm)")
        }
    }

    private func finish(_ error: String? = nil) {
        guard result == nil else { return }
        result = error == nil ? 0 : 1
        if let error { diagnose(error) }
        timer?.invalidate()
        if outboundStart < outboundEnd { inputSource?.resume() }
        inputSource?.cancel()
        central?.stopScan()
        if let channel {
            for stream in [channel.inputStream as Stream?, channel.outputStream as Stream?].compactMap({ $0 }) {
                stream.delegate = nil
                stream.remove(from: .main, forMode: .default)
                stream.close()
            }
        }
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        CFRunLoopStop(CFRunLoopGetMain())
    }
}

private func run(_ args: [String]) -> Int32 {
    switch args {
    case ["--help"]:
        print("Usage: inkbridge-ble scan | connect [PERIPHERAL-UUID]")
        return 0
    case ["scan"]:
        return Bridge(mode: .scan).run()
    case ["connect"]:
        return Bridge(mode: .connect(nil)).run()
    default:
        if args.count == 2, args[0] == "connect", let id = UUID(uuidString: args[1]) {
            return Bridge(mode: .connect(id)).run()
        }
        diagnose("usage: inkbridge-ble scan | connect [PERIPHERAL-UUID]")
        return 2
    }
}

signal(SIGPIPE, SIG_IGN)
exit(run(Array(CommandLine.arguments.dropFirst())))
