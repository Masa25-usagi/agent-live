import SwiftUI
import AgentServices
#if os(macOS)
import AppKit
#endif

struct ConnectionSettingsView: View {
    @ObservedObject var session: AgentSession
    let legacy: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var apiProvider = "grok"
    @State private var apiKey = ""
    @State private var providerMessage = ""
    @State private var savingProvider = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("声で返答", isOn: Binding(get: { session.settings.liveConversation }, set: { session.setConversationEnabled($0) }))
                    Picker("話し方", selection: Binding(get: { session.settings.voice }, set: { session.selectVoice($0) })) {
                        ForEach(VoiceProvider.allCases) { Text($0.title).tag($0) }
                    }
                    if session.settings.voice == .hermes {
                        Toggle("節約高速モード（試験）", isOn: Binding(get: { session.settings.economyFastMode }, set: { session.setEconomyFastMode($0) }))
                        Text("呼びかけへの返答を先に始め、端末の日本語の声で読み上げます。Grok・Nousの会話に対応します。")
                            .font(.caption).foregroundStyle(.secondary)
                        Picker("サブスク", selection: Binding(get: { session.settings.agentProvider }, set: { session.selectAgentProvider($0) })) {
                            ForEach(AgentInferenceProvider.allCases) { Text($0.title).tag($0) }
                        }
                        NavigationLink {
                            ModelSelectionView(title: "会話モデル", models: agentModels, selected: session.settings.agentModel,
                                defaultLabel: session.settings.agentProvider == .current ? "Hermesの設定を使う" : "", loading: session.loadingModels, message: modelStatus,
                                reload: { await session.loadModels(refresh: $0) }, choose: { session.selectAgentModel($0) })
                        } label: { settingRow("モデル", value: session.loadingModels ? "一覧を読み込んでいます" : session.settings.agentModel.isEmpty ? "選択してください" : session.settings.agentModel) }
                    } else {
                        if session.settings.voice == .gemini {
                            Picker("会話が途切れたら切断", selection: Binding(get: { session.settings.geminiIdleSeconds }, set: { session.setGeminiIdleSeconds($0) })) {
                                Text("30秒後").tag(30.0); Text("1分後").tag(60.0); Text("2分後").tag(120.0); Text("5分後").tag(300.0)
                            }
                            Text("記録開始時は未接続です。呼びかけや必要な質問で接続し、別れの言葉か待機時間で切断します。「切らずにつないでおいて」と頼むと、その会話では自動切断しません。")
                                .font(.caption).foregroundStyle(.secondary)
                            Toggle("高速モード（試験）", isOn: Binding(get: { session.settings.geminiFastMode }, set: { session.setGeminiFastMode($0) }))
                            if session.settings.geminiFastMode {
                                Picker("接続方法", selection: Binding(get: { session.settings.directGemini }, set: { session.setDirectGemini($0) })) {
                                    Text("ホスト経由").tag(false)
                                    Text("端末から直接").tag(true)
                                }
                                Text("同じモデルで接続方法を比べられます。直接接続もGoogleの音声API利用枠を使います。開始時の認証とHermesの作業にはホストを使います。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        NavigationLink {
                            ModelSelectionView(title: "Liveモデル", models: voiceModels, selected: session.settings.selectedVoiceModel,
                                loading: session.loadingModels, message: session.modelMessage, reload: { await session.loadModels(refresh: $0) }, choose: { session.selectVoiceModel($0) })
                        } label: { settingRow("モデル", value: session.loadingModels ? "一覧を読み込んでいます" : session.settings.selectedVoiceModel) }
                    }
                    Toggle("節約モード", isOn: Binding(get: { session.costSaving }, set: { enabled in Task { await session.saveCostSettings(enabled: enabled) } }))
                        .disabled(!session.paired)
                    if !session.costSettingStatus.isEmpty { Text(session.costSettingStatus).font(.caption).foregroundStyle(.secondary) }
                    if (session.settings.voice == .hermes && session.settings.economyFastMode) || (session.settings.voice == .gemini && session.settings.geminiFastMode) {
                        NavigationLink("Jevの接続（試験）") {
                            Form {
                                Toggle("Jevも端末から直接", isOn: Binding(get: { session.settings.directJev }, set: { session.setDirectJev($0) }))
                                Text("オンにすると、次の判断からJevを端末から呼び出します。JevのAPIキーは端末の安全な保存領域に保存します。自動制作の実行範囲はホスト側で守ります。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.navigationTitle("Jevの接続")
                        }
                    }
                } header: { Text("声で話す") } footer: {
                    Text(session.settings.voice == .hermes ? "Grok・Nousの契約を優先して使います。声をオフにしても、相棒の反応を有効にしていれば文字で返答します。" : session.settings.voice == .gemini ? "音声APIの利用量はGeminiへ接続している間に発生します。切断後も録音と文字起こしは続けられます。" : "記録中に接続を維持するLive音声です。各社の音声API利用枠を使います。")
                }
                Section {
                    Toggle("会話から反応・行動する", isOn: $session.settings.companionEnabled)
                    Toggle("案・試作品も自動で作る", isOn: $session.settings.automaticDrafts).disabled(!session.settings.companionEnabled)
                    NavigationLink("ホストごとの実行範囲") {
                        Form {
                            Section(session.hostName.isEmpty ? "接続中のホスト" : session.hostName) {
                                Picker("実行環境", selection: Binding(get: { session.hostMode }, set: { mode in Task { await session.saveHostMode(mode) } })) {
                                    Text("メインPC").tag("main")
                                    Text("専用PC・隔離環境").tag("dedicated")
                                }.pickerStyle(.inline).disabled(!session.paired || session.savingHostMode)
                            }
                            Section {
                                Text(session.hostMode == "dedicated" ? "このホスト内部での制作・ファイルや設定の変更・インストールまで自動で進めます。" : "調査・記憶の更新と、専用フォルダー内の案・試作品の作成を自動で進めます。既存環境の変更は確認します。")
                                Text("送信・公開・購入・他ホストの変更は、どちらでも確認が必要です。切り替えはこのサーバーに保存され、同じホストを使う端末へ反映されます。").font(.caption).foregroundStyle(.secondary)
                            }
                        }.navigationTitle("実行範囲").task { await session.checkConnection() }
                    }
                    NavigationLink("目的・行動基準") {
                        Form {
                            Section("手伝ってほしいこと") {
                                TextField("目的", text: $session.settings.objective, axis: .vertical).lineLimit(3...6)
                                Button("Hermesに基準を作ってもらう") { session.saveSettings(); session.refreshBehaviorPolicy(force: true) }.disabled(!session.paired || session.preparingPolicy)
                            }
                            Section("Hermesが作った基準") {
                                Text(session.behaviorStatus).font(.caption).foregroundStyle(.secondary)
                                if let rules = session.behaviorPolicy {
                                    Text(rules.persona)
                                    criteria("声をかける", rules.speakCriteria)
                                    criteria("動く", rules.buildCriteria)
                                    criteria("見送る", rules.doNotBuildCriteria)
                                }
                            }
                        }.navigationTitle("JevとHermes")
                    }
                } header: { Text("相棒の動き") } footer: {
                    Text("Jevが発言を判断し、Hermesが調査・記憶・案や試作品を進めます。制作の許可範囲はホストごとに切り替えられます。")
                }
                Section {
                    NavigationLink("文字起こし・読み上げ") {
                        Form {
                            Toggle("端末内で素早く文字を表示", isOn: Binding(get: { session.settings.onDeviceTranscription }, set: { session.setOnDeviceTranscription($0) }))
                            Text("日本語の端末内認識を使い、話し終わった内容をAIへ渡します。利用できない場合はGroqを使います。保存する音声はそのまま残します。").font(.caption).foregroundStyle(.secondary)
                            Picker("読み上げ", selection: Binding(get: { session.settings.speechProvider }, set: { session.selectSpeechProvider($0) })) {
                                ForEach(AgentSpeechProvider.allCases) { Text($0.title).tag($0) }
                            }
                            Toggle("専門用語を自動で調べる", isOn: $session.settings.autoResearch)
                        }.navigationTitle("文字と声")
                    }
                    NavigationLink("記録と保存") { recordingSettings }
                    NavigationLink("サーバー・APIの接続") { connectionSettings }
                    Button(session.loadingModels ? "接続を確認しています" : "モデル一覧を更新") { Task { await session.loadModels(refresh: true) } }.disabled(session.loadingModels || !session.paired)
                    if !session.modelMessage.isEmpty { Text(session.modelMessage).font(.caption).foregroundStyle(.secondary) }
                    if let legacy { Button("以前の会議支援を開く") { session.saveSettings(); dismiss(); legacy() }.disabled(session.recording) }
                } header: { Text("詳細") }
            }.navigationTitle("設定").toolbar { Button("完了") { session.saveSettings(); dismiss() } }
                .task { await session.loadModels() }
        }.frame(minWidth: 320, minHeight: 460)
    }
    private var recordingSettings: some View {
        Form {
            Toggle("起動時に記録を始める", isOn: $session.settings.autoRecord)
            Toggle("オンにした映像も保存する", isOn: $session.settings.recordVideo)
            Stepper("保存待ち \(session.settings.offlineMegabytes) MBまで", value: $session.settings.offlineMegabytes, in: 64...4096, step: 64)
            Text("音声は画面ロック中も続きます。カメラは実際のロック中に停止します。Driveへの保存を確認した区切りから端末容量を解放します。").font(.caption).foregroundStyle(.secondary)
            Button("保存待ちを再送する") { Task { await session.synchronizeNow() } }.disabled(!session.paired)
            Text(session.syncStatus).font(.caption).foregroundStyle(.secondary)
        }.navigationTitle("記録と保存")
    }
    private var connectionSettings: some View {
        Form {
            Section("サーバー") {
                TextField("接続先", text: $session.settings.endpoint).disabled(session.recording || session.agentBusy)
                SecureField("接続キー、またはMacの接続情報", text: $token).disabled(session.recording || session.agentBusy)
                Button("接続を確認") { session.saveSettings(); Task { if token.isEmpty { await session.checkConnection() } else { await session.pair(token: token); token = "" } } }.disabled(session.agentBusy)
                healthRow(session.health["agent"] == true, ok: "Hermesに接続済み", action: "Hermesを確認してください", icon: "brain")
                healthRow(session.health["drive"] == true, ok: "Drive保存を利用できます", action: "Driveの認証が必要です", icon: "externaldrive")
                healthRow(session.health["jev"] == true, ok: "Jevに接続済み", action: "Jevの接続を確認してください", icon: "sparkles")
                #if os(macOS)
                Button("iPhone用の接続情報をコピー") {
                    if let secret = DeviceCredential.read(), let data = try? JSONSerialization.data(withJSONObject: ["endpoint": session.settings.endpoint, "token": secret,
                        "voice": session.settings.voice.rawValue, "agent_provider": session.settings.agentProvider.rawValue,
                        "agent_model": session.settings.agentModel, "speech_provider": session.settings.speechProvider.rawValue]), let value = String(data: data, encoding: .utf8) {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
                    }
                }.disabled(!session.paired)
                #endif
            }
            Section("APIキーを追加") {
                Picker("サービス", selection: $apiProvider) {
                    Text("Grok / xAI").tag("grok"); Text("OpenAI").tag("openai"); Text("Gemini").tag("gemini"); Text("Groq（文字起こし）").tag("groq"); Text("Jev（判断）").tag("jev")
                }
                SecureField("APIキー", text: $apiKey)
                Button(savingProvider ? "保存しています" : "サーバーへ保存") {
                    savingProvider = true; providerMessage = ""
                    Task {
                        do { try await session.saveProviderCredential(provider: apiProvider, key: apiKey); apiKey = ""; providerMessage = "保存しました" }
                        catch { providerMessage = BridgeClient.connectionMessage(error) }
                        savingProvider = false
                    }
                }.disabled(apiKey.isEmpty || !session.paired || savingProvider || session.recording)
                if !providerMessage.isEmpty { Text(providerMessage).font(.caption).foregroundStyle(.secondary) }
            }
            Text("Macまたはサーバーと同じTailscaleへ接続してください。節約モードは無音・映像の重複・不要な調査を減らします。請求額の上限を設定する機能ではありません。").font(.caption).foregroundStyle(.secondary)
        }.navigationTitle("接続")
    }
    private func settingRow(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(label); Text(value).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
    }
    private func healthRow(_ connected: Bool, ok: String, action: String, icon: String) -> some View {
        Label {
            Text(connected ? ok : action)
        } icon: {
            Image(systemName: icon).foregroundStyle(connected ? Color.green : Color.orange)
        }.accessibilityElement(children: .combine)
    }
    private func criteria(_ title: String, _ values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(title).font(.subheadline.bold()); ForEach(values, id: \.self) { Text("• " + $0).font(.caption) } }
    }
    private var voiceModels: [ConversationModel] { session.catalog?.live[session.settings.voice.rawValue] ?? [] }
    private var agentModels: [ConversationModel] { session.catalog?.providers.first(where: { $0.id == session.settings.agentProvider.rawValue })?.models ?? [] }
    private var modelStatus: String {
        if !session.modelMessage.isEmpty { return session.modelMessage }
        let provider = session.catalog?.providers.first { $0.id == session.settings.agentProvider.rawValue }
        return provider?.ready == false ? provider?.message ?? "モデル一覧を更新してください" : ""
    }
}
