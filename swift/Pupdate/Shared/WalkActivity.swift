import ActivityKit
import AppIntents
import Foundation

/// Shared between the app and the widget extension: what the Lock Screen / Dynamic Island shows.
struct WalkActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var state: String          // calm, checkin, nudge, final, countdown, alert
        var title: String
        var subtitle: String
        var deadline: Date?        // when the current stage times out (drives a self-ticking timer)
        var form: String           // sprout, strider, guardian
        var species: String        // chick, dog, cat, ...
        var xp: Int
        var progress: Double       // 0...1 along the route
        var metersLeft: Int
        var turnText: String? = nil     // next turn-by-turn instruction
        var turnSymbol: String? = nil   // SF Symbol for the maneuver
        var turnMeters: Int? = nil
        var happy: Bool? = nil          // just petted: the dog smiles (never shown during an alert)
    }

    var walkId: String? = nil       // for the Lock Screen Pet button
    var walkerName: String
    var buddyName: String
    var from: String
    var to: String
}

enum WalkStateStyle {
    static func isUrgent(_ s: String) -> Bool { ["final", "countdown", "alert"].contains(s) }
    static func needsTap(_ s: String) -> Bool { s != "calm" }
    static func spriteName(form: String, species: String = "dog") -> String {
        let pets = ["dog": "pet_dog", "cat": "pet_cat", "bunny": "pet_rabbit", "poodle": "pet_poodle", "hedgehog": "pet_hedgehog",
                    "chipmunk": "pet_chipmunk", "otter": "pet_otter", "seal": "pet_seal", "sloth": "pet_sloth",
                    "turtle": "pet_turtle", "penguin": "penguin"]
        if let p = pets[species] { return p }
        switch form { case "strider": return "front-facing_baby_chick"; case "guardian": return "owl"; default: return "hatching_chick" }
    }
    static func gearName(form: String, species: String) -> String? {
        guard species != "chick" else { return nil }
        switch form { case "strider": return "glowing_star"; case "guardian": return "crown"; default: return nil }
    }
    /// The dog's face on the Lock Screen / Dynamic Island for this update.
    static func dogMood(_ c: WalkActivityAttributes.ContentState) -> DogMood {
        (c.happy ?? false) && c.state != "alert" ? .happy : DogMood.from(walkState: c.state)
    }
    static func showsPet(_ c: WalkActivityAttributes.ContentState) -> Bool {
        !(c.happy ?? false) && ["checkin", "nudge", "final", "countdown"].contains(c.state)
    }
    static func badgeName(state: String) -> String? {
        switch state {
        case "checkin": return "red_question_mark"
        case "nudge", "final": return "sweat_droplets"
        case "countdown", "alert": return "red_exclamation_mark"
        default: return nil
        }
    }
}

/// "Pet" on the Lock Screen and in the Dynamic Island. Runs in the app's process.
/// The dog smiles right away, then the pet goes to the server exactly like a rub in the app.
/// During an alert it is only a late pet: friends are told, and the alert stays open.
struct PetBuddyIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Pet your buddy"

    @Parameter(title: "Walk") var walkId: String

    init() {}
    init(walkId: String) { self.walkId = walkId }

    func perform() async throws -> some IntentResult {
        for activity in Activity<WalkActivityAttributes>.activities where activity.attributes.walkId == walkId {
            var s = activity.content.state
            if s.state != "alert" {
                s.happy = true
                s.title = "Good \(activity.attributes.buddyName)!"
                s.subtitle = "Thanks for checking in."
                s.deadline = nil
            }
            await activity.update(ActivityContent(state: s, staleDate: nil))
        }
        let base = UserDefaults.standard.string(forKey: "wb.server")
            ?? (Bundle.main.object(forInfoDictionaryKey: "WBDefaultServer") as? String) ?? "http://localhost:8100"
        if let url = URL(string: base + "/walks/\(walkId)/pet") {
            var req = URLRequest(url: url, timeoutInterval: 8)
            req.httpMethod = "POST"
            _ = try? await URLSession.shared.data(for: req)
        }
        return .result()
    }
}
