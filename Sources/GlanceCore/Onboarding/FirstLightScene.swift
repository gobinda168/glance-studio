import Foundation

/// First Light's 3D scene (spec 2026-10-10-first-light-onboarding-design.md, "Architecture"): the mark assembling
/// itself and then living through setup. Everything here is a function of the clock: the view asks for a frame at a
/// time and gets the ticks as projected capsules and the orb, its thinking lights and the account satellites as
/// screen spheres, which `FirstLight.metal` shades. The CPU does the 3D (30-odd points a frame); the GPU only shades.
public struct FirstLightScene: Equatable, Sendable {
  public enum Layout: Equatable, Sendable {
    /// The mark centred, the word under it.
    case intro
    /// The mark on the left third, the step's card on the right.
    case setup
  }

  /// The orb's state colour (MASTER §7.2): coral calm or speaking, teal thinking, amber reading.
  public enum Mood: Equatable, Sendable { case calm, thinking, reading }

  public static let quarters = 4
  public static let maxSatellites = 4
  /// The camera's distance from the dial, in mark units: a gentle perspective.
  static let distance = 700.0

  public private(set) var layout = Layout.intro
  public private(set) var mood = Mood.calm
  /// No flight, no dolly, no breathing, no parallax: the finished mark, and changes as quick fades.
  public let reduceMotion: Bool

  private var centerX = FirstLightSpring(0.5, response: 0.9, damping: 0.9)
  private var centerY = FirstLightSpring(0.4, response: 0.9, damping: 0.9)
  /// The dial's outer radius as a fraction of the window's shorter side.
  private var radius = FirstLightSpring(0.25, response: 0.9, damping: 0.9)
  /// How bright a tick whose quarter isn't lit is (1 in the intro: the whole mark).
  private var dim = FirstLightSpring(1, response: 0.8, damping: 1)
  private var lit = Array(repeating: FirstLightSpring(0, response: 0.7, damping: 0.8), count: quarters)
  private var thinking = FirstLightSpring(0, response: 0.5, damping: 1)
  private var reading = FirstLightSpring(0, response: 0.5, damping: 1)
  private var satellites = Array(repeating: FirstLightSpring(0, response: 0.8, damping: 0.62), count: maxSatellites)
  private var finaleStart: Double?

  public init(reduceMotion: Bool) {
    self.reduceMotion = reduceMotion
  }

  // MARK: Directing

  /// Moves the mark aside for the setup card, and dims the dial so each finished step can light its quarter.
  public mutating func setLayout(_ layout: Layout, at t: Double) {
    self.layout = layout
    let target: (x: Double, y: Double, r: Double, dim: Double) = switch layout {
    case .intro: (0.5, 0.4, 0.25, 1)
    case .setup: (0.26, 0.5, 0.24, 0.36)
    }
    centerX.go(target.x, at: t, instant: reduceMotion)
    centerY.go(target.y, at: t, instant: reduceMotion)
    radius.go(target.r, at: t, instant: reduceMotion)
    dim.go(target.dim, at: t, instant: reduceMotion)
  }

  public mutating func setMood(_ mood: Mood, at t: Double) {
    self.mood = mood
    thinking.go(mood == .thinking ? 1 : 0, at: t, instant: reduceMotion)
    reading.go(mood == .reading ? 1 : 0, at: t, instant: reduceMotion)
  }

  /// Lights quarter `index` (0 = twelve to three o'clock, clockwise) when its step is done.
  public mutating func setLit(_ index: Int, _ on: Bool, at t: Double) {
    guard lit.indices.contains(index) else { return }
    lit[index].go(on ? 1 : 0, at: t, instant: reduceMotion)
  }

  /// How many linked accounts orbit the orb.
  public mutating func setSatellites(_ count: Int, at t: Double) {
    for index in satellites.indices {
      satellites[index].go(index < count ? 1 : 0, at: t, instant: reduceMotion)
    }
  }

