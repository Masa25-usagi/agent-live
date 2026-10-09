import SwiftUI
import UIKit
import ReplayKit
import Combine
import Darwin
import AgentServices
import AgentUI

@main
struct AgentLiveIOSApp: App {
    @StateObject private var model = MobileController()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            LiveHomeView(session: model.session, camera: $model.cameraOn, screen: Binding(get: { model.sharingActive }, set: { enabled in if enabled { model.screenOn = true } else { model.endScreenSharing() } }), level: Double(model.level), start: { Task { await model.start() } }, stop: { Task { await model.stop() } }, pocket: { model.pocket = true })
                .overlay { if model.pocket { Color.black.ignoresSafeArea().overlay(alignment: .bottom) { Text("ダブルタップで戻る").font(.caption).foregroundStyle(.white.opacity(0.25)).padding(.bottom, 50) }.onTapGesture(count: 2) { model.pocket = false } } }
                .overlay(alignment: .top) { if let error = model.error {
                    VStack(spacing: 8) {
                        Text(error).font(.caption)
                        if model.captureState.paused { Button("音声を再開") { model.resumeAudio() }.buttonStyle(.bordered) }
                    }.padding(12).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12)).padding(.top, 45)
                        .onTapGesture { if !model.captureState.paused { model.error = nil } }
                } }
                .onChange(of: scenePhase) { _, phase in model.sceneChanged(phase) }
                .sheet(isPresented: $model.screenOn) { BroadcastSheet(model: model) }
                .task { await model.prepareConnection(); if model.session.settings.autoRecord && !CommandLine.arguments.contains("--connect-only") { await model.start() } }
        }
    }
}

