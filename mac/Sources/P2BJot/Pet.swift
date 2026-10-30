import AppKit
import SwiftUI

// Idea2do's pet (Desktop/Pet/PetState.swift, PetView.swift), drawn in code with no image assets. Edge docking is left out.

enum PetLayout {
    /// Wide enough that a speech bubble fits above the body.
    static let panelSize = NSSize(width: 180, height: 112)
    /// Body center inside the panel, AppKit coordinates (origin bottom left).
    static let bodyCenter = NSPoint(x: 90, y: 40)
    static let bodySize = CGSize(width: 58, height: 52)
    static let hitRadius: CGFloat = 34
}

enum PetActivity: Equatable { case idle, saving, processing }

enum PetReaction: Equatable {
    case hop, land, happy, gulp, reject
    case worried(String)

    var bubble: String? {
        switch self {
        case .happy: return "已保存"
        case .gulp: return "放进草稿了"
        case .reject: return "收不了这个"
        case let .worried(text): return text
        case .hop, .land: return nil
        }
    }
}

enum PetEyes: Equatable { case open, wide, focus, happy, closed, blink, worried }
enum PetMouth: Equatable { case smile, bigSmile, open, flat, wavy }

struct PetFace: Equatable {
    var eyes: PetEyes
    var mouth: PetMouth
    var blush: Bool

    /// Transient reactions outrank ongoing work, which outranks passive states, so feedback is never hidden.
    static func make(activity: PetActivity, reaction: PetReaction?, sleeping: Bool, hovering: Bool,
                     pressed: Bool, dropTargeted: Bool, blinking: Bool) -> PetFace {
        var face: PetFace
        switch reaction {
        case .reject?, .worried?: face = PetFace(eyes: .worried, mouth: .wavy, blush: false)
        case .happy?, .gulp?: face = PetFace(eyes: .happy, mouth: .bigSmile, blush: true)
        default:
            if dropTargeted { face = PetFace(eyes: .wide, mouth: .open, blush: true) }
            else if activity == .saving { face = PetFace(eyes: .focus, mouth: .flat, blush: false) }
            else if activity == .processing { face = PetFace(eyes: .focus, mouth: .smile, blush: false) }
            else if sleeping { face = PetFace(eyes: .closed, mouth: .flat, blush: false) }
            else if pressed { face = PetFace(eyes: .happy, mouth: .open, blush: true) }
            else if hovering { face = PetFace(eyes: .wide, mouth: .bigSmile, blush: true) }
            else { face = PetFace(eyes: .open, mouth: .smile, blush: false) }
        }
        if blinking, face.eyes == .open || face.eyes == .wide || face.eyes == .focus { face.eyes = .blink }
        return face
    }
}

@MainActor
final class PetState: ObservableObject {
    @Published var activity: PetActivity = .idle
    @Published var reaction: PetReaction?
    @Published var hasDraft = false
    @Published var failedCount = 0
    @Published var hasPendingSuggestions = false
    /// A card or the input bubble is attached; the pet's own speech bubble would overlap it.
    @Published var cardShowing = false
    @Published var sleeping = false
    @Published var hovering = false
    @Published var pressed = false
    @Published var dragging = false
    @Published var dropTargeted = false
    @Published var blinking = false
    @Published var dragTilt: Double = 0
    @Published var shakePhase = 0
    @Published var sproutKick = Date.distantPast
    @Published var sproutKickStrength = 0.0
    @Published var animating = true
    /// Unit-ish gaze direction in SwiftUI orientation (y grows downward).
    @Published var gaze = CGVector.zero
    @Published var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    var face: PetFace {
        PetFace.make(activity: activity, reaction: reaction, sleeping: sleeping, hovering: hovering,
                     pressed: pressed, dropTargeted: dropTargeted, blinking: blinking)
    }
}

private enum Palette {
    static let bodyTop = Color(red: 0.24, green: 0.62, blue: 0.56)
    static let bodyBottom = Color(red: 0.11, green: 0.41, blue: 0.38)
    static let leaf = Color(red: 0.58, green: 0.84, blue: 0.46)
    static let stem = Color(red: 0.40, green: 0.70, blue: 0.36)
    static let cheek = Color(red: 1.0, green: 0.52, blue: 0.60)
    static let alert = Color(red: 0.93, green: 0.36, blue: 0.27)
}

