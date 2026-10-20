#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// First Light (spec 2026-10-10-first-light-onboarding-design.md): shades one frame of the Glance mark that
// FirstLightScene (GlanceCore) has already projected. Ticks arrive as screen capsules with a streak (their velocity)
// and a focus blur; the orb and the small spheres as screen circles, lit as glass spheres. No ray marching: about 30
// primitives a pixel, a flat cost.

namespace firstlight {

float hash(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

float noise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + float2(1, 0)), u.x), mix(hash(i + float2(0, 1)), hash(i + float2(1, 1)), u.x), u.y);
}

float fbm(float2 p) {
    float value = 0.0, amplitude = 0.5;
    for (int i = 0; i < 4; i++) {
        value += amplitude * noise(p);
        p = p * 2.03 + float2(1.7, 9.2);
        amplitude *= 0.5;
    }
    return value;
}

float segment(float2 p, float2 a, float2 b) {
    float2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
    return length(pa - ba * h);
}

float cross2(float2 a, float2 b) { return a.x * b.y - a.y * b.x; }

// Signed distance to the parallelogram a, b, b − v, a − v: a capsule's core swept over the shutter.
float swept(float2 p, float2 a, float2 b, float2 v) {
    float2 c = b - v, d = a - v;
    float dist = min(min(segment(p, a, b), segment(p, b, c)), min(segment(p, c, d), segment(p, d, a)));
    float c0 = cross2(b - a, p - a), c1 = cross2(c - b, p - b), c2 = cross2(d - c, p - c), c3 = cross2(a - d, p - d);
    bool inside = (c0 > 0 && c1 > 0 && c2 > 0 && c3 > 0) || (c0 < 0 && c1 < 0 && c2 < 0 && c3 < 0);
    return inside ? -dist : dist;
}

// A small sphere: a pearl lit like the orb with a coral bounce from it, or a light (thinking).
float4 sphere(float2 p, float2 center, float radius, float3 color, bool emissive, float3 light, float2 orbCenter,
              float isDark) {
    float2 d = (p - center) / max(radius, 0.001);
    float r = length(d);
    if (emissive) {
        float core = 1.0 - smoothstep(0.55, 1.0, r);
        float halo = exp(-max(r - 0.6, 0.0) * 1.6) * 0.55;
        return float4(color, clamp(core + halo, 0.0, 1.0));
    }
    float aa = 1.2 / max(radius, 0.001);
    float coverage = 1.0 - smoothstep(1.0 - aa, 1.0, r);
    if (coverage <= 0.0) return float4(0);
    float3 n = float3(d.x, d.y, -sqrt(max(1.0 - r * r, 0.0)));
    float wrap = (dot(n, light) + 0.5) / 1.5;
    float3 body = color * (0.55 + 0.45 * clamp(wrap, 0.0, 1.0));
    float2 toOrb = normalize(orbCenter - center + 1e-4);
    float bounce = clamp(dot(n.xy, toOrb), 0.0, 1.0);
    body = mix(body, float3(0.93, 0.47, 0.30), bounce * 0.45);
    float spec = pow(max(dot(reflect(-light, n), float3(0, 0, -1)), 0.0), 40.0);
    body += spec * 0.8;
    body *= mix(0.92, 1.0, isDark);
    return float4(body, coverage);
}

} // namespace firstlight

using namespace firstlight;

