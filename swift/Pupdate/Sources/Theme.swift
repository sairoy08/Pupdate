import SwiftUI
import UIKit

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255, opacity: alpha)
    }
}

enum Palette {
    // Neutral graphite, no blue-purple tint. One accent (amber) for XP and the primary action;
    // green / amber / red only where they mean state.
    static let bg = Color(hex: 0x0c0c0d)
    static let bg2 = Color(hex: 0x0c0c0d)
    static let card = Color(hex: 0x171719)
    static let card2 = Color(hex: 0x1f1f22)
    static let line = Color(hex: 0x2c2c30)
    static let lineTop = Color(hex: 0x2c2c30)
    static let text = Color(hex: 0xf4f4f2)
    static let muted = Color(hex: 0x9b9ba1)
    static let gold = Color(hex: 0xf2b134)
    static let goldDeep = Color(hex: 0xf2b134)
    static let ok = Color(hex: 0x34c77b)
    static let okDeep = Color(hex: 0x34c77b)
    static let warn = Color(hex: 0xf2b134)
    static let alert = Color(hex: 0xff4f4a)
    static let alertDeep = Color(hex: 0xff4f4a)
    static let ink = Color(hex: 0x111111)
    static let sky = Color(hex: 0x7fb2ff)
}

/// Fonts scale with the iPhone's text size (Dynamic Type) and with Settings > Text size.
enum Typeface {
    static var scale: CGFloat { CGFloat(UserDefaults.standard.object(forKey: "wb.textScale") as? Double ?? 1.0) }
    private static func f(_ name: String, _ size: CGFloat, _ style: Font.TextStyle) -> Font {
        .custom(name, size: size * scale, relativeTo: style)
    }
    static func display(_ size: CGFloat) -> Font { f("BricolageGrotesque-ExtraBold", size, .title) }
    static func displayBold(_ size: CGFloat) -> Font { f("BricolageGrotesque-Bold", size, .title3) }
    static func body(_ size: CGFloat = 16) -> Font { f("Figtree-Medium", size, .body) }
    static func semi(_ size: CGFloat = 16) -> Font { f("Figtree-SemiBold", size, .body) }
    static func bold(_ size: CGFloat = 16) -> Font { f("Figtree-Bold", size, .body) }
}

/// Motion is reduced when the iPhone setting is on or when chosen in Settings.
enum Motion {
    static var reduced: Bool {
        UIAccessibility.isReduceMotionEnabled || (UserDefaults.standard.object(forKey: "wb.reduceMotion") as? Bool ?? false)
    }
}

/// 3D sprites from Microsoft Fluent Emoji (MIT). See Resources/Sprites/FLUENT_EMOJI_LICENSE.txt.
enum Sprite: String {
    case hatchling = "hatching_chick", chick = "front-facing_baby_chick", owl
    case question = "red_question_mark", exclaim = "red_exclamation_mark", sparkles, sweat = "sweat_droplets"
    case fire, gem = "gem_stone", shield, footprints, house, bell, trophy, star = "glowing_star", crown
    case compass, books, pin = "round_pushpin"
    case dog = "pet_dog", cat = "pet_cat", bunny = "pet_rabbit", poodle = "pet_poodle", hedgehog = "pet_hedgehog"
    case chipmunk = "pet_chipmunk", otter = "pet_otter", seal = "pet_seal", sloth = "pet_sloth", turtle = "pet_turtle", penguin

    var image: Image {
        if let ui = UIImage(named: rawValue) ?? Bundle.main.path(forResource: rawValue, ofType: "png").flatMap(UIImage.init(contentsOfFile:)) {
            return Image(uiImage: ui)
        }
        return Image(systemName: "questionmark.circle")
    }
}

extension Sprite {
    /// UI icons are SF Symbols; only the pets themselves stay as pictures.
    var symbol: String? {
        switch self {
        case .fire: return "flame.fill"
        case .gem: return "bolt.fill"
        case .star: return "star.fill"
        case .trophy: return "trophy.fill"
        case .shield: return "shield.lefthalf.filled"
        case .house: return "house.fill"
        case .books: return "books.vertical.fill"
        case .pin: return "mappin.and.ellipse"
        case .bell: return "bell.fill"
        case .sparkles: return "sparkles"
        case .question: return "questionmark"
        case .sweat: return "drop.fill"
        case .exclaim: return "exclamationmark"
        case .compass: return "location.north.line.fill"
        default: return nil
        }
    }
    var tint: Color {
        switch self {
        case .fire, .gem, .trophy, .star, .sparkles: return Palette.gold
        case .exclaim, .bell: return Palette.alert
        case .question, .sweat: return Palette.sky
        default: return Palette.text
        }
    }
}

/// An icon: the SF Symbol for UI sprites, the picture for pets.
struct SpriteIcon: View {
    let sprite: Sprite
    var size: CGFloat = 22
    var tint: Color?
    init(_ sprite: Sprite, size: CGFloat = 22, tint: Color? = nil) { self.sprite = sprite; self.size = size; self.tint = tint }
    var body: some View {
        if let sym = sprite.symbol {
            Image(systemName: sym)
                .font(.system(size: size * 0.7, weight: .semibold))
                .foregroundStyle(tint ?? sprite.tint)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            sprite.image.resizable().scaledToFit().frame(width: size, height: size)
        }
    }
}

