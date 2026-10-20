import Foundation
import Testing
@testable import GlanceCore

@Test func theMarkHasTheLogosTwentyFourTicks() {
  let ticks = FirstLightMark.ticks
  #expect(ticks.count == 24)
  #expect(ticks.filter { $0.ink == .coral }.count == 17)
  #expect(ticks.filter { $0.ink == .amber }.count == 7)
  #expect(ticks.map(\.degrees) == stride(from: 0.0, to: 360, by: 15).map { $0 })
  #expect(ticks.allSatisfy { $0.outer > FirstLightMark.inner })
  #expect(FirstLightMark.outerRadius == 94) // y2 = 6 at 195°
}

@Test func springsStartAtZeroAndSettleAtOne() {
  #expect(FirstLightCurve.spring(-1, response: 0.5, damping: 0.8) == 0)
  #expect(FirstLightCurve.spring(0, response: 0.5, damping: 0.8) == 0)
  #expect(abs(FirstLightCurve.spring(5, response: 0.5, damping: 0.8) - 1) < 0.0001)
  #expect(abs(FirstLightCurve.spring(5, response: 0.5, damping: 1) - 1) < 0.0001)
  // An underdamped spring overshoots a little on the way.
  let peak = stride(from: 0.0, to: 1, by: 0.01).map { FirstLightCurve.spring($0, response: 0.5, damping: 0.6) }.max()!
  #expect(peak > 1 && peak < 1.2)
}

@Test func aSpringRetargetedMidFlightStartsFromWhereItIs() {
  var spring = FirstLightSpring(0, response: 0.5, damping: 1)
  spring.set(1, at: 0)
  let midway = spring.value(at: 0.1)
  spring.set(0, at: 0.1)
  #expect(abs(spring.value(at: 0.1) - midway) < 0.0001)
  #expect(abs(spring.value(at: 10)) < 0.0001)
}

@Test func afterTheIntroTheTicksSitExactlyOnTheMark() {
  let scene = FirstLightScene(reduceMotion: false)
  let frame = scene.frame(at: 20, width: 1000, height: 600)
  let scale = 0.25 * 600 / FirstLightMark.outerRadius
  for (tick, capsule) in zip(FirstLightMark.ticks, frame.ticks) {
    let d = tick.direction
    #expect(abs(capsule.a.x - (500 + d.x * FirstLightMark.inner * scale)) < 0.01)
    #expect(abs(capsule.a.y - (240 + d.y * FirstLightMark.inner * scale)) < 0.01)
    #expect(abs(capsule.b.x - (500 + d.x * tick.outer * scale)) < 0.01)
    #expect(abs(capsule.velocity.x) < 0.01 && abs(capsule.velocity.y) < 0.01)
    #expect(capsule.blur < 0.01)
    #expect(capsule.alpha == 1)
  }
  #expect(abs(frame.orb.center.x - (500 + 9 * scale)) < 0.5)
  #expect(frame.orb.opacity == 1)
  #expect(frame.spheres.isEmpty)
}

@Test func atTheStartTheTicksAreStillOnTheirWayAndTheOrbIsAPoint() {
  let frame = FirstLightScene(reduceMotion: false).frame(at: 0.7, width: 1000, height: 600)
  #expect(frame.ticks[0].blur > 10)
  #expect(frame.ticks.last!.alpha == 0)
  #expect(frame.orb.radius < 5)
}

@Test func reduceMotionShowsTheFinishedMarkFromTheFirstFrame() {
  let reduced = FirstLightScene(reduceMotion: true).frame(at: 0, width: 1000, height: 600)
  let settled = FirstLightScene(reduceMotion: false).frame(at: 20, width: 1000, height: 600)
  for (a, b) in zip(reduced.ticks, settled.ticks) {
    #expect(abs(a.a.x - b.a.x) < 0.01 && abs(a.b.y - b.b.y) < 0.01)
  }
  #expect(abs(reduced.orb.radius - settled.orb.radius) < 1)
}

@Test func setupMovesTheMarkLeftAndDimsUnlitQuarters() {
  var scene = FirstLightScene(reduceMotion: true)
  scene.setLayout(.setup, at: 5)
  scene.setLit(0, true, at: 5)
  let frame = scene.frame(at: 5, width: 1000, height: 600)
  #expect(frame.orb.center.x < 400)
  #expect(frame.ticks[0].alpha == 1)    // 0°: quarter 0, lit
  #expect(abs(frame.ticks[6].alpha - 0.36) < 0.0001)  // 90°: quarter 1, not yet
}

@Test func linkedAccountsOrbitAndThinkingAddsLights() {
  var scene = FirstLightScene(reduceMotion: true)
  scene.setSatellites(2, at: 0)
  #expect(scene.frame(at: 5, width: 800, height: 600).spheres.count == 2)
  scene.setMood(.thinking, at: 0)
  #expect(scene.frame(at: 5, width: 800, height: 600).spheres.count == 5)
}

@Test func theFinaleFillsTheFrameWithLight() {
  var scene = FirstLightScene(reduceMotion: false)
  scene.setLayout(.setup, at: 10)
  scene.startFinale(at: 20)
  let end = scene.frame(at: 20 + scene.finaleDuration, width: 1000, height: 600)
  #expect(end.flare > 0.99)
  #expect(end.orb.radius > 600)
  #expect(abs(end.orb.center.x - 500) < 1 && abs(end.orb.center.y - 300) < 1)
}

@Test func theShaderGetsTwelveFloatsPerTickAndEightPerSphere() {
  var scene = FirstLightScene(reduceMotion: true)
  #expect(scene.frame(at: 0, width: 800, height: 600).packedTicks.count == 24 * FirstLightFrame.floatsPerTick)
  #expect(scene.frame(at: 0, width: 800, height: 600).packedSpheres.count == FirstLightFrame.floatsPerSphere)
  scene.setSatellites(3, at: 0)
  #expect(scene.frame(at: 0, width: 800, height: 600).packedSpheres.count == 3 * FirstLightFrame.floatsPerSphere)
}