/// position: the pixel in points. size: the view. orb: centre x, y, radius, glow. mid / hi / lo: the orb's tones,
/// with w = the reading scan, the voice's ripple, the finale's flare. env: dark (0/1), the light's direction x, y
/// from the pointer, the orb's opacity. ticks: 12 floats each; spheres: 8 floats each (FirstLightFrame's packing).
[[ stitchable ]] half4 firstLight(float2 position, half4 color, float2 size, float time, float4 orb, float4 mid,
                                  float4 hi, float4 lo, float4 env,
                                  device const float *ticks, int tickFloats,
                                  device const float *spheres, int sphereFloats) {
    float2 p = position;
    float isDark = env.x;
    float3 light = normalize(float3(env.y, env.z, -0.95));
    float2 oc = orb.xy;
    float orad = max(orb.z, 0.001);
    float glow = orb.w;
    float orbOpacity = env.w;
    float minSide = min(size.x, size.y);

    // The ground: warm graphite or warm paper, lit faintly by the orb, darker at the corners, with a whisper of grain
    // so the gradients never band.
    float3 groundColor = mix(float3(0.957, 0.945, 0.918), float3(0.075, 0.071, 0.067), isDark);
    float3 col = groundColor;
    float fromOrb = length(p - oc);
    float ambient = exp(-fromOrb / (minSide * 0.55)) * orbOpacity;
    col += mix(float3(0.03, 0.018, 0.01) * 0.8, mid.rgb * 0.09, isDark) * ambient;
    float2 uv = p / size - 0.5;
    col *= 1.0 - dot(uv, uv) * mix(0.10, 0.55, isDark);
    col += (hash(p + fract(time) * 61.0) - 0.5) * mix(0.010, 0.016, isDark);

    // The orb's soft shadow on the ground (stronger on paper).
    float2 shadowD = (p - (oc + float2(0.12, 0.62) * orad)) / (orad * float2(1.05, 0.5) + 1.0);
    col *= 1.0 - exp(-dot(shadowD, shadowD) * 1.6) * mix(0.16, 0.30, isDark) * orbOpacity * step(3.0, orad);

    int sphereCount = sphereFloats / 8;

    // Spheres behind the orb first.
    for (int i = 0; i < sphereCount; i++) {
        device const float *s = spheres + i * 8;
        if (s[2] <= 0.01 || s[3] < 0.5) continue;
        if (length(p - oc) < orad) continue;
        float4 c = sphere(p, float2(s[0], s[1]), s[2], float3(s[4], s[5], s[6]), s[7] > 0.5, light, oc, isDark);
        col = s[7] > 0.5 ? col + c.rgb * c.a * mix(0.6, 1.0, isDark) : mix(col, c.rgb, c.a);
    }

    // The orb's halo: in points, so a tiny orb (the first spark) still glows.
    float edgeDist = max(fromOrb - orad, 0.0);
    float halo = exp(-edgeDist / (orad * 0.42 + 12.0)) * glow * orbOpacity;
    float3 haloColor = mix(mid.rgb, hi.rgb, 0.35);
    col = mix(col + haloColor * halo * 0.55, mix(col, haloColor, halo * 0.28), 1.0 - isDark);

    // The voice's ripples.
    if (hi.w > 0.01) {
        for (int k = 0; k < 3; k++) {
            float phase = fract(time * 0.55 + float(k) / 3.0);
            float ringRadius = orad * (1.08 + phase * 0.9);
            float ring = exp(-pow((fromOrb - ringRadius) / 1.6, 2.0)) * (1.0 - phase) * hi.w;
            col = mix(col + hi.rgb * ring * 0.6, mix(col, mid.rgb, ring * 0.5), 1.0 - isDark);
        }
    }

    // The orb: glass with a coral body, a moving liquid light inside, a fresnel rim, a pointer-lit highlight.
    float2 d = (p - oc) / orad;
    float r2 = dot(d, d);
    if (r2 < 1.0 && orbOpacity > 0.0) {
        float3 n = float3(d.x, d.y, -sqrt(1.0 - r2));
        float lambert = dot(n, light);
        float wrap = clamp((lambert + 0.45) / 1.45, 0.0, 1.0);
        float3 body = mix(lo.rgb, mid.rgb, smoothstep(0.0, 0.7, wrap));
        body = mix(body, hi.rgb, pow(wrap, 3.0) * 0.55);
        float swirl = fbm(d * 2.1 + n.z * 1.4 + float2(time * 0.06, -time * 0.045));
        body += (hi.rgb - lo.rgb) * (swirl - 0.5) * 0.32;
        float core = exp(-dot(d + light.xy * 0.25, d + light.xy * 0.25) * 2.2);
        body += hi.rgb * core * 0.18;
        float fresnel = pow(1.0 + n.z, 3.0);
        body = mix(body, mix(hi.rgb, float3(1.0, 0.86, 0.78), 0.4), fresnel * 0.45);
        float3 reflected = reflect(-light, n);
        float spec = pow(max(dot(reflected, float3(0, 0, -1)), 0.0), 80.0);
        float sheen = pow(max(dot(reflected, float3(0, 0, -1)), 0.0), 8.0);
        body += spec * 0.95 + sheen * 0.10;
        if (mid.w > 0.01) {
            float scanY = sin(time * 1.7) * 0.85;
            float band = exp(-pow((d.y - scanY) * 11.0, 2.0)) * smoothstep(1.0, 0.7, r2);
            body += float3(1.0, 0.88, 0.62) * band * mid.w * 0.7;
        }
        float edge = 1.0 - smoothstep(1.0 - 1.4 / orad, 1.0, sqrt(r2));
        col = mix(col, body, edge * orbOpacity);
    }

    // Spheres in front of the orb.
    for (int i = 0; i < sphereCount; i++) {
        device const float *s = spheres + i * 8;
        if (s[2] <= 0.01 || s[3] > 0.5) continue;
        float4 c = sphere(p, float2(s[0], s[1]), s[2], float3(s[4], s[5], s[6]), s[7] > 0.5, light, oc, isDark);
        col = s[7] > 0.5 ? col + c.rgb * c.a * mix(0.6, 1.0, isDark) : mix(col, c.rgb, c.a);
    }

    // The ticks: each a capsule swept along its velocity (motion blur) and softened by its distance from the focal
    // plane (depth of field). Spreading the same light over a larger area dims it, so a streak or a blur is fainter.
    int tickCount = tickFloats / 12;
    for (int i = 0; i < tickCount; i++) {
        device const float *t = ticks + i * 12;
        float alpha = t[11];
        if (alpha <= 0.001) continue;
        float2 a = float2(t[0], t[1]), b = float2(t[2], t[3]), v = float2(t[4], t[5]);
        float halfWidth = t[6], blur = t[7];
        float dist = swept(p, a, b, v * 1.6) - halfWidth;
        float soft = blur + 0.7;
        float coverage = 1.0 - smoothstep(-soft, soft, dist);
        float energy = (2.0 * halfWidth) / (2.0 * halfWidth + length(v) * 1.6 + blur * 1.5);
        float3 tickColor = float3(t[8], t[9], t[10]);
        float lit = coverage * alpha * clamp(energy, 0.08, 1.0);
        float bloom = exp(-max(dist, 0.0) / (5.0 + blur)) * alpha * energy;
        col = mix(col, tickColor, lit);
        col = mix(col + tickColor * bloom * 0.14, mix(col, tickColor, bloom * 0.07), 1.0 - isDark);
    }

    // Lift-off: the orb's light fills the frame, then settles to the ground's colour.
    float flare = lo.w;
    if (flare > 0.0) {
        float3 fill = mix(hi.rgb, mid.rgb, smoothstep(0.0, max(size.x, size.y), fromOrb));
        col = mix(col, fill, smoothstep(0.0, 0.55, flare));
        col = mix(col, groundColor, smoothstep(0.55, 1.0, flare));
    }

    return half4(half3(clamp(col, 0.0, 1.0)), 1.0h);
}