struct PetView: View {
    @ObservedObject var state: PetState

    private struct Pose: Equatable {
        var scaleX: CGFloat = 1, scaleY: CGFloat = 1, tilt: Double = 0, lift: CGFloat = 0
    }

    private var pose: Pose {
        guard !state.reduceMotion else { return Pose() }
        var pose = Pose()
        if state.hovering || state.dropTargeted { pose.scaleX = 1.05; pose.scaleY = 1.05 }
        if state.pressed { pose.scaleX = 1.08; pose.scaleY = 0.88 }
        switch state.reaction {
        case .hop?: pose.lift = -10; pose.scaleX = 0.95; pose.scaleY = 1.07
        case .land?: pose.scaleX = 1.12; pose.scaleY = 0.85
        case .happy?, .gulp?: pose.lift = -5
        default: break
        }
        if state.dragging { pose.scaleX = 0.94; pose.scaleY = 1.07; pose.tilt = state.dragTilt }
        pose.tilt += [0, -10, 10, -7, 7, -3, 0][min(state.shakePhase, 6)]
        return pose
    }

    var body: some View {
        let pose = pose
        let face = state.face
        ZStack {
            Ellipse()
                .fill(Color.black.opacity(pose.lift < 0 ? 0.10 : 0.17))
                .frame(width: pose.lift < 0 ? 34 : 44, height: 6)
                .blur(radius: 1.5)
                .position(x: centerX, y: 100)

            creature(face)
                .frame(width: 70, height: 70)
                .scaleEffect(x: pose.scaleX, y: pose.scaleY, anchor: .bottom)
                .rotationEffect(.degrees(pose.tilt), anchor: .bottom)
                .offset(y: pose.lift)
                .position(x: centerX, y: 63)

            if state.sleeping, state.reaction == nil {
                sleepMarks.position(x: centerX + 34, y: 30).transition(.opacity)
            }
            if let text = state.reaction?.bubble, !state.cardShowing {
                bubble(text).position(x: PetLayout.panelSize.width / 2, y: 15)
                    .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
            }
        }
        .frame(width: PetLayout.panelSize.width, height: PetLayout.panelSize.height)
        .animation(state.reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.52), value: pose)
        .animation(.easeOut(duration: 0.18), value: state.reaction)
        .animation(.easeOut(duration: 0.25), value: state.sleeping)
        .accessibilityHidden(true)
    }

    private var centerX: CGFloat { PetLayout.bodyCenter.x }

    private func creature(_ face: PetFace) -> some View {
        ZStack {
            sprout.position(x: 35, y: 12)
            MochiShape()
                .fill(LinearGradient(colors: [Palette.bodyTop, Palette.bodyBottom], startPoint: .top, endPoint: .bottom))
                .overlay(
                    Ellipse().fill(Color.white.opacity(0.22))
                        .frame(width: 16, height: 9).rotationEffect(.degrees(-24))
                        .offset(x: -14, y: -14)
                )
                .shadow(color: .black.opacity(0.16), radius: 3, y: 2)
                .frame(width: PetLayout.bodySize.width, height: PetLayout.bodySize.height)
                .position(x: 35, y: 44)

            HStack(spacing: 13) { EyeView(eyes: face.eyes, mirrored: false); EyeView(eyes: face.eyes, mirrored: true) }
                .offset(x: state.gaze.dx * 3, y: state.gaze.dy * 2)
                .animation(.easeOut(duration: 0.12), value: state.gaze)
                .position(x: 35, y: 41)

            HStack(spacing: 25) { Ellipse().fill(Palette.cheek); Ellipse().fill(Palette.cheek) }
                .frame(width: 43, height: 5)
                .opacity(face.blush ? 0.8 : 0)
                .position(x: 35 + state.gaze.dx, y: 49)

            MouthView(mouth: face.mouth)
                .offset(x: state.gaze.dx * 2)
                .position(x: 35, y: 53)

            if state.hasDraft { note.position(x: 60, y: 58).transition(.scale.combined(with: .opacity)) }
            if state.hasPendingSuggestions { question.position(x: 9, y: 50).transition(.scale.combined(with: .opacity)) }
            if state.failedCount > 0 {
                Circle().fill(Palette.alert)
                    .overlay(Text("!").font(.system(size: 8, weight: .heavy)).foregroundStyle(.white))
                    .frame(width: 11, height: 11)
                    .overlay(Circle().stroke(Color.white, lineWidth: 1.2))
                    .position(x: 60, y: 23)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: state.hasDraft)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: state.hasPendingSuggestions)
    }

    /// Only the sprout redraws continuously, capped at 30 fps and paused whenever the pet is not animating.
    private var sprout: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !state.animating)) { context in
            let motion = sproutMotion(at: context.date.timeIntervalSinceReferenceDate, date: context.date)
            ZStack(alignment: .bottom) {
                Capsule().fill(Palette.stem).frame(width: 2.4, height: 10)
                Ellipse().fill(Palette.leaf).frame(width: 10, height: 5.5)
                    .rotationEffect(.degrees(-28 - motion.flutter), anchor: .trailing).offset(x: -5, y: -8)
                Ellipse().fill(Palette.leaf).frame(width: 11, height: 6)
                    .rotationEffect(.degrees(24 + motion.flutter), anchor: .leading).offset(x: 5.5, y: -9)
            }
            .frame(width: 24, height: 18, alignment: .bottom)
            .rotationEffect(.degrees(motion.angle), anchor: .bottom)
        }
    }

    private struct SproutMotion { var angle: Double, flutter: Double }

    /// Accumulates phase and eases amplitude, so a change of tempo never makes the sprout jump.
    private final class SproutClock {
        var last: Double?
        var phase = 0.0, amplitude = 7.0, lean = 0.0

        func advance(to t: Double, period: Double, amplitude target: Double, lean targetLean: Double) {
            let dt = last.map { min(max(t - $0, 0), 0.1) } ?? 0
            last = t
            phase += dt * 2 * .pi / period
            let ease = min(1, dt * 5)
            amplitude += (target - amplitude) * ease
            lean += (targetLean - lean) * ease
        }
    }

    @State private var clock = SproutClock()

    /// A steady sway whose tempo follows the mood, plus a decaying spring from the latest flick and drag inertia.
    private func sproutMotion(at t: Double, date: Date) -> SproutMotion {
        let (period, amplitude, lean): (Double, Double, Double)
        if state.sleeping { (period, amplitude, lean) = (4.2, 4, 16) }
        else if state.activity == .processing { (period, amplitude, lean) = (0.55, 14, 0) }
        else if state.hovering || state.dropTargeted { (period, amplitude, lean) = (0.9, 10, 0) }
        else { (period, amplitude, lean) = (2.4, 7, 0) }
        clock.advance(to: t, period: period, amplitude: amplitude, lean: lean)
        var angle = clock.lean + clock.amplitude * sin(clock.phase)
        var flutter = (state.sleeping ? 2 : 5) * sin(clock.phase * 2 + 0.8)
        let elapsed = date.timeIntervalSince(state.sproutKick)
        if elapsed >= 0, elapsed < 1.6 {
            let spring = exp(-elapsed * 3.2) * sin(elapsed * 17)
            angle += 28 * state.sproutKickStrength * spring
            flutter += 12 * state.sproutKickStrength * spring
        }
        if state.dragging { angle -= state.dragTilt * 1.4 }
        return SproutMotion(angle: angle, flutter: flutter)
    }

    private var note: some View {
        RoundedRectangle(cornerRadius: 1.5).fill(Color.white)
            .frame(width: 11, height: 13)
            .overlay(VStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { _ in Capsule().fill(Palette.bodyBottom.opacity(0.45)).frame(width: 6, height: 1) }
            })
            .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
            .rotationEffect(.degrees(14))
    }

    /// Something waits for the user's decision; shown without a count so it never nags.
    private var question: some View {
        RoundedRectangle(cornerRadius: 2).fill(Color.white)
            .frame(width: 11, height: 13)
            .overlay(Text("?").font(.system(size: 9, weight: .heavy, design: .rounded)).foregroundStyle(Palette.bodyBottom))
            .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
            .rotationEffect(.degrees(-14))
    }

    private var sleepMarks: some View {
        ZStack {
            Text("z").font(.system(size: 9, weight: .bold, design: .rounded)).offset(x: -6, y: 6)
            Text("z").font(.system(size: 12, weight: .bold, design: .rounded)).offset(x: 3, y: -4)
        }
        .foregroundStyle(Palette.bodyBottom.opacity(0.75))
    }

    private func bubble(_ text: String) -> some View {
        HStack(spacing: 3) {
            if state.reaction == .happy || state.reaction == .gulp {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.bodyBottom)
            }
            Text(text).font(.system(size: 11, weight: .medium)).lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)).shadow(color: .black.opacity(0.18), radius: 2, y: 1))
        .foregroundStyle(.primary)
    }
}

