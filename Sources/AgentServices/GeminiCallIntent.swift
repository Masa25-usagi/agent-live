import Foundation

public enum GeminiCallIntent: Equatable {
    case none, request, keepOpen, close
    public static func parse(_ text: String) -> Self {
        let value = text.folding(options: [.widthInsensitive, .caseInsensitive], locale: Locale(identifier: "ja-JP"))
            .lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // Examples and quoted words are observations, not call-control commands.
        if value.contains("「") || value.contains("\"") || ["って言", "と言っ", "という発言", "という例"].contains(where: value.contains) { return .none }
        if ["切らないで", "切らずに", "ずっとつないで", "ずっと繋いで", "接続を維持", "接続し続けて", "接続を続けて", "終わりと言うまで", "許可が下りるまで"].contains(where: value.contains) { return .keepOpen }
        if ["切ってはいけない", "切ってほしくない", "切って欲しくない", "切りたくない", "バイバイしない", "さようならは言わない"].contains(where: value.contains) { return .none }
        if ["バイバイ", "ばいばい", "さようなら", "さよなら", "切るね", "切っていいよ", "接続を切って", "通話を終了", "会話を終了", "電話を切る"].contains(where: value.contains) { return .close }
        if CompanionAddressing.requestsReply(value) { return .request }
        let pattern = #"^(?:(?:ねえ|ねぇ|もしもし)[\s、,。!?！？]*)?(?:ジェミニ|ジェミニー|gemini)(?=[\s、,。!?！？]|$|こんにちは|こんばんは|おはよう|教えて|聞いて|お願い|今日|今|返事)"#
        return value.range(of: pattern, options: .regularExpression) != nil ? .request : .none
    }
}
