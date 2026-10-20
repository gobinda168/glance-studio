import GlanceCore
import GlanceKit
import SwiftUI

/// First Light's stage: `FirstLightScene` (GlanceCore) works out the frame, `FirstLight.metal` shades it. The pointer
/// is the scene's light, and leans the dial a little; the voice's level makes the orb ripple. The clock stops when the
/// window is off screen, and under Reduce Motion the scene is the finished mark.
struct FirstLightView: View {
    let scene: FirstLightScene
    /// When the window appeared: the scene's time zero.
    let epoch: Date
    /// The voice's loudness now, 0…1.
    let level: () -> Double

    @Environment(\.colorScheme) private var colorScheme
    @State private var pointer: CGPoint?
    @State private var onScreen = true
    @State private var smoothing = Smoothing()

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(paused: !onScreen)) { context in
                let t = context.date.timeIntervalSince(epoch)
                let size = geometry.size
                let target = pointer.map {
                    (x: Double(($0.x - size.width / 2) / max(size.width / 2, 1)),
                     y: Double(($0.y - size.height / 2) / max(size.height / 2, 1)))
                }
                let smoothed = smoothing.step(pointer: target, level: level(), at: t)
                let frame = scene.frame(at: t, width: size.width, height: size.height, pointer: smoothed.pointer,
                                        level: smoothed.level)
                if Self.hasShader {
                    Rectangle()
                        .fill(.black)
                        .colorEffect(shader(frame, size: size, pointer: smoothed.pointer))
                } else {
                    Fallback(frame: frame, dark: colorScheme == .dark)
                }
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let location): pointer = location
            case .ended: pointer = nil
            }
        }
        .background(OnScreenReader { onScreen = $0 })
        .accessibilityHidden(true)
    }

    private func shader(_ frame: FirstLightFrame, size: CGSize, pointer: (x: Double, y: Double)?) -> Shader {
        let orb = frame.orb
        // The light sits up and to the right, where the mark's highlight is; the pointer pulls it round.
        let light = (x: 0.33 + (pointer?.x ?? 0) * 0.65, y: -0.39 + (pointer?.y ?? 0) * 0.65)
        return ShaderLibrary.default.firstLight(
            .float2(size),
            .float(Float(frame.time)),
            .float4(Float(orb.center.x), Float(orb.center.y), Float(orb.radius), Float(orb.glow)),
            .float4(Float(orb.palette.mid.r), Float(orb.palette.mid.g), Float(orb.palette.mid.b), Float(orb.scan)),
            .float4(Float(orb.palette.hi.r), Float(orb.palette.hi.g), Float(orb.palette.hi.b), Float(orb.ripple)),
            .float4(Float(orb.palette.lo.r), Float(orb.palette.lo.g), Float(orb.palette.lo.b), Float(frame.flare)),
            .float4(colorScheme == .dark ? 1 : 0, Float(light.x), Float(light.y), Float(orb.opacity)),
            .floatArray(frame.packedTicks),
            .floatArray(frame.packedSpheres))
    }

    /// The app's Metal library (FirstLight.metal compiled into `default.metallib`).
    static let hasShader = Bundle.main.url(forResource: "default", withExtension: "metallib") != nil

    /// Eases the pointer and the voice level frame to frame, so the light glides rather than jumps.
    final class Smoothing {
        private var pointer: (x: Double, y: Double) = (0, 0)
        private var level = 0.0
        private var last: Double?

        func step(pointer target: (x: Double, y: Double)?, level input: Double, at t: Double)
            -> (pointer: (x: Double, y: Double), level: Double) {
            let dt = min(max(t - (last ?? t), 0), 0.1)
            last = t
            let follow = 1 - exp(-dt * 5)
            let goal = target ?? (0, 0)
            pointer = (pointer.x + (goal.x - pointer.x) * follow, pointer.y + (goal.y - pointer.y) * follow)
            // The level rises fast and falls slowly, like a meter.
            level += (input - level) * (1 - exp(-dt * (input > level ? 30 : 8)))
            return (pointer, level)
        }
    }

    /// Without the shader: the mark drawn flat, so onboarding still works.
    private struct Fallback: View {
        let frame: FirstLightFrame
        let dark: Bool

        var body: some View {
            Canvas { context, _ in
                for tick in frame.ticks where tick.alpha > 0 {
                    var path = Path()
                    path.move(to: CGPoint(x: tick.a.x, y: tick.a.y))
                    path.addLine(to: CGPoint(x: tick.b.x, y: tick.b.y))
                    let color = Color(red: tick.color.r, green: tick.color.g, blue: tick.color.b)
                    context.stroke(path, with: .color(color.opacity(tick.alpha)),
                                   style: StrokeStyle(lineWidth: tick.halfWidth * 2, lineCap: .round))
                }
                let orb = frame.orb
                let rect = CGRect(x: orb.center.x - orb.radius, y: orb.center.y - orb.radius,
                                  width: orb.radius * 2, height: orb.radius * 2)
                context.fill(Path(ellipseIn: rect), with: .radialGradient(
                    Gradient(colors: [GlanceColor.coralHi, GlanceColor.coral, GlanceColor.coralLo]),
                    center: CGPoint(x: rect.midX + orb.radius * 0.3, y: rect.midY - orb.radius * 0.35),
                    startRadius: 0, endRadius: orb.radius * 1.7))
            }
            .background(dark ? Color(red: 0.075, green: 0.071, blue: 0.067) : Color(red: 0.957, green: 0.945, blue: 0.918))
        }
    }
}
