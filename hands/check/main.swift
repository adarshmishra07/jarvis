// Runs companion/src/never.cases.json against hands/rules.swift: the Swift matching must agree with the companion's.
import Foundation

struct Failure: Error { let message: String }
let root = CommandLine.arguments[1]
let rules = try Rules(json: Data(contentsOf: URL(fileURLWithPath: root + "/companion/src/never.json")))
let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: root + "/companion/src/never.cases.json"))) as! [String: Any]
var bad: [String] = []
for (kind, list) in cases["refused"] as! [String: [String]] { for t in list where rules.never(t) != kind { bad.append("\(t) should be \(kind), got \(rules.never(t) ?? "nil")") } }
for t in cases["allowed"] as! [String] where rules.never(t) != nil { bad.append("\(t) should be allowed") }
let p = cases["personal"] as! [String: [String]], s = cases["sites"] as! [String: [String]]
for t in p["refused"]! where !rules.personal(t) { bad.append("\(t) should be personal") }
for t in p["allowed"]! where rules.personal(t) { bad.append("\(t) should not be personal") }
for u in s["refused"]! where !rules.moneySite(URL(string: u)!) { bad.append("\(u) should be a money site") }
for u in s["allowed"]! where rules.moneySite(URL(string: u)!) { bad.append("\(u) should not be a money site") }
if bad.isEmpty { print("hands rules: all cases agree") } else { bad.forEach { print("FAIL", $0) }; exit(1) }
