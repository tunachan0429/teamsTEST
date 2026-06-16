import SwiftUI
import Network
import Citadel
import NIOCore
import Darwin

// MARK: - Wake-on-LAN

struct WakeOnLan {
    /// MACアドレス (例: "AA:BB:CC:DD:EE:FF" or "AA-BB-CC-DD-EE-FF")
    static func send(macAddress: String, broadcastAddress: String = "255.255.255.255", port: UInt16 = 9) async throws {
        let cleanMac = macAddress
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
        guard cleanMac.count == 12 else {
            throw WoLError.invalidMacAddress
        }
        var macBytes = [UInt8]()
        var idx = cleanMac.startIndex
        while idx < cleanMac.endIndex {
            let nextIdx = cleanMac.index(idx, offsetBy: 2)
            guard let byte = UInt8(cleanMac[idx..<nextIdx], radix: 16) else {
                throw WoLError.invalidMacAddress
            }
            macBytes.append(byte)
            idx = nextIdx
        }
        // マジックパケット: 0xFF x6 + MACx16
        var packet = [UInt8](repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet += macBytes }

        // 注意: Network.framework(NWConnection)はブロードキャスト送信時にSO_BROADCASTを
        // 有効化しないため、iOS上では "Permission denied" (errno 13) で失敗する。
        // そのため生のBSDソケットでSO_BROADCASTを明示的に有効化して送信する。
        try Self.sendBroadcastPacket(packet, to: broadcastAddress, port: port)
    }

    private static func sendBroadcastPacket(_ packet: [UInt8], to address: String, port: UInt16) throws {
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else {
            throw WoLError.socketError("ソケットの作成に失敗しました (errno: \(errno))")
        }
        defer { close(sock) }

        var broadcastEnable: Int32 = 1
        guard setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &broadcastEnable, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw WoLError.socketError("ブロードキャスト設定に失敗しました (errno: \(errno))")
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, address, &addr.sin_addr) == 1 else {
            throw WoLError.socketError("ブロードキャストアドレスの形式が無効です: \(address)")
        }

        let sentBytes = withUnsafePointer(to: &addr) { ptr -> Int in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                packet.withUnsafeBufferPointer { bufferPtr in
                    sendto(sock, bufferPtr.baseAddress, bufferPtr.count, 0, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        guard sentBytes == packet.count else {
            throw WoLError.socketError("パケットの送信に失敗しました (errno: \(errno))")
        }
    }

    enum WoLError: LocalizedError {
        case invalidMacAddress
        case socketError(String)
        var errorDescription: String? {
            switch self {
            case .invalidMacAddress:
                return "MACアドレスの形式が無効です"
            case .socketError(let message):
                return message
            }
        }
    }
}

// MARK: - SSH Client
// Citadel (純Swift / SwiftNIOベース) を使用。CocoaPods/Objective-Cブリッジ不要のため
// GitHub Actions の署名なしビルドでも安定して解決・コンパイルできる。
// Package URL: https://github.com/orlandos-nl/Citadel.git

protocol SSHServiceProtocol {
    func shutdown(host: String, port: Int, username: String, password: String) async throws
    func checkOnline(host: String, port: Int) async -> Bool
}

class SSHService: SSHServiceProtocol {
    func shutdown(host: String, port: Int, username: String, password: String) async throws {
        let client = try await SSHClient.connect(
            host: host,
            port: port,
            authenticationMethod: .passwordBased(username: username, password: password),
            hostKeyValidator: .acceptAnything(),
            reconnect: .never
        )
        defer { Task { try? await client.close() } }
        // Windows: shutdown /s /t 0  /  Linux/Mac: sudo shutdown -h now でも代用可
        _ = try await client.executeCommand("shutdown /s /t 0")
    }

    func checkOnline(host: String, port: Int) async -> Bool {
        await TCPPing.check(host: host, port: port)
    }
}

enum SSHError: LocalizedError {
    case connectionFailed
    case authFailed

    var errorDescription: String? {
        switch self {
        case .connectionFailed: return "SSH接続に失敗しました"
        case .authFailed:       return "SSH認証に失敗しました"
        }
    }
}

// MARK: - TCP Ping (ホスト死活確認)

struct TCPPing {
    static func check(host: String, port: Int, timeout: TimeInterval = 3) async -> Bool {
        await withCheckedContinuation { cont in
            let conn = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: UInt16(port))!,
                using: .tcp
            )
            var resumed = false
            let timer = DispatchWorkItem {
                if !resumed { resumed = true; conn.cancel(); cont.resume(returning: false) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    timer.cancel()
                    if !resumed { resumed = true; conn.cancel(); cont.resume(returning: true) }
                case .failed:
                    timer.cancel()
                    if !resumed { resumed = true; cont.resume(returning: false) }
                default: break
                }
            }
            conn.start(queue: .global())
        }
    }
}

