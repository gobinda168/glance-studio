import { expect, test } from 'claude-code/testing'
import {
  BARS, HALF, HEAVY, LIGHT, SPACE, TERMINAL, TICK,
  encode, gauge, hex, kindColor, mix, palette, ruler, scanLine, segmentBar, sparkline, timeline, track,
} from '../hooks/raster.js'

const pal = palette(false)
// [code point, foreground] per cell, the background checked once.
const cells = (w) => {
  const out = []
  for (let i = 0; i < w.length; i += 3) {
    expect(w[i + 2]).toBe(TERMINAL)
    out.push([w[i], w[i + 1]])
  }
  return out
}
const codes = (w) => cells(w).map(([c]) => c)
const colours = (w) => cells(w).map(([, f]) => f)

test("the palette is Glance's tokens, the track by theme", () => {
  expect(palette(false)).toMatchObject({ coral: 0xe8643c, coralHi: 0xffb28f, teal: 0x2a8f94, tealHi: 0x8fd9dc, amber: 0xd9a441, green: 0x2ea043, red: 0xf85149, line: 0x2b2926, tick: 0x55504a })
  expect(palette(true)).toMatchObject({ line: 0xe4dfd6, tick: 0xb9b2a6, coral: 0xe8643c })
  expect(hex(0x2a8f94)).toBe("#2a8f94")
  expect(hex(0x00000f)).toBe("#00000f")
  expect(mix(0x000000, 0xffffff, 0.5)).toBe(0x808080)
  expect(kindColor("read", pal)).toBe(pal.amber)
  expect(kindColor("edit", pal)).toBe(pal.green)
  expect(kindColor("run", pal)).toBe(pal.teal)
  expect(kindColor("agent", pal)).toBe(pal.coralHi)
  expect(kindColor("plan", pal)).toBe(pal.line)
  expect(kindColor("other", pal)).toBe(pal.line)
})

test("encode is the little-endian words in base64", () => {
  const w = Uint32Array.of(0x2588, 0xff8800, TERMINAL)
  expect(encode(w)).toBe(new Uint8Array(w.buffer).toBase64())
  expect(Uint8Array.fromBase64(encode(w)).length).toBe(12)
})

test("the plan bar: one segment per item, a gap between, coloured by status", () => {
  const w = segmentBar(13, ["done", "pending"], pal)
  expect(codes(w)).toEqual([...Array(6).fill(HEAVY), SPACE, ...Array(6).fill(HEAVY)])
  expect(colours(w).slice(0, 6)).toEqual(Array(6).fill(pal.green))
  expect(colours(w).slice(7)).toEqual(Array(6).fill(pal.line))
  expect(colours(segmentBar(5, ["current"], pal))).toEqual(Array(5).fill(pal.coral))
  // More items than room for gaps: no gaps, every cell filled.
  expect(codes(segmentBar(4, ["done", "done", "pending", "pending", "pending", "pending"], pal))).toEqual(Array(4).fill(HEAVY))
  expect(codes(segmentBar(4, [], pal))).toEqual(Array(4).fill(LIGHT))
})

test("the gauge: heavy cells, a half cell at the end, then the track", () => {
  expect(codes(gauge(10, 0.45, pal.teal, pal))).toEqual([...Array(4).fill(HEAVY), HALF, ...Array(5).fill(LIGHT)])
  expect(codes(gauge(10, 0.41, pal.teal, pal))).toEqual([...Array(4).fill(HEAVY), ...Array(6).fill(LIGHT)])
  expect(colours(gauge(10, 0.41, pal.teal, pal))).toEqual([...Array(4).fill(pal.teal), ...Array(6).fill(pal.line)])
  expect(codes(gauge(4, 2, pal.red, pal))).toEqual(Array(4).fill(HEAVY))
  expect(codes(gauge(4, -1, pal.red, pal))).toEqual(Array(4).fill(LIGHT))
  expect(codes(gauge(4, NaN, pal.red, pal))).toEqual(Array(4).fill(LIGHT))
})

test("the ruler: a tick every tenth", () => {
  expect(codes(ruler(11, pal))).toEqual(Array(11).fill(TICK))
  const r = codes(ruler(21, pal))
  expect(r.filter((c) => c === TICK).length).toBe(11)
  expect(r[0]).toBe(TICK)
  expect(r[20]).toBe(TICK)
  expect(r[1]).toBe(SPACE)
  expect(colours(ruler(21, pal))[0]).toBe(pal.tick)
})

test("the sparkline: newest at the right, the latest coral, scaled to the largest", () => {
  const w = sparkline(4, [10, 20], pal)
  expect(codes(w)).toEqual([SPACE, SPACE, BARS[3], BARS[7]])
  expect(colours(w).slice(2)).toEqual([pal.teal, pal.coral])
  expect(codes(sparkline(2, [1, 2, 3], pal))).toEqual([BARS[5], BARS[7]])
  expect(codes(sparkline(2, [0, 0], pal))).toEqual([SPACE, SPACE])
  expect(codes(sparkline(3, [], pal))).toEqual([SPACE, SPACE, SPACE])
})

test("the timeline: each step as long as it took, coloured by kind, red when it failed", () => {
  const steps = [
    { startedAt: 0, endedAt: 5, kind: "read", failed: false },
    { startedAt: 5, endedAt: 10, kind: "edit", failed: true },
  ]
  const w = timeline(10, steps, 0, 10, pal)
  expect(codes(w)).toEqual(Array(10).fill(HEAVY))
  expect(colours(w)).toEqual([...Array(5).fill(pal.amber), ...Array(5).fill(pal.red)])
  // A gap (thinking) is track; a running step reaches the end.
  const g = timeline(10, [{ startedAt: 0, endedAt: 2, kind: "run", failed: false }, { startedAt: 6, endedAt: null, kind: "edit", failed: false }], 0, 10, pal)
  expect(codes(g)).toEqual([HEAVY, HEAVY, LIGHT, LIGHT, LIGHT, LIGHT, HEAVY, HEAVY, HEAVY, HEAVY])
  expect(codes(timeline(3, [], 0, 0, pal))).toEqual([LIGHT, LIGHT, LIGHT])
})

test("the scan line: a six-cell teal glow at the phase, the rest track", () => {
  const w = scanLine(10, 3, pal)
  expect(codes(w)).toEqual([HEAVY, HEAVY, HEAVY, HEAVY, ...Array(6).fill(LIGHT)])
  expect(colours(w)[3]).toBe(pal.tealHi)
  expect(colours(w)[4]).toBe(pal.line)
  // It wraps around: phase columns + 6 is the start again.
  expect(codes(scanLine(10, 16, pal))).toEqual(codes(scanLine(10, 0, pal)))
  expect(codes(track(3, pal.amber))).toEqual([LIGHT, LIGHT, LIGHT])
  expect(colours(track(3, pal.amber))).toEqual([pal.amber, pal.amber, pal.amber])
})