  /// Lift-off: the dial turns once, the camera flies into the orb and its light fills the frame. Done after
  /// `finaleDuration`.
  public mutating func startFinale(at t: Double) {
    guard finaleStart == nil else { return }
    finaleStart = t
    for index in lit.indices { lit[index].go(1, at: t, instant: reduceMotion) }
  }

  public var finaleDuration: Double { reduceMotion ? 0.3 : 1.7 }

  private func isLit(_ index: Int) -> Bool { lit[index].target > 0.5 }

  // MARK: Rendering

  /// When the intro's mark has finished assembling.
  public static let introDuration = 3.6

  /// The scene at time `t` (seconds since the window appeared) in a `width` × `height` point view. `pointer` is the
  /// mouse from the view's centre, −1…1 each way (nil when outside); `level` the voice's loudness 0…1.
  public func frame(at t: Double, width: Double, height: Double, pointer: (x: Double, y: Double)? = nil,
                    level: Double = 0) -> FirstLightFrame {
    // Under Reduce Motion the intro has already happened.
    let clock = reduceMotion ? max(t, Self.introDuration + 1) : t
    let side = min(width, height)
    let scale = radius.value(at: t) * side / FirstLightMark.outerRadius
    var center = (x: centerX.value(at: t) * width, y: centerY.value(at: t) * height)

    // The dial settles from tilted and rolled to facing the camera; the pointer leans it a little.
    let settle = FirstLightCurve.spring(clock - 1.5, response: 1.3, damping: 0.82)
    var pose = Pose(tiltX: -64 * (1 - settle), tiltY: 0, roll: -50 * (1 - settle))
    if let pointer, !reduceMotion {
      pose.tiltX += pointer.y * 7
      pose.tiltY += pointer.x * 7
    }

    // Lift-off: one turn, then a dolly into the orb, which moves to the centre.
    var zoom = 1.0, flare = 0.0, toCenter = 0.0
    if let finaleStart {
      let f = t - finaleStart
      if reduceMotion {
        flare = FirstLightCurve.progress(f, start: 0, duration: finaleDuration)
      } else {
        pose.roll += 360 * FirstLightCurve.easeInOut(FirstLightCurve.progress(f, start: 0, duration: 1.1))
        zoom = 1 + 14 * FirstLightCurve.easeIn(FirstLightCurve.progress(f, start: 0.6, duration: 1.0))
        toCenter = FirstLightCurve.easeInOut(FirstLightCurve.progress(f, start: 0.4, duration: 1.0))
        flare = FirstLightCurve.easeIn(FirstLightCurve.progress(f, start: 0.95, duration: 0.75))
      }
    }

    // The orb: a point of light at first, then it inflates; it breathes, and swells with the voice.
    let inflate = 0.07 + 0.93 * FirstLightCurve.spring(clock - 2.2, response: 0.7, damping: 0.68)
    let breath = reduceMotion ? 1 : 1 + 0.018 * sin(2 * .pi * t / 4)
    let orbScale = inflate * breath * (1 + 0.05 * level)
    let orbLocal = Vec(FirstLightMark.orbOffset.x, FirstLightMark.orbOffset.y, 0)
    let orbCenterWorld = pose.apply(orbLocal)

    // Zooming happens about the orb, which drifts to the window's centre as the camera closes in.
    let orbScreen = Self.project(orbCenterWorld, center: center, scale: scale)
    center.x += (width / 2 - orbScreen.x) * toCenter
    center.y += (height / 2 - orbScreen.y) * toCenter
    let focus = (x: orbScreen.x + (width / 2 - orbScreen.x) * toCenter,
                 y: orbScreen.y + (height / 2 - orbScreen.y) * toCenter)
    let projector = Projector(center: center, scale: scale, zoom: zoom, focus: focus)

    // Ticks.
    let dimValue = dim.value(at: t)
    var ticks: [FirstLightFrame.Capsule] = []
    for (index, tick) in FirstLightMark.ticks.enumerated() {
      let now = Self.tickPose(index, tick, at: clock)
      let before = Self.tickPose(index, tick, at: clock - 1.0 / 30)
      let a = projector.project(pose.apply(now.inner)), b = projector.project(pose.apply(now.outer))
      let a0 = projector.project(pose.apply(before.inner)), b0 = projector.project(pose.apply(before.outer))
      let depth = (pose.apply(now.inner).z + pose.apply(now.outer).z) / 2
      let perspective = Self.distance / max(Self.distance + depth, 1)
      let quarter = min(Int(tick.degrees / 90), Self.quarters - 1)
      let brightness = FirstLightCurve.mix(dimValue, 1, lit[quarter].value(at: t))
      let velocity = (x: ((a.x + b.x) - (a0.x + b0.x)) / 2, y: ((a.y + b.y) - (a0.y + b0.y)) / 2)
      ticks.append(FirstLightFrame.Capsule(
        a: a, b: b, velocity: velocity,
        halfWidth: FirstLightMark.width / 2 * scale * perspective * zoom,
        blur: min(abs(depth) / Self.distance * 60, 18),
        color: tick.ink == .coral ? FirstLightFrame.coral : FirstLightFrame.amber,
        alpha: now.opacity * brightness))
    }

    // The orb.
    let orbPoint = projector.project(orbCenterWorld)
    let orbPerspective = Self.distance / max(Self.distance + orbCenterWorld.z, 1)
    let orbRadius = FirstLightMark.orbRadius * orbScale * scale * orbPerspective * zoom
    let ignite = FirstLightCurve.progress(clock, start: 0, duration: 0.8)
    let thinkingWeight = thinking.value(at: t), readingWeight = reading.value(at: t)
    let palette = FirstLightFrame.Palette.blend(thinking: thinkingWeight, reading: readingWeight)

    // Thinking lights and linked accounts: small spheres around the orb, in tilted orbits so they pass behind it.
    var spheres: [FirstLightFrame.Sphere] = []
    if thinkingWeight > 0.01 {
      for k in 0..<3 {
        let angle = t * 2 * .pi / 1.6 + Double(k) * 2 * .pi / 3
        let local = orbLocal + Self.orbit(angle: angle, radius: FirstLightMark.orbRadius * 1.45, tilt: 72)
        spheres.append(sphere(local, radius: 3.4 * thinkingWeight, pose: pose, projector: projector, scale: scale,
                              zoom: zoom, orb: orbCenterWorld, color: FirstLightFrame.teal, emissive: true))
      }
    }
    for (k, satellite) in satellites.enumerated() {
      let size = satellite.value(at: t)
      guard size > 0.01 else { continue }
      let angle = (reduceMotion ? 0 : t * 2 * .pi / 16) + Double(k) * .pi / 2 + 0.6
      let local = orbLocal + Self.orbit(angle: angle, radius: FirstLightMark.orbRadius * 1.6, tilt: 66)
      spheres.append(sphere(local, radius: 6.5 * size, pose: pose, projector: projector, scale: scale, zoom: zoom,
                            orb: orbCenterWorld, color: FirstLightFrame.pearl, emissive: false))
    }

    return FirstLightFrame(
      orb: FirstLightFrame.Orb(center: orbPoint, radius: orbRadius, opacity: ignite, glow: 0.6 + 0.4 * (1 - inflate),
                               palette: palette, scan: readingWeight, ripple: level),
      ticks: ticks, spheres: spheres, flare: flare, time: t)
  }