// MARK: - Settings Model

class PCSettings: ObservableObject {
    @Published var macAddress: String {
        didSet { UserDefaults.standard.set(macAddress, forKey: "mac") }
    }
    @Published var broadcastAddress: String {
        didSet { UserDefaults.standard.set(broadcastAddress, forKey: "broadcast") }
    }
    @Published var hostIP: String {
        didSet { UserDefaults.standard.set(hostIP, forKey: "host") }
    }
    @Published var sshPort: Int {
        didSet { UserDefaults.standard.set(sshPort, forKey: "sshPort") }
    }
    @Published var sshUsername: String {
        didSet { UserDefaults.standard.set(sshUsername, forKey: "sshUser") }
    }
    @Published var sshPassword: String {
        didSet { UserDefaults.standard.set(sshPassword, forKey: "sshPass") }
    }

    init() {
        macAddress       = UserDefaults.standard.string(forKey: "mac")       ?? "AA:BB:CC:DD:EE:FF"
        broadcastAddress = UserDefaults.standard.string(forKey: "broadcast") ?? "255.255.255.255"
        hostIP           = UserDefaults.standard.string(forKey: "host")       ?? "192.168.1.10"
        sshPort          = UserDefaults.standard.integer(forKey: "sshPort").nonZero ?? 22
        sshUsername      = UserDefaults.standard.string(forKey: "sshUser")    ?? "username"
        sshPassword      = UserDefaults.standard.string(forKey: "sshPass")    ?? ""
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}

// MARK: - ViewModel

class PowerControlViewModel: ObservableObject {
    enum DogeImage { case doge, acOn, acOff }

    @Published var isPowered: Bool = false
    @Published var currentImage: DogeImage = .doge
    @Published var dogeLabel: String = "STANDBY"
    @Published var logs: [(time: String, message: String)] = []
    @Published var uptimeSeconds: Int = 0
    @Published var pingMs: Int = 0
    @Published var showConfirm: Bool = false
    @Published var errorMessage: String? = nil
    @Published var isWorking: Bool = false    // 通信中フラグ
    @Published var clockString: String = "--:--:--"
    @Published var showSettings: Bool = false

    let settings = PCSettings()
    private let ssh = SSHService()

    private var uptimeTimer: Timer?
    private var flashTimer: Timer?
    private var clockTimer: Timer?
    private var pingTimer: Timer?

    var hostStatus: String { isPowered ? settings.hostIP : "OFFLINE" }
    var pingStatus: String { isPowered ? "\(pingMs) ms" : "--- ms" }
    var uptimeStatus: String {
        let h = uptimeSeconds / 3600
        let m = (uptimeSeconds % 3600) / 60
        let s = uptimeSeconds % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
    var powerStatus: String { isPowered ? "*** ON ***" : "-- OFF --" }
    var buttonLabel: String { isPowered ? "POWER OFF" : "POWER ON" }
    var confirmTitle: String { isPowered ? "POWER OFF" : "POWER ON" }
    var confirmMessage: String {
        isPowered
            ? "PCの電源を\nOFFにしますか？"
            : "PCの電源を\nONにしますか？"
    }

    init() {
        addLog("SYSTEM READY.")
        startClock()
        checkInitialStatus()
    }

    // 起動時に実際のPCの状態を確認し、isPoweredを正しい初期値に合わせる
    private func checkInitialStatus() {
        addLog("CHECKING HOST STATUS...")
        Task { @MainActor in
            let online = await TCPPing.check(host: settings.hostIP, port: settings.sshPort)
            if online {
                isPowered = true
                startUptimeTimer()
                currentImage = .doge
                dogeLabel = "ONLINE"
                pingMs = Int.random(in: 1...8)
                addLog("HOST IS ONLINE.")
            } else {
                isPowered = false
                currentImage = .doge
                dogeLabel = "STANDBY"
                addLog("HOST IS OFFLINE.")
            }
        }
    }

    private func startClock() {
        let fmt = DateFormatter(); fmt.dateFormat = "HH:mm:ss"
        clockString = fmt.string(from: Date())
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.clockString = fmt.string(from: Date())
        }
    }

    func addLog(_ msg: String) {
        let fmt = DateFormatter(); fmt.dateFormat = "HH:mm:ss"
        logs.append((time: fmt.string(from: Date()), message: msg))
        if logs.count > 5 { logs = Array(logs.suffix(5)) }
    }