/// Rounded top, softly flattened bottom, like a rice cake sitting on the desk.
private struct MochiShape: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        var p = Path()
        p.move(to: CGPoint(x: r.minX + w * 0.5, y: r.minY))
        p.addCurve(to: CGPoint(x: r.maxX, y: r.minY + h * 0.62),
                   control1: CGPoint(x: r.minX + w * 0.88, y: r.minY), control2: CGPoint(x: r.maxX, y: r.minY + h * 0.26))
        p.addCurve(to: CGPoint(x: r.minX + w * 0.5, y: r.maxY),
                   control1: CGPoint(x: r.maxX, y: r.minY + h * 0.92), control2: CGPoint(x: r.minX + w * 0.8, y: r.maxY))
        p.addCurve(to: CGPoint(x: r.minX, y: r.minY + h * 0.62),
                   control1: CGPoint(x: r.minX + w * 0.2, y: r.maxY), control2: CGPoint(x: r.minX, y: r.minY + h * 0.92))
        p.addCurve(to: CGPoint(x: r.minX + w * 0.5, y: r.minY),
                   control1: CGPoint(x: r.minX, y: r.minY + h * 0.26), control2: CGPoint(x: r.minX + w * 0.12, y: r.minY))
        p.closeSubpath()
        return p
    }
}