  private func sphere(_ local: Vec, radius: Double, pose: Pose, projector: Projector, scale: Double, zoom: Double,
                      orb: Vec, color: FirstLightFrame.RGB, emissive: Bool) -> FirstLightFrame.Sphere {
    let world = pose.apply(local)
    let perspective = Self.distance / max(Self.distance + world.z, 1)
    return FirstLightFrame.Sphere(center: projector.project(world), radius: radius * scale * perspective * zoom,
                                  behind: world.z > orb.z, color: color, emissive: emissive)
  }

  /// Where tick `index` is at `t`: it leaves from beside the camera at its own moment (clockwise order), sweeps in
  /// on a spiral, turning end over end, and lands in the dial's plane.
  static func tickPose(_ index: Int, _ tick: FirstLightMark.Tick, at t: Double) -> (inner: Vec, outer: Vec, opacity: Double) {
    let start = 0.6 + Double(index) * 0.045
    let p = FirstLightCurve.progress(t, start: start, duration: 1.25)
    let e = FirstLightCurve.easeOut(p)
    let swirl = (1 - e) * 140
    let radians = (tick.degrees - swirl) * .pi / 180
    let radial = Vec(sin(radians), -cos(radians), 0)
    let tumble = (1 - e) * .pi
    let direction = radial * cos(tumble) + Vec(0, 0, -1) * sin(tumble)
    let innerRadius = FirstLightCurve.mix(250, FirstLightMark.inner, e)
    let z = FirstLightCurve.mix(-distance * 0.9, 0, e)
    let inner = radial * innerRadius + Vec(0, 0, z)
    let outer = inner + direction * (tick.outer - FirstLightMark.inner)
    return (inner, outer, FirstLightCurve.progress(t, start: start, duration: 0.3))
  }