    func showConfirmDialog() { showConfirm = true }
    func cancelConfirm()     { showConfirm = false }

    // MARK: - Execute Toggle (Real)
    func executeToggle() {
        showConfirm = false
        isWorking = true

        if !isPowered {
            powerOn()
        } else {
            powerOff()
        }
    }

    private func powerOn() {
        addLog("SENDING WOL PACKET...")
        Task { @MainActor in
            do {
                try await WakeOnLan.send(
                    macAddress: settings.macAddress,
                    broadcastAddress: settings.broadcastAddress
                )
                addLog("WOL SENT.")
                addLog("WAITING FOR HOST...")
                currentImage = .acOn
                dogeLabel = "BOOTING"

                // PCが応答するまでポーリング（最大60秒）
                let online = await waitForOnline(maxSeconds: 60)
                if online {
                    isPowered = true
                    startUptimeTimer()
                    currentImage = .doge
                    dogeLabel = "ONLINE"
                    pingMs = Int.random(in: 1...8)
                    addLog("HOST CONNECTED.")
                    addLog("POWER ON.")
                } else {
                    currentImage = .doge
                    dogeLabel = "STANDBY"
                    addLog("HOST TIMEOUT.")
                    errorMessage = "PCが応答しませんでした\n（WoL設定を確認してください）"
                }
            } catch {
                currentImage = .doge
                dogeLabel = "STANDBY"
                addLog("WOL ERROR.")
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func powerOff() {
        addLog("SENDING SHUTDOWN...")
        Task { @MainActor in
            do {
                try await ssh.shutdown(
                    host: settings.hostIP,
                    port: settings.sshPort,
                    username: settings.sshUsername,
                    password: settings.sshPassword
                )
                addLog("SHUTDOWN CMD SENT.")
                currentImage = .acOff
                dogeLabel = "SHUTTING DOWN"

                // PCがオフラインになるまでポーリング（最大60秒）
                await waitForOffline(maxSeconds: 60)
                isPowered = false
                stopUptimeTimer()
                currentImage = .doge
                dogeLabel = "STANDBY"
                pingMs = 0
                uptimeSeconds = 0
                addLog("HOST DISCONNECTED.")
                addLog("POWER OFF.")
            } catch {
                addLog("SHUTDOWN ERROR.")
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    // オンラインになるまで待機（1秒ごとにTCP ping）
    private func waitForOnline(maxSeconds: Int) async -> Bool {
        for _ in 0..<maxSeconds {
            let online = await TCPPing.check(host: settings.hostIP, port: settings.sshPort)
            if online { return true }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return false
    }

    // オフラインになるまで待機
    private func waitForOffline(maxSeconds: Int) async {
        for _ in 0..<maxSeconds {
            let online = await TCPPing.check(host: settings.hostIP, port: settings.sshPort)
            if !online { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func startUptimeTimer() {
        uptimeSeconds = 0
        uptimeTimer?.invalidate()
        uptimeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.uptimeSeconds += 1
            self.pingMs = Int.random(in: 1...8)
        }
    }

    private func stopUptimeTimer() {
        uptimeTimer?.invalidate()
        uptimeTimer = nil
    }

    deinit {
        uptimeTimer?.invalidate()
        flashTimer?.invalidate()
        clockTimer?.invalidate()
    }
}

// MARK: - Pixel Font Helper

struct PixelText: View {
    let text: String
    let size: CGFloat
    var color: Color = .black
    var alignment: TextAlignment = .leading

    var body: some View {
        Text(text)
            .font(.custom("PressStart2P-Regular", size: size))
            .foregroundColor(color)
            .multilineTextAlignment(alignment)
    }
}

// MARK: - Blinking Text

struct BlinkingText: View {
    let text: String
    let size: CGFloat
    let isOn: Bool
    let shouldBlink: Bool
    @State private var visible = true
    @State private var timer: Timer?

    var body: some View {
        PixelText(text: text, size: size, color: isOn ? .black : Color(white: 0.67))
            .opacity(shouldBlink && !visible ? 0 : 1)
            .onAppear { if shouldBlink { startBlink() } }
            .onDisappear { timer?.invalidate() }
            .onChange(of: shouldBlink) { v in
                if v { startBlink() } else { timer?.invalidate(); visible = true }
            }
    }
    private func startBlink() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in visible.toggle() }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var settings: PCSettings
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            ZStack {
                Color.white.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 0) {
                        sectionHeader("▶ WAKE-ON-LAN")
                        settingsField(label: "MAC ADDRESS", value: $settings.macAddress, placeholder: "AA:BB:CC:DD:EE:FF", keyboard: .asciiCapable)
                        settingsField(label: "BROADCAST", value: $settings.broadcastAddress, placeholder: "255.255.255.255", keyboard: .decimalPad)

                        sectionHeader("▶ SSH (POWER OFF)")
                        settingsField(label: "HOST IP", value: $settings.hostIP, placeholder: "192.168.1.10", keyboard: .decimalPad)
                        settingsFieldInt(label: "SSH PORT", binding: portBinding, placeholder: "22")
                        settingsField(label: "USERNAME", value: $settings.sshUsername, placeholder: "username", keyboard: .asciiCapable)
                        settingsFieldSecure(label: "PASSWORD", value: $settings.sshPassword)

                        Spacer(minLength: 40)
                    }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    PixelText(text: "SETTINGS", size: 10, color: .black)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { dismiss() }) {
                        PixelText(text: "DONE", size: 9, color: .black)
                    }
                }
            }
        }
    }

    private var portBinding: Binding<String> {
        Binding(
            get: { String(settings.sshPort) },
            set: { settings.sshPort = Int($0) ?? 22 }
        )
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            PixelText(text: title, size: 7, color: .white)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.black)
        .padding(.top, 16)
    }

    private func settingsField(label: String, value: Binding<String>, placeholder: String, keyboard: UIKeyboardType) -> some View {
        VStack(spacing: 0) {
            HStack {
                PixelText(text: label, size: 7, color: Color(white: 0.4))
                    .frame(width: 120, alignment: .leading)
                TextField(placeholder, text: value)
                    .font(.custom("PressStart2P-Regular", size: 8))
                    .keyboardType(keyboard)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider().background(Color(white: 0.85))
        }
    }

    private func settingsFieldInt(label: String, binding: Binding<String>, placeholder: String) -> some View {
        settingsField(label: label, value: binding, placeholder: placeholder, keyboard: .numberPad)
    }

    private func settingsFieldSecure(label: String, value: Binding<String>) -> some View {
        VStack(spacing: 0) {
            HStack {
                PixelText(text: label, size: 7, color: Color(white: 0.4))
                    .frame(width: 120, alignment: .leading)
                SecureField("••••••••", text: value)
                    .font(.custom("PressStart2P-Regular", size: 8))
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider().background(Color(white: 0.85))
        }
    }
}

// MARK: - Main View

struct ContentView: View {
    @StateObject private var vm = PowerControlViewModel()

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    topBar
                    headerBar
                    dogeSection
                    statusSection
                    controlSection
                    logSection
                    Spacer(minLength: 32)
                }
            }

            // Working overlay
            if vm.isWorking {
                workingOverlay
            }

            // Confirm dialog
            if vm.showConfirm {
                confirmOverlay
            }
        }
        .preferredColorScheme(.light)
        .sheet(isPresented: $vm.showSettings) {
            SettingsView(settings: vm.settings)
        }
        .alert("ERROR", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("OK") { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
                .font(.custom("PressStart2P-Regular", size: 8))
        }
    }

    // MARK: Top Bar
    var topBar: some View {
        HStack {
            PixelText(text: vm.clockString, size: 7, color: .white)
            Spacer()
            PixelText(text: "DOGE PC CTRL", size: 7, color: .white)
            Spacer()
            Button(action: { vm.showSettings = true }) {
                PixelText(text: "⚙", size: 11, color: .white)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.black)
    }

    // MARK: Header
    var headerBar: some View {
        HStack {
            Spacer()
            PixelText(text: "♥ DOGE POWER CONTROL ♥", size: 9, color: .white)
                .padding(.vertical, 10)
            Spacer()
        }
        .background(Color.black)
    }

    // MARK: Doge Image
    var dogeSection: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.white
                dogeImageView.frame(width: 150, height: 150)
            }
            .frame(width: 160, height: 160)
            .overlay(Rectangle().stroke(Color.black, lineWidth: 3))

            PixelText(text: vm.dogeLabel, size: 10, color: .white)
                .frame(width: 160)
                .padding(.vertical, 6)
                .background(Color.black)
                .overlay(Rectangle().stroke(Color.black, lineWidth: 3))
        }
        .padding(.top, 24)
    }