enum Mood { case calm, asking, worried, alarmed, happy }

struct StateCopy { let title: String; let sub: String; let mood: Mood }

let STATE_COPY: [String: StateCopy] = [
    "calm": .init(title: "Walking together", sub: "{name} is keeping an eye out.", mood: .calm),
    "checkin": .init(title: "Still good?", sub: "Pet {name} to say you're OK.", mood: .asking),
    "nudge": .init(title: "Hey, you there?", sub: "Pet {name} now.", mood: .worried),
    "final": .init(title: "Last chance", sub: "Your friends get an alert soon.", mood: .worried),
    "countdown": .init(title: "Alerting friends", sub: "Pet {name} to cancel.", mood: .alarmed),
    "alert": .init(title: "Friends alerted", sub: "Pet {name} to tell them you're OK.", mood: .alarmed),
]

/// State copy with the buddy's real name filled in.
func stateCopy(_ state: String, name: String) -> StateCopy {
    let c = STATE_COPY[state] ?? STATE_COPY["calm"]!
    return StateCopy(title: c.title, sub: c.sub.replacingOccurrences(of: "{name}", with: name), mood: c.mood)
}

struct Species: Identifiable, Hashable {
    let id: String
    let name: String
    let sprite: Sprite
}

/// Pets you can pick. The pup is the main one (drawn and animated); every other pet keeps its
/// look and earns gear instead: a star at Explorer, a crown at Guardian. No chick.
let SPECIES: [Species] = [
    .init(id: "dog", name: "Pup", sprite: .dog),  // the main pet, first and the default
    .init(id: "cat", name: "Kitty", sprite: .cat), .init(id: "bunny", name: "Bunny", sprite: .bunny),
    .init(id: "poodle", name: "Poodle", sprite: .poodle), .init(id: "hedgehog", name: "Hedgehog", sprite: .hedgehog),
    .init(id: "chipmunk", name: "Chipmunk", sprite: .chipmunk), .init(id: "otter", name: "Otter", sprite: .otter),
    .init(id: "seal", name: "Seal", sprite: .seal), .init(id: "sloth", name: "Sloth", sprite: .sloth),
    .init(id: "turtle", name: "Turtle", sprite: .turtle), .init(id: "penguin", name: "Penguin", sprite: .penguin),
]

func petSprite(_ species: String?, _ form: String) -> Sprite {
    let sp = species ?? "dog"
    if sp == "chick" {
        switch form { case "strider": return .chick; case "guardian": return .owl; default: return .hatchling }
    }
    return SPECIES.first { $0.id == sp }?.sprite ?? .hatchling
}

/// The dog is drawn as an animated vector (DogView) with its own evolution gear,
/// so it doesn't use a sprite or the star/crown overlay.
let VECTOR_SPECIES: Set<String> = ["dog"]

/// A pet picture anywhere in the app: the animated dog for "dog", the sprite for everyone else.
struct PetImage: View {
    let species: String?
    let form: String
    var mood: Mood = .calm
    var size: CGFloat
    var animated = false

    var body: some View {
        if VECTOR_SPECIES.contains(species ?? "") {
            DogView(form: form, mood: dogMood(mood), size: size, animated: animated && !Motion.reduced)
        } else {
            petSprite(species, form).image.resizable().scaledToFit().frame(width: size, height: size)
        }
    }
}

func dogMood(_ m: Mood) -> DogMood {
    switch m {
    case .calm: return .calm
    case .asking: return .asking
    case .worried: return .worried
    case .alarmed: return .alarmed
    case .happy: return .happy
    }
}

/// Old call sites: chick line by form.
func formSprite(_ form: String) -> Sprite { petSprite("chick", form) }

func formName(_ form: String, species: String? = "dog") -> String {
    if (species ?? "dog") == "chick" {
        switch form { case "strider": return "Chick"; case "guardian": return "Night Owl"; default: return "Hatchling" }
    }
    if species == "dog" {
        switch form { case "strider": return "Scout Pup"; case "guardian": return "Guardian Dog"; default: return "Puppy" }
    }
    switch form { case "strider": return "Explorer"; case "guardian": return "Guardian"; default: return "Baby" }
}

/// Gear a non-chick pet wears at each stage.
func petGear(_ species: String?, _ form: String) -> Sprite? {
    guard (species ?? "dog") != "chick", !VECTOR_SPECIES.contains(species ?? "") else { return nil }
    switch form { case "strider": return .star; case "guardian": return .crown; default: return nil }
}

func level(_ xp: Int) -> Int { xp / 25 + 1 }

enum Haptics {
    private static var on: Bool { UserDefaults.standard.object(forKey: "wb.haptics") as? Bool ?? true }
    static func tap() { if on { UIImpactFeedbackGenerator(style: .medium).impactOccurred() } }
    static func success() { if on { UINotificationFeedbackGenerator().notificationOccurred(.success) } }
    static func warning() { if on { UINotificationFeedbackGenerator().notificationOccurred(.warning) } }
}