  /// A point on a circle of `radius` in a plane tilted `tilt`° from facing the camera.
  static func orbit(angle: Double, radius: Double, tilt: Double) -> Vec {
    let tiltRadians = tilt * .pi / 180
    return Vec(radius * cos(angle), radius * sin(angle) * cos(tiltRadians), radius * sin(angle) * sin(tiltRadians))
  }

  static func project(_ point: Vec, center: (x: Double, y: Double), scale: Double) -> (x: Double, y: Double) {
    let perspective = distance / max(distance + point.z, 1)
    return (center.x + point.x * scale * perspective, center.y + point.y * scale * perspective)
  }

  // MARK: 3D

  struct Vec: Equatable {
    var x, y, z: Double
    init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }
    static func + (a: Vec, b: Vec) -> Vec { Vec(a.x + b.x, a.y + b.y, a.z + b.z) }
    static func * (a: Vec, s: Double) -> Vec { Vec(a.x * s, a.y * s, a.z * s) }
  }

  /// The dial's orientation, in degrees: rolled about its axis, then tilted about x (top away) and y.
  struct Pose {
    var tiltX: Double, tiltY: Double, roll: Double

    func apply(_ v: Vec) -> Vec {
      let r = roll * .pi / 180, a = tiltX * .pi / 180, b = tiltY * .pi / 180
      let rolled = Vec(v.x * cos(r) - v.y * sin(r), v.x * sin(r) + v.y * cos(r), v.z)
      let tilted = Vec(rolled.x, rolled.y * cos(a) - rolled.z * sin(a), rolled.y * sin(a) + rolled.z * cos(a))
      return Vec(tilted.x * cos(b) + tilted.z * sin(b), tilted.y, -tilted.x * sin(b) + tilted.z * cos(b))
    }
  }

  struct Projector {
    let center: (x: Double, y: Double)
    let scale: Double
    let zoom: Double
    let focus: (x: Double, y: Double)

    func project(_ point: Vec) -> (x: Double, y: Double) {
      let p = FirstLightScene.project(point, center: center, scale: scale)
      return (focus.x + (p.x - focus.x) * zoom, focus.y + (p.y - focus.y) * zoom)
    }
  }

  public static func == (a: FirstLightScene, b: FirstLightScene) -> Bool {
    a.layout == b.layout && a.mood == b.mood && a.reduceMotion == b.reduceMotion && a.centerX == b.centerX
      && a.centerY == b.centerY && a.radius == b.radius && a.dim == b.dim && a.lit == b.lit
      && a.thinking == b.thinking && a.reading == b.reading && a.satellites == b.satellites
      && a.finaleStart == b.finaleStart
  }
}