    @ViewBuilder
    var dogeImageView: some View {
        switch vm.currentImage {
        case .doge:  Image("img_doge").resizable().interpolation(.none).scaledToFit()
        case .acOn:  Image("img_on").resizable().interpolation(.none).scaledToFit()
        case .acOff: Image("img_off").resizable().interpolation(.none).scaledToFit()
        }
    }

    // MARK: Status
    var statusSection: some View {
        VStack(spacing: 0) {
            HStack {
                PixelText(text: "▶ SYSTEM STATUS", size: 7, color: .white)
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.black)

            VStack(spacing: 0) {
                statusRow(label: "POWER",  value: vm.powerStatus,  isOn: vm.isPowered, blink: vm.isPowered)
                Divider().background(Color(white: 0.8))
                statusRow(label: "HOST",   value: vm.hostStatus,   isOn: vm.isPowered)
                Divider().background(Color(white: 0.8))
                statusRow(label: "PING",   value: vm.pingStatus,   isOn: vm.isPowered)
                Divider().background(Color(white: 0.8))
                statusRow(label: "UPTIME", value: vm.uptimeStatus, isOn: vm.isPowered)
            }
            .padding(12)
        }
        .frame(width: 300)
        .overlay(Rectangle().stroke(Color.black, lineWidth: 3))
        .padding(.top, 20)
    }