@MainActor
final class MobileController: ObservableObject {
    let session = AgentSession(automaticMaintenance: false)
    private let audio = MobileAudio()
    private let camera = CameraCapture()
    @Published var level: Float = 0
    @Published var cameraOn = false { didSet { if oldValue != cameraOn { if !cameraOn && !sharingActive { session.clearVisualFrame() }; Task { await updateCamera() } } } }
    @Published var screenOn = false
    @Published var sharingActive = false
    @Published var pendingScreenBytes = 0
    @Published var pocket = false { didSet { guard oldValue != pocket else { return }; if pocket { brightness = UIScreen.main.brightness; UIScreen.main.brightness = 0.02 } else { UIScreen.main.brightness = brightness } } }
    @Published var error: String?
    @Published var captureState: AudioCaptureState = .inactive
    private var brightness: CGFloat = 0.5
    private var idleDisabled = false
    private var starting = false
    private var inForeground = true
    private var subscriptions = Set<AnyCancellable>()
    private var recoveryTask: Task<Void, Never>?
    private var preparedConnection = false
    init() {
        session.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        audio.onPCM = { [weak self] data, level in Task { @MainActor in self?.level = level; self?.session.acceptAudio(data) } }
        audio.onState = { [weak self] message in Task { @MainActor in self?.error = message; try? self?.session.archive.appendTranscript(text: message, source: "interruption", final: true) } }
        audio.onCaptureState = { [weak self] state in Task { @MainActor in
            guard let self else { return }
            if self.captureState.paused, state == .recording { self.error = nil; try? self.session.archive.appendTranscript(text: "音声の記録を再開", source: "interruption", final: true) }
            self.captureState = state
        } }
        session.onAudio = { [weak self] data, rate in self?.audio.play(data, rate: rate) }
        session.onEncodedAudio = { [weak self] data in self?.audio.playEncoded(data) }
        session.onInterrupt = { [weak self] in self?.audio.interrupt() }
        session.onStorageFull = { [weak self] in Task { await self?.stop() } }
        camera.onFrame = { [weak self] data in Task { @MainActor in if self?.cameraOn == true { self?.session.acceptFrame(data) } } }
        camera.onError = { [weak self] error in Task { @MainActor in self?.error = error; self?.cameraOn = false } }
        #if !AGENT_LIVE_VOICE_ONLY
        recoveryTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.recoverBroadcast()
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
        #endif
    }
    /// USB setup uses the app's private container; the connection key never enters launch arguments.
    func prepareConnection() async {
        guard !preparedConnection else { return }; preparedConnection = true
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let incoming = documents.appendingPathComponent("agentlive-pairing.json")
        var imported = false
        if FileManager.default.fileExists(atPath: incoming.path) {
            do {
                let values = try incoming.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true, (values.fileSize ?? 0) > 0, (values.fileSize ?? 0) <= 16_384 else { throw BridgeError.malformedResponse }
                let data = try Data(contentsOf: incoming)
                guard let config = try JSONSerialization.jsonObject(with: data) as? [String: String], let endpoint = config["endpoint"], let token = config["token"] else { throw BridgeError.malformedResponse }
                _ = try BridgeClient(endpoint: endpoint, token: token)
                await session.pair(token: String(decoding: data, as: UTF8.self))
                if DeviceCredential.read() == token && session.settings.endpoint == endpoint {
                    imported = true
                    try FileManager.default.removeItem(at: incoming)
                } else { throw BridgeError.missingCredential }
            } catch { self.error = "Macからの接続情報を取り込めませんでした。設定から再接続できます。" }
        }
        if !imported { await session.checkConnection() }
        var sharedKeychainReady = false
        #if !AGENT_LIVE_VOICE_ONLY
        do {
            try SharedBroadcastStore.save(["ready": true], name: "probe")
            sharedKeychainReady = SharedBroadcastStore.read("probe")?["ready"] as? Bool == true
            SharedBroadcastStore.remove("probe")
        } catch { }
        #endif
        let report: [String: Any] = ["configuration_imported": imported, "configured": session.paired,
            "server_reachable": session.error == nil && !session.health.isEmpty,
            "recording": session.recording, "services": session.health, "checked_at_epoch": Date().timeIntervalSince1970,
            "voice": session.settings.voice.rawValue, "live_conversation": session.settings.liveConversation,
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "app_build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "agent_provider": session.settings.agentProvider.rawValue,
            "agent_model": session.settings.agentModel, "speech_provider": session.settings.speechProvider.rawValue,
            "economy_fast_mode": session.settings.economyFastMode, "gemini_fast_mode": session.settings.geminiFastMode,
            "direct_gemini": session.usesDirectGemini, "direct_jev": session.settings.directJev,
            "gemini_on_demand": session.settings.geminiOnDemand, "gemini_idle_seconds": session.settings.geminiIdleSeconds,
            "broadcast_extension_installed": Bundle.main.builtInPlugInsURL.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("AgentLiveBroadcast.appex").path) } ?? false,
            "broadcast_shared_keychain_ready": sharedKeychainReady, "host_mode": session.hostMode]
        // Health and chosen model IDs only; no credentials. Used to confirm the actual app connection.
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
            try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            try? data.write(to: documents.appendingPathComponent("agentlive-connection.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        session.startMaintenance()
    }
    func start() async {
        guard !starting, !session.recording else { return }; starting = true; defer { starting = false }
        do {
            try await session.start(); try await audio.start()
            idleDisabled = UIApplication.shared.isIdleTimerDisabled
            let id = session.sessionID
            camera.onSegment = { [weak self] url, start, duration in Task { @MainActor in self?.session.acceptVideoFile(url, source: "camera", sessionID: id, startedAt: start, duration: duration) } }
            if cameraOn { await updateCamera() }; prepareBroadcast()
        } catch { self.error = error.localizedDescription; await stop() }
    }
    func stop() async {
        #if !AGENT_LIVE_VOICE_ONLY
        SharedBroadcastStore.remove("connection")
        #endif
        audio.stop(); await camera.stop(); cameraOn = false; pocket = false
        UIApplication.shared.isIdleTimerDisabled = idleDisabled
        await session.stop()
    }
    func resumeAudio() { audio.resumeAfterInterruption() }
    func sceneChanged(_ phase: ScenePhase) {
        inForeground = phase == .active
        if !inForeground { Task { await camera.stop() }; if cameraOn { error = "画面ロック中はカメラが停止します。音声は続いています。"; try? session.archive.appendTranscript(text: "カメラを一時停止（画面が非表示）。音声記録は継続", source: "camera", final: true) } }
        else if cameraOn { Task { await updateCamera() } }
    }
    private func updateCamera() async {
        UIApplication.shared.isIdleTimerDisabled = cameraOn && session.recording ? true : idleDisabled
        guard cameraOn, session.recording, inForeground else { await camera.stop(); return }
        do { try await camera.start(directory: session.archive.root.appendingPathComponent("VideoStaging"), recordVideo: session.settings.recordVideo) }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription; cameraOn = false }
    }
    func endScreenSharing() {
        SharedBroadcastStore.remove("connection"); sharingActive = false; session.receivesSharedScreen = false
        if !cameraOn { session.clearVisualFrame() }
    }
    func prepareBroadcast() {
        #if !AGENT_LIVE_VOICE_ONLY
        guard session.recording, let token = DeviceCredential.read() else { return }
        let config: [String: Any] = ["endpoint": session.settings.endpoint, "token": token, "sessionID": session.sessionID, "recordVideo": session.settings.recordVideo,
            "offlineMegabytes": session.settings.offlineMegabytes, "frameInterval": session.costSaving ? 3 : 1]
        do {
            try SharedBroadcastStore.save(config, name: "connection")
        } catch { self.error = "画面共有の接続情報を準備できませんでした。" }
        #endif
    }
    private func recoverBroadcast() {
        #if !AGENT_LIVE_VOICE_ONLY
        if let state = SharedBroadcastStore.read("state") {
            sharingActive = session.recording && state["sessionID"] as? String == session.sessionID && state["active"] as? Bool == true && Date().timeIntervalSince1970 - (state["heartbeat"] as? Double ?? 0) < 15
            pendingScreenBytes = state["pending_bytes"] as? Int ?? 0
        } else { sharingActive = false }
        session.receivesSharedScreen = sharingActive
        #endif
    }
}

struct BroadcastSheet: View {
    @ObservedObject var model: MobileController
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 22) {
            Text("画面を見せる").font(.title2.bold())
            #if AGENT_LIVE_VOICE_ONLY
            Text("この版では音声とカメラを使えます。他のアプリの画面共有には、画面共有に対応した版のインストールが必要です。AIの作業結果は作業ボタンから開けます。").multilineTextAlignment(.center)
            #else
            Text("記録を開始したあと、下のボタンからAgent Liveへの画面共有を開始してください。他のアプリへ移動しても音声は続きます。").multilineTextAlignment(.center)
            BroadcastPicker().frame(width: 60, height: 60).disabled(!model.session.recording)
            Text("共有の停止はiPhone上部の画面収録表示から行えます。").font(.caption).foregroundStyle(.secondary)
            if model.pendingScreenBytes > 0 {
                Text("画面共有の保存待ち: " + ByteCountFormatter.string(fromByteCount: Int64(model.pendingScreenBytes), countStyle: .file) + "。次の共有開始時にも再送します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            #endif
            Button("閉じる") { dismiss() }
        }.padding(30).onAppear { model.prepareBroadcast() }.presentationDetents([.medium])
    }
}
struct BroadcastPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let view = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 60, height: 60))
        view.preferredExtension = AgentContainer.broadcastIdentifier; view.showsMicrophoneButton = false; return view
    }
    func updateUIView(_ view: RPSystemBroadcastPickerView, context: Context) {}
}