private struct ArcShape: Shape {
    /// Positive bends downward (smile), negative bends upward (happy eye).
    var bend: CGFloat
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.midY), control: CGPoint(x: r.midX, y: r.midY + bend))
        return p
    }
}

private struct EyeView: View {
    let eyes: PetEyes
    let mirrored: Bool

    var body: some View {
        ZStack {
            switch eyes {
            case .open: Capsule().fill(Color.white).frame(width: 6, height: 9)
            case .wide: Capsule().fill(Color.white).frame(width: 7, height: 11)
            case .focus: Capsule().fill(Color.white).frame(width: 6, height: 6)
            case .blink: Capsule().fill(Color.white).frame(width: 7, height: 1.8)
            case .happy: ArcShape(bend: -6).stroke(Color.white, style: StrokeStyle(lineWidth: 2.2, lineCap: .round)).frame(width: 8, height: 6)
            case .closed: ArcShape(bend: 4).stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round)).frame(width: 8, height: 4)
            case .worried:
                VStack(spacing: 1.5) {
                    Capsule().fill(Color.white).frame(width: 7, height: 1.6).rotationEffect(.degrees(mirrored ? 18 : -18))
                    Capsule().fill(Color.white).frame(width: 5.5, height: 7.5)
                }
            }
        }
        .frame(width: 9, height: 12)
    }
}

private struct MouthView: View {
    let mouth: PetMouth

    var body: some View {
        ZStack {
            switch mouth {
            case .smile: ArcShape(bend: 4).stroke(Color.white, style: StrokeStyle(lineWidth: 1.8, lineCap: .round)).frame(width: 9, height: 4)
            case .bigSmile:
                ArcShape(bend: 7).fill(Color(red: 0.07, green: 0.28, blue: 0.26))
                    .overlay(ArcShape(bend: 7).stroke(Color.white, style: StrokeStyle(lineWidth: 1.6, lineCap: .round)))
                    .frame(width: 11, height: 5)
            case .open: Ellipse().stroke(Color.white, lineWidth: 1.6).frame(width: 5, height: 6)
            case .flat: Capsule().fill(Color.white).frame(width: 7, height: 1.8)
            case .wavy:
                Path { p in
                    p.move(to: CGPoint(x: 0, y: 3)); p.addLine(to: CGPoint(x: 2.5, y: 1))
                    p.addLine(to: CGPoint(x: 5, y: 3)); p.addLine(to: CGPoint(x: 7.5, y: 1)); p.addLine(to: CGPoint(x: 10, y: 3))
                }
                .stroke(Color.white, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .frame(width: 10, height: 4)
            }
        }
        .frame(width: 12, height: 8)
    }
}
