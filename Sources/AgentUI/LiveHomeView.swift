import SwiftUI
import AgentServices
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

public struct LiveHomeView: View {
    @ObservedObject private var session: AgentSession
    @Binding private var camera: Bool
    @Binding private var screen: Bool
    private let level: Double
    private let start: () -> Void
    private let stop: () -> Void
    private let pocket: (() -> Void)?
    private let legacy: (() -> Void)?
    @State private var showSettings = false
    @State private var showTimeline = false
    @State private var showWorkspace = false
    @State private var showComposer = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var message = ""
    @State private var workInstruction = ""
    @State private var artifact: WorkspaceArtifact?
    public init(session: AgentSession, camera: Binding<Bool>, screen: Binding<Bool>, level: Double, start: @escaping () -> Void, stop: @escaping () -> Void, pocket: (() -> Void)? = nil, legacy: (() -> Void)? = nil) {
        self.session = session; self._camera = camera; self._screen = screen; self.level = level; self.start = start; self.stop = stop; self.pocket = pocket; self.legacy = legacy
    }
    private let ink = Color(red: 0.91, green: 0.93, blue: 1)
    private let accent = Color(red: 0.6, green: 0.69, blue: 1)
    private let stageBackground = Color(red: 0.035, green: 0.043, blue: 0.065)
    private let cardCornerRadius: CGFloat = 22
    public var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 22) {
                        liveStage.frame(minHeight: max(210, geometry.size.height - 200))
                        if let row = currentCaption {
                            Button { showTimeline = true } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(speaker(row.source)).font(.caption.weight(.semibold)).foregroundStyle(accent)
                                        if !row.final { Text(row.source == "assistant" ? "返答中" : "聞き取り中").font(.caption2).foregroundStyle(ink.opacity(0.45)) }
                                        Spacer(); Image(systemName: "text.bubble").font(.caption).foregroundStyle(ink.opacity(0.45))
                                    }
                                    Text(row.text).font(.body).lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
                                }.padding(18).background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: cardCornerRadius))
                            }.buttonStyle(.plain).accessibilityLabel("文字起こしを開く。" + row.text)
                        }
                        if let proposal = session.proposal {
                            VStack(alignment: .leading, spacing: 12) {
                                Label("Hermesへの依頼", systemImage: "sparkles").font(.caption).foregroundStyle(accent)
                                Text(proposal.task).lineLimit(4)
                                HStack(spacing: 8) { Button("開始") { session.approveWork(); showWorkspace = true }.buttonStyle(.borderedProminent); Button("今はしない") { session.dismissWork() }.buttonStyle(.bordered) }
                            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: cardCornerRadius))
                        }
                        if let error = session.error {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.circle")
                                Text(error).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                            }.foregroundStyle(.orange).padding(14).background(.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                            .accessibilityElement(children: .combine).accessibilityLabel("エラー。\(error)")
                        }
                    }.frame(maxWidth: .infinity).padding(.horizontal, 22).padding(.bottom, 14)
                }.scrollIndicators(.hidden)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { controlBar }
        .foregroundStyle(ink).background(stageBackground).preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) { ConnectionSettingsView(session: session, legacy: legacy) }
        .sheet(isPresented: $showTimeline) {
            NavigationStack { ScrollView { LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(session.entries) { row in VStack(alignment: .leading, spacing: 6) {
                    Text(speaker(row.source) + " · " + row.timestamp.formatted(date: .omitted, time: .standard)).font(.caption).foregroundStyle(.secondary)
                    Text(row.text).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading) }
            }.padding(20) }.navigationTitle("文字起こし").toolbar { Button("閉じる") { showTimeline = false } } }.frame(minWidth: 320, minHeight: 420)
        }
        .sheet(isPresented: $showWorkspace) {
            NavigationStack {
                ScrollView { VStack(alignment: .leading, spacing: 20) {
                    TextField("作ってほしいもの・進めてほしい作業", text: $workInstruction, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...5)
                    Button("この作業を開始") { session.beginWork(workInstruction); workInstruction = "" }.buttonStyle(.borderedProminent).disabled(workInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !session.paired || session.agentBusy)
                    if session.agentBusy { ProgressView(session.agentProgress) }
                    Text(.init(session.agentResult.isEmpty ? "計画・調査・作業の結果がここに表示されます。" : session.agentResult)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(session.artifacts) { file in Button { artifact = file } label: { Label(file.name, systemImage: "doc.richtext").frame(maxWidth: .infinity, alignment: .leading) } }
                    if session.agentBusy { Button("作業を止める", role: .destructive) { session.stopWork() } }
                }.padding(24) }.navigationTitle("Hermesの作業").toolbar { Button("閉じる") { showWorkspace = false } }
            }.frame(minWidth: 320, minHeight: 420).task { await session.refreshArtifacts() }
                .sheet(item: $artifact) { file in
                    NavigationStack { ArtifactPreview(url: file.url).navigationTitle(file.name).toolbar { Button("閉じる") { artifact = nil } } }.frame(minWidth: 350, minHeight: 500)
                }
        }
    }
    private var currentCaption: LiveEntry? {
        if let user = session.entries.last(where: { $0.source == "user" }), !user.final { return user }
        return session.entries.last
    }
    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                Circle().fill(session.recording ? Color.red : accent).frame(width: 6, height: 6)
                Text(session.recording ? "記録中" : "Agent Live").font(.subheadline.weight(.semibold))
            }
            Spacer()
            Button { showWorkspace = true } label: {
                Image(systemName: "sparkles").font(.system(size: 19)).frame(width: 44, height: 44)
                    .overlay(alignment: .topTrailing) { if session.agentBusy { Circle().fill(accent).frame(width: 6, height: 6).padding(7) } }
            }.accessibilityLabel("Hermesの作業")
            Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3").font(.system(size: 19)).frame(width: 44, height: 44) }.accessibilityLabel("設定")
        }.buttonStyle(.plain).padding(.horizontal, 22).padding(.top, 6)
    }
    private var liveStage: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 18)
            if (camera || screen), let jpeg = session.visualFrame {
                ZStack(alignment: .topTrailing) {
                    SharedVisualPreview(jpeg: jpeg).frame(maxWidth: .infinity, maxHeight: 310)
                        .background(.black, in: RoundedRectangle(cornerRadius: 26)).clipShape(RoundedRectangle(cornerRadius: 26))
                    orb.frame(width: 60, height: 60).padding(14)
                }.transition(.opacity)
                Label(screen ? "画面を共有中" : "カメラを共有中", systemImage: screen ? "rectangle.on.rectangle" : "video").font(.subheadline)
            } else {
                orb.frame(width: 220, height: 220).padding(.vertical, 8)
                Text(session.reacting ? "発言を確認しています" : session.connecting ? "接続しています" : session.recording ? "記録しています" : session.paired ? "声で話しかける" : "接続を設定してください").font(.title3.weight(.medium)).multilineTextAlignment(.center)
            }
            Text(session.recording ? (session.localTranscriptionActive ? "聞いています · 端末内の文字起こし" : "声で話す · 必要なときに見せる") : "声で話す、あなたの相棒")
                .font(.caption).foregroundStyle(ink.opacity(0.5))
            if session.recording, !session.settings.liveConversation {
                Text("声オフ · 返答は文字で表示").font(.caption).foregroundStyle(accent)
            }
            if session.recording, session.settings.voice == .gemini, session.settings.geminiOnDemand, session.settings.liveConversation {
                Text(session.geminiCallActive ? (session.keepingGeminiConnected ? "会話中 · 接続を維持" : "会話中 · 会話が途切れると切断") : "待機中 · Geminiへの音声送信なし")
                    .font(.caption).foregroundStyle(accent)
                Button {
                    if session.geminiCallActive { session.endGeminiCall() } else { session.startGeminiCall() }
                } label: {
                    Label(session.geminiCallActive ? "会話を終了" : "Geminiと話す", systemImage: session.geminiCallActive ? "phone.down" : "phone")
                }.buttonStyle(.bordered).disabled(session.connecting)
            }
            if session.preparingPolicy { Text("Hermesが相棒の基準を準備しています").font(.caption2).foregroundStyle(ink.opacity(0.5)) }
            Button { showSettings = true } label: {
                HStack(spacing: 6) {
                    Text(session.settings.voice == .hermes ? (session.settings.agentProvider == .nous ? "Nous" : session.settings.agentProvider == .grok ? "Grok" : "Hermes") : session.voiceName)
                    if session.costSaving { Image(systemName: "leaf").font(.caption2) }
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }.font(.caption).foregroundStyle(ink.opacity(0.6)).padding(.horizontal, 13).padding(.vertical, 8)
                    .background(.white.opacity(0.045), in: Capsule())
            }.buttonStyle(.plain).accessibilityLabel("会話モデルと節約の設定")
            Spacer(minLength: 12)
        }.frame(maxWidth: .infinity).animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: camera || screen)
    }
    private var orb: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            ZStack {
                Circle().fill(accent.opacity(0.045)).blur(radius: size * 0.09)
                Circle().fill(RadialGradient(colors: [Color(red: 0.87, green: 0.91, blue: 1), Color(red: 0.58, green: 0.7, blue: 1), Color(red: 0.29, green: 0.43, blue: 0.89)], center: .init(x: 0.32, y: 0.22), startRadius: 0, endRadius: size * 0.65))
                    .frame(width: size * 0.72, height: size * 0.72)
                    .shadow(color: accent.opacity(0.17), radius: size * 0.11)
                    .scaleEffect(reduceMotion ? 1 : 1 + (session.recording ? min(0.15, level * 0.4) : 0))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: level)
                if session.connecting || session.reacting { ProgressView().tint(.white).scaleEffect(size < 100 ? 0.7 : 1) }
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }.accessibilityLabel(session.reacting ? "相棒が応答中" : "音声の状態")
    }
    private var controlBar: some View {
        VStack(spacing: 15) {
            HStack(spacing: 10) {
                mediaButton("video", title: "カメラ", selected: camera) { camera.toggle() }.disabled(!session.recording)
                mediaButton("rectangle.on.rectangle", title: "画面共有", selected: screen) { screen.toggle() }.disabled(!session.recording)
                mediaButton("text.bubble", title: "文字", selected: showComposer) { showComposer.toggle() }
            }
            if showComposer {
                HStack {
                    TextField("文字でも話しかける", text: $message).textFieldStyle(.plain).onSubmit { submit() }
                        .accessibilityLabel("文字のメッセージ入力")
                    Button { submit() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2).foregroundStyle(accent).frame(width: 44, height: 44) }.disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityLabel("送信")
                }.padding(.leading, 15).padding(.trailing, 6).background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 20))
            }
            HStack(spacing: 16) {
                if session.recording {
                    Button { Task { await session.toggleConversation() } } label: {
                        VStack(spacing: 4) {
                            Image(systemName: session.settings.liveConversation ? "speaker.wave.2" : "speaker.slash").font(.system(size: 19))
                            Text(session.settings.liveConversation ? "声オン" : "声オフ").font(.caption2)
                        }.frame(width: 58, height: 58)
                    }.buttonStyle(.plain).background(.white.opacity(0.09), in: Circle()).accessibilityLabel(session.settings.liveConversation ? "声の返答をオフにする。文字の返答と記録は続きます" : "声の返答をオンにする")
                }
                Button(action: session.recording ? stop : start) {
                    Label(session.recording ? "記録を終了" : "記録を開始", systemImage: session.recording ? "stop.fill" : "mic.fill")
                        .font(.headline).frame(maxWidth: .infinity).frame(minHeight: 54)
                }.buttonStyle(.plain).background(session.recording ? Color.white.opacity(0.12) : accent, in: Capsule()).foregroundStyle(session.recording ? ink : Color(red: 0.05, green: 0.075, blue: 0.15))
                if let pocket, session.recording {
                    Button(action: pocket) { Image(systemName: "moon").font(.system(size: 21)).frame(width: 44, height: 54) }.accessibilityLabel("画面を暗くする")
                }
            }
            Text(session.agentBusy ? "Hermesが作業中 · 会話は続けられます" : session.syncStatus).font(.caption2).foregroundStyle(ink.opacity(0.45)).lineLimit(2)
        }.padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 12).background(stageBackground)
    }
    private func mediaButton(_ icon: String, title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) { Image(systemName: icon).font(.system(size: 19)); Text(title).font(.caption2) }
                .frame(maxWidth: .infinity).frame(minHeight: 58).foregroundStyle(selected ? accent : ink.opacity(0.75))
                .background(selected ? accent.opacity(0.13) : .white.opacity(0.045), in: RoundedRectangle(cornerRadius: 20))
        }.buttonStyle(.plain).accessibilityLabel(title).accessibilityValue(selected ? "オン" : "オフ")
    }
    private func submit() { session.sendText(message); message = "" }
    private func speaker(_ source: String) -> String {
        if source == "user" || source == "microphone" || source == "verified:microphone" { return "あなた" }
        if source == "hermes" { return "Hermes" }
        if source == "assistant" { return "相棒" }
        if source.contains("meeting") || source.contains("screen-audio") || source.contains("discord") { return "会話の記録" }
        if source == "camera" || source == "screen" || source == "capture" { return "映像の状態" }
        return "記録"
    }
}

private struct SharedVisualPreview: View {
    let jpeg: Data
    @State private var picture: Image?
    var body: some View {
        Group { if let picture { picture.resizable().scaledToFit() } }
            .task(id: jpeg) {
                #if os(macOS)
                if let value = NSImage(data: jpeg) { picture = Image(nsImage: value) }
                #else
                if let value = UIImage(data: jpeg) { picture = Image(uiImage: value) }
                #endif
            }
    }
}

#if os(macOS)
private struct ArtifactPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> WKWebView { let view = WKWebView(); view.load(URLRequest(url: url)); return view }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#else
private struct ArtifactPreview: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView { let view = WKWebView(); view.load(URLRequest(url: url)); return view }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#endif