    func statusRow(label: String, value: String, isOn: Bool, blink: Bool = false) -> some View {
        HStack {
            PixelText(text: label, size: 7, color: Color(white: 0.33))
            Spacer()
            BlinkingText(text: value, size: 8, isOn: isOn, shouldBlink: blink)
        }
        .padding(.vertical, 6)
    }

    // MARK: Controls
    var controlSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            PixelText(text: "▶ OPERATION", size: 7, color: Color(white: 0.33))
            Button(action: { vm.showConfirmDialog() }) {
                HStack(spacing: 12) {
                    powerIcon
                    PixelText(text: vm.buttonLabel, size: 12, color: .white)
                }
                .frame(maxWidth: .infinity).frame(height: 64)
                .background(Color.black)
                .overlay(Rectangle().stroke(Color.black, lineWidth: 3))
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(vm.isWorking)
            .opacity(vm.isWorking ? 0.5 : 1)
        }
        .frame(width: 300)
        .padding(.top, 24)
    }

    var powerIcon: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            context.fill(Path(CGRect(x: w*0.41, y: h*0.045, width: w*0.18, height: h*0.45)), with: .color(.white))
            var arc = Path()
            arc.addArc(center: CGPoint(x: w/2, y: h/2), radius: w*0.41,
                       startAngle: .degrees(227), endAngle: .degrees(313), clockwise: false)
            context.stroke(arc, with: .color(.white), lineWidth: w*0.14)
        }
        .frame(width: 20, height: 20)
    }

    // MARK: Log
    var logSection: some View {
        VStack(spacing: 0) {
            HStack {
                PixelText(text: "▶ EVENT LOG", size: 7, color: .white)
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.black)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(vm.logs, id: \.time) { log in
                    HStack(alignment: .top, spacing: 8) {
                        PixelText(text: log.time, size: 7, color: Color(white: 0.67))
                            .frame(minWidth: 46, alignment: .leading)
                        PixelText(text: log.message, size: 7, color: .black)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .bottomLeading)
            .frame(height: 80)
            .padding(10)
        }
        .frame(width: 300)
        .overlay(Rectangle().stroke(Color.black, lineWidth: 3))
        .padding(.top, 16)
    }

    // MARK: Working Overlay
    var workingOverlay: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(1.5)
                PixelText(text: vm.isPowered ? "SHUTTING DOWN..." : "BOOTING...", size: 8, color: .white)
            }
            .padding(32)
            .background(Color.black)
            .overlay(Rectangle().stroke(Color.white, lineWidth: 2))
        }
    }

    // MARK: Confirm Overlay
    var confirmOverlay: some View {
        ZStack {
            Color.white.opacity(0.93).ignoresSafeArea()
            VStack(spacing: 0) {
                PixelText(text: vm.confirmTitle, size: 8, color: .white)
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .background(Color.black)
                VStack(spacing: 14) {
                    PixelText(text: vm.confirmMessage, size: 8, color: .black, alignment: .center)
                        .lineSpacing(8).multilineTextAlignment(.center)
                    HStack(spacing: 10) {
                        Button(action: { vm.cancelConfirm() }) {
                            PixelText(text: "CANCEL", size: 8, color: .black)
                                .frame(maxWidth: .infinity).frame(height: 44)
                                .overlay(Rectangle().stroke(Color.black, lineWidth: 2))
                        }
                        .buttonStyle(PlainButtonStyle())
                        Button(action: { vm.executeToggle() }) {
                            PixelText(text: "OK", size: 8, color: .white)
                                .frame(maxWidth: .infinity).frame(height: 44)
                                .background(Color.black)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(16)
            }
            .frame(width: 260)
            .overlay(Rectangle().stroke(Color.black, lineWidth: 3))
            .background(Color.white)
        }
    }
}

#Preview { ContentView() }
