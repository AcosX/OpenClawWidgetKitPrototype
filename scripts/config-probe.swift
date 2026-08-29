import Foundation

let exampleURL = URL(fileURLWithPath: CommandLine.arguments[1])
let example = try JSONDecoder().decode(OpenClawWidgetConfiguration.self, from: Data(contentsOf: exampleURL))
precondition(example.schemaVersion == 1)
precondition(example.accounts.first?.name == "primary")
precondition(example.adminBaseURL?.contains("your-sub2api") == true)

let legacy = Data("""
{"adminBaseURL":"http://legacy.invalid","adminToken":"legacy-token","widgetURL":"http://widget.invalid","bridgeBaseURL":"http://bridge.invalid","bridgeToken":"bridge-token","accounts":[{"name":"Legacy","accountID":7}]}
""".utf8)
let mapped = try JSONDecoder().decode(OpenClawWidgetConfiguration.self, from: legacy)
precondition(mapped.schemaVersion == 0)
precondition(mapped.adminBaseURL == "http://legacy.invalid")
precondition(mapped.widgetURL == "http://widget.invalid")
precondition(mapped.accounts.first?.accountID == 7)
print("config example and legacy mapping: OK")