/// One frame of First Light, in the view's points, ready for the shader.
public struct FirstLightFrame: Sendable {
  public struct RGB: Equatable, Sendable {
    public var r, g, b: Double
    init(_ hex: UInt32) {
      r = Double((hex >> 16) & 0xFF) / 255
      g = Double((hex >> 8) & 0xFF) / 255
      b = Double(hex & 0xFF) / 255
    }
    init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
    static func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
      RGB(r: a.r + (b.r - a.r) * t, g: a.g + (b.g - a.g) * t, b: a.b + (b.b - a.b) * t)
    }
  }

  static let coral = RGB(0xE8643C)
  static let amber = RGB(0xD9A441)
  static let teal = RGB(0x5CC3C8)
  static let pearl = RGB(0xF4EDE3)

  /// The orb's three tones: its highlight, body and depth.
  public struct Palette: Equatable, Sendable {
    public var hi, mid, lo: RGB

    static let coral = Palette(hi: RGB(0xFFB08F), mid: RGB(0xE8643C), lo: RGB(0xB93A18))
    static let teal = Palette(hi: RGB(0xC9F1F2), mid: RGB(0x2A8F94), lo: RGB(0x155A5D))
    static let amber = Palette(hi: RGB(0xFFE2A6), mid: RGB(0xD9A441), lo: RGB(0x8A5A00))

    static func blend(thinking: Double, reading: Double) -> Palette {
      func tone(_ key: KeyPath<Palette, RGB>) -> RGB {
        RGB.mix(RGB.mix(coral[keyPath: key], teal[keyPath: key], thinking), amber[keyPath: key], reading)
      }
      return Palette(hi: tone(\.hi), mid: tone(\.mid), lo: tone(\.lo))
    }
  }

  public struct Capsule: Sendable {
    public var a, b, velocity: (x: Double, y: Double)
    public var halfWidth, blur: Double
    public var color: RGB
    public var alpha: Double
  }

  public struct Sphere: Sendable {
    public var center: (x: Double, y: Double)
    public var radius: Double
    /// Further than the orb: hidden where it overlaps it.
    public var behind: Bool
    public var color: RGB
    /// A light (thinking) rather than a lit pearl (an account).
    public var emissive: Bool
  }

  public struct Orb: Sendable {
    public var center: (x: Double, y: Double)
    public var radius: Double
    public var opacity: Double
    public var glow: Double
    public var palette: Palette
    /// The amber scan line's strength (reading).
    public var scan: Double
    /// The voice's loudness: ripples.
    public var ripple: Double
  }

  public var orb: Orb
  public var ticks: [Capsule]
  public var spheres: [Sphere]
  /// The finale's light filling the frame, 0…1.
  public var flare: Double
  public var time: Double

  public static let floatsPerTick = 12
  public static let floatsPerSphere = 8

  /// `[ax, ay, bx, by, vx, vy, halfWidth, blur, r, g, b, alpha]` per tick.
  public var packedTicks: [Float] {
    ticks.flatMap { t -> [Double] in
      [t.a.x, t.a.y, t.b.x, t.b.y, t.velocity.x, t.velocity.y, t.halfWidth, t.blur, t.color.r, t.color.g, t.color.b,
       t.alpha]
    }.map(Float.init)
  }

  /// `[cx, cy, radius, behind, r, g, b, emissive]` per sphere; at least one (empty) so the shader's array is never
  /// zero-length.
  public var packedSpheres: [Float] {
    let values = spheres.flatMap { s -> [Double] in
      [s.center.x, s.center.y, s.radius, s.behind ? 1 : 0, s.color.r, s.color.g, s.color.b, s.emissive ? 1 : 0]
    }
    return (values.isEmpty ? Array(repeating: 0, count: Self.floatsPerSphere) : values).map(Float.init)
  }
}
