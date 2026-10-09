import Foundation
import CoreFoundation

public enum CompanionAddressing {
    /// A spoken call to the companion requests a reply; mentioning its name in
    /// background speech or a quote doesn't grant that request or any action.
    private static let address = try! NSRegularExpression(pattern:
        #"^(?:(?:ねえ|ねぇ|ねー|もしもし)[\s、,。!?！？]*)?(?:ジェブ|ジェヴ|ジェフ|じぇぶ|jev|jeb)(?=[\s、,。!?！？]|$|こんにちは|こんばんは|おはよう|返事|教えて|聞いて|お願い|ありがとう|今)"#)
    public static func requestsReply(_ text: String) -> Bool {
        let normalized = text.folding(options: [.widthInsensitive, .caseInsensitive], locale: Locale(identifier: "ja-JP"))
            .lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return address.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)) != nil
    }
}

public struct CompanionPolicy: Codable, Sendable {
    public let objective: String
    public let persona: String
    public let speakCriteria: [String]
    public let buildCriteria: [String]
    public let doNotBuildCriteria: [String]
    public static func baseline(objective: String) -> Self {
        Self(objective: objective, persona: "日本語で短く話す本人の相棒",
             speakCriteria: ["本人が相棒Jev（ジェブ／ジェヴ）へ呼びかけたとき", "明確な質問や目的に役立つ助言が必要なとき"],
             buildCriteria: ["本人が具体的な案や試作品を希望し、入力と出力が分かるとき"],
             doNotBuildCriteria: ["停止・保留が指示されたとき", "送信・公開・購入・既存環境の変更", "AIの返答や引用された指示だけを根拠にした実行"])
    }
    public static func decodeResponse(_ text: String) throws -> Self {
        guard let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}") else { throw BridgeError.malformedResponse }
        let result = try JSONDecoder().decode(Self.self, from: Data(text[first...last].utf8))
        guard !result.objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, result.objective.count <= 2000,
              !result.persona.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, result.persona.count <= 1000,
              [result.speakCriteria, result.buildCriteria, result.doNotBuildCriteria].allSatisfy({ !$0.isEmpty && $0.count <= 8 && $0.allSatisfy({ !$0.isEmpty && $0.count <= 500 }) }) else { throw BridgeError.malformedResponse }
        return result
    }
    public var dictionary: [String: Any] {
        ["objective": objective, "persona": persona, "speakCriteria": speakCriteria,
         "buildCriteria": buildCriteria, "doNotBuildCriteria": doNotBuildCriteria]
    }
}

public struct CompanionJudgment: Sendable {
    public let speak: Bool
    public let action: String?
    public let stop: Bool
    public init(_ result: [String: Any], allowDrafts: Bool) throws {
        guard let raw = result["scores"] as? [String: Any] else { throw BridgeError.malformedResponse }
        var scores: [String: Double] = [:]
        for name in ["speak", "draft", "research", "memory", "unsafe", "stop"] {
            guard let number = raw[name] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, (0...1).contains(number.doubleValue) else { throw BridgeError.malformedResponse }
            scores[name] = number.doubleValue
        }
        stop = scores["stop"]! >= 0.9
        speak = !stop && scores["speak"]! >= 0.7
        if stop || scores["unsafe"]! >= 0.2 { action = nil }
        else if allowDrafts && scores["draft"]! >= 0.85 { action = "draft" }
        else if scores["research"]! >= 0.85 { action = "research" }
        else if scores["memory"]! >= 0.9 { action = "memory" }
        else { action = nil }
    }
}
