import AudioToolbox
import AVFoundation
import UIKit
import UserNotifications

/// Sound, speech and vibration, each switchable in Settings > Accessibility.
enum Feedback {
    private static let voice = AVSpeechSynthesizer()
    private static func flag(_ key: String, _ def: Bool) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? def }

    static var speakOn: Bool { flag("wb.speak", false) }
    static var soundsOn: Bool { flag("wb.sounds", true) }
    static var strongVibration: Bool { flag("wb.strongVibe", true) }

    /// Read text aloud (spoken prompts). Ducks other audio briefly.
    static func speak(_ text: String) {
        guard speakOn, !text.isEmpty else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers, .mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        voice.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: text)
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        voice.speak(u)
    }

    static func checkInChime() {
        if soundsOn { AudioServicesPlaySystemSound(1007) }
        Haptics.warning()
    }

    static func alertSound() {
        if soundsOn { AudioServicesPlaySystemSound(1005) }
        if strongVibration { AudioServicesPlaySystemSound(kSystemSoundID_Vibrate) } else { Haptics.warning() }
    }

    static func petted() {
        if soundsOn { AudioServicesPlaySystemSound(1104) }
        Haptics.success()
    }
}

/// Local notifications for when the app is in the background. There is no push (APNs needs a paid account),
/// so these only fire while iOS keeps the app running: reliably on the walker's phone during a walk
/// (background location), and only briefly on a friend's phone after they leave the app.
@MainActor
enum Notify {
    static func ask() {
        // UI tests launch with -wb.role; a permission dialog there would cover the screen under test.
        guard !ProcessInfo.processInfo.arguments.contains("-wb.role") else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Posting again with the same id replaces the earlier banner.
    static func post(_ id: String, title: String, body: String = "") {
        guard UIApplication.shared.applicationState != .active else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    static func clear(_ id: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    }
}
