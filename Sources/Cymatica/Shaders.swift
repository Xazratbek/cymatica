/// Metal source, compiled at launch so the build does not need the offline Metal toolchain.
/// Struct layouts must match the Swift mirrors in Renderer.swift.
enum ShaderSource {
    static let metal = #"""
#include <metal_stdlib>
using namespace metal;

constant float PI = 3.14159265358979;
constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);

// a: position.xy on the plate (-1...1), height above the plate, vertical velocity
// b: horizontal velocity.xy, per-grain random seed, spark (fades after each hop)
struct Grain { float4 a; float4 b; };

struct SimUniforms {
    float4 modes[4];   // a, b, variant, weight
    float dt; float time; float drive; float gain;
    float threshold; float hopUp; float hopSide; float gravity;
    uint shape; uint frame; uint grainCount; uint clockCount;
    float4 clock;      // mix (0 plate modes ... 1 clock), shimmer floor, guide, falloff
    float4 sprinkle;   // rate per second, side speed, rise speed, unused
    uint scatterFrom; uint pad0; uint pad1; uint pad2;
};

// A capsule the sand gathers on in clock mode. Mirrors ClockStroke in ClockFace.swift.
struct ClockStroke { float4 ends; float4 extra; };

struct DrawUniforms {
    float4x4 viewProjection;
    float4 sandColor;
    float4 sparkColor;
    float4 halfVector;  // xyz: light/eye half vector, w: glint strength
    float pointSize; float intensity; float sparkle; float time;
};

struct CompositeUniforms { float bloomStrength; float exposure; float headroom; float blackFloor; };

inline uint pcgHash(uint v) {
    uint state = v * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

inline float random01(thread uint &state) {
    state = pcgHash(state);
    return float(state) * (1.0 / 4294967296.0);
}

// ---------------------------------------------------------------------------
// Plate physics
// ---------------------------------------------------------------------------

inline float squareMode(float2 p, float4 mode) {
    float2 u = p * 0.5 + 0.5;
    float n = mode.x, m = mode.y;
    return 0.5 * (cos(n * PI * u.x) * cos(m * PI * u.y) - mode.z * cos(m * PI * u.x) * cos(n * PI * u.y));
}

inline float circleMode(float2 p, float4 mode, device const float *profiles, int slot) {
    float r = min(length(p), 1.0);
    float x = r * 1023.0;
    int i0 = int(x);
    int i1 = min(i0 + 1, 1023);
    float radial = mix(profiles[slot * 1024 + i0], profiles[slot * 1024 + i1], x - float(i0));
    return radial * cos(mode.x * atan2(p.y, p.x) + mode.z);
}

// Time-averaged vibration energy, 0 on nodal lines.
inline float plateEnergy(float2 p, constant SimUniforms &U, device const float *profiles) {
    float energy = 0.0;
    for (int i = 0; i < 4; i++) {
        float w = U.modes[i].w;
        if (w <= 0.0) continue;
        float z = U.shape == 0 ? squareMode(p, U.modes[i]) : circleMode(p, U.modes[i], profiles, i);
        energy += w * z * z;
    }
    return energy;
}

// Bakes the clock strokes into a field texture covering the plate: x = distance to the
// nearest stroke edge (negative inside), yz = unit vector toward it. Runs only when the
// displayed time changes, so grains pay one texture read per frame instead of a loop
// over every stroke.
kernel void bakeClockField(texture2d<float, access::write> field [[texture(0)]],
                           device const ClockStroke *strokes [[buffer(0)]],
                           constant uint &count [[buffer(1)]],
                           uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= field.get_width() || gid.y >= field.get_height()) return;
    float2 p = (float2(gid) + 0.5) / float2(field.get_width(), field.get_height()) * 2.0 - 1.0;
    float best = 1e9;
    float2 nearest = p;
    for (uint i = 0; i < count; i++) {
        float2 a = strokes[i].ends.xy;
        float2 ab = strokes[i].ends.zw - a;
        float t = clamp(dot(p - a, ab) / max(dot(ab, ab), 1e-8), 0.0, 1.0);
        float2 closest = a + ab * t;
        float d = length(p - closest) - strokes[i].extra.x;
        if (d < best) { best = d; nearest = closest; }
    }
    float2 delta = nearest - p;
    float len = length(delta);
    field.write(float4(best, len > 1e-6 ? delta / len : float2(0.0), 0.0), gid);
}

// Clock "energy": 0 on the strokes, rising to 1 within `falloff` of them. `toward`
// points at the nearest stroke.
inline float clockEnergy(float2 p, texture2d<float> field, float falloff, thread float2 &toward) {
    float4 f = field.sample(linearClamp, p * 0.5 + 0.5);
    float len = length(f.yz);
    toward = len > 1e-4 ? f.yz / len : float2(0.0);
    float e = saturate(f.x / falloff);
    return e * e;
}

kernel void scatterGrains(device Grain *grains [[buffer(0)]],
                          constant SimUniforms &U [[buffer(1)]],
                          uint id [[thread_position_in_grid]]) {
    if (id >= U.grainCount || id < U.scatterFrom) return;
    uint s = pcgHash(id * 2654435761u + 977u);
    float2 p;
    if (U.shape == 0) {
        p = float2(random01(s), random01(s)) * 2.0 - 1.0;
    } else {
        float r = sqrt(random01(s)) * 0.995;
        float t = random01(s) * 2.0 * PI;
        p = float2(cos(t), sin(t)) * r;
    }
    grains[id].a = float4(p, 0.0, 0.0);
    grains[id].b = float4(0.0, 0.0, random01(s), 0.0);
}

// Each grain sits still until the plate under it accelerates harder than gravity; then
// it is thrown in a random direction and lands somewhere else. Grains only come to rest
// where the plate barely moves, so the sand collects on the nodal lines by itself.
kernel void simulateGrains(device Grain *grains [[buffer(0)]],
                           constant SimUniforms &U [[buffer(1)]],
                           device const float *profiles [[buffer(2)]],
                           texture2d<float> clockField [[texture(0)]],
                           uint id [[thread_position_in_grid]]) {
    if (id >= U.grainCount) return;
    Grain g = grains[id];
    float2 pos = g.a.xy;
    float height = g.a.z;
    float rise = g.a.w;
    float2 vel = g.b.xy;
    float spark = g.b.w;
    uint s = pcgHash(id * 9781u + U.frame * 6271u + 17u);
    float dt = U.dt;
    float clockMix = U.clock.x;

    if (height <= 0.0) {
        float energy = 0.0;
        float2 toward = float2(0.0);
        // A still plate (silence, music mode) cannot throw anything: skip the field.
        if (clockMix < 1.0 && U.drive > 0.0) energy += (1.0 - clockMix) * plateEnergy(pos, U, profiles);
        if (clockMix > 0.0) energy += clockMix * max(U.clockCount > 0 ? clockEnergy(pos, clockField, U.clock.w, toward) : 0.0, U.clock.y);
        float accel = U.drive * U.gain * sqrt(energy);   // plate acceleration in units of g
        float launch = smoothstep(U.threshold, U.threshold * 1.6, accel);
        if (launch > 0.0 && random01(s) < launch * (1.0 - exp(-dt * 55.0))) {
            float strength = sqrt(max(accel - U.threshold, 0.0));
            float angle = random01(s) * 2.0 * PI;
            // Clock strokes are not eigenmodes, so the hops are steered toward the
            // nearest stroke to let a new digit form within a second.
            float2 heading = float2(cos(angle), sin(angle)) + toward * (U.clock.z * clockMix);
            heading /= max(length(heading), 1e-4);
            vel = heading * U.hopSide * strength * (0.3 + 0.7 * random01(s));
            rise = U.hopUp * strength * (0.6 + 0.8 * random01(s));
            height = 1e-5;
            spark = 1.0;
        } else if (clockMix > 0.0 && random01(s) < U.sprinkle.x * clockMix * dt) {
            // Now and then a settled grain is tossed across the plate, so strokes that
            // appear in empty space (a growing ring, a new digit) still receive sand.
            float angle = random01(s) * 2.0 * PI;
            vel = float2(cos(angle), sin(angle)) * U.sprinkle.y * (0.4 + 0.6 * random01(s));
            rise = U.sprinkle.z * (0.5 + 0.5 * random01(s));
            height = 1e-5;
        } else {
            vel *= exp(-dt * 30.0);
            pos += vel * dt;
        }
    }
    if (height > 0.0) {
        rise -= U.gravity * dt;
        height += rise * dt;
        pos += vel * dt;
        if (height <= 0.0) {
            height = 0.0;
            rise = 0.0;
            vel *= 0.25;
        }
    }
    spark = max(spark - dt * 2.5, 0.0);

    // The plate rim reflects grains back.
    if (U.shape == 0) {
        if (abs(pos.x) > 1.0) { pos.x = sign(pos.x) * (2.0 - abs(pos.x)); vel.x = -0.5 * vel.x; }
        if (abs(pos.y) > 1.0) { pos.y = sign(pos.y) * (2.0 - abs(pos.y)); vel.y = -0.5 * vel.y; }
        pos = clamp(pos, -0.999, 0.999);
    } else {
        float r = length(pos);
        if (r > 0.999) {
            float2 normal = pos / r;
            pos = normal * min(2.0 * 0.999 - r, 0.999);
            vel = reflect(vel, normal) * 0.5;
        }
    }

    g.a = float4(pos, height, rise);
    g.b = float4(vel, g.b.z, spark);
    grains[id] = g;
}

// ---------------------------------------------------------------------------
// Sand rendering
// ---------------------------------------------------------------------------

struct GrainOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    float3 color;
};

vertex GrainOut grainVertex(device const Grain *grains [[buffer(0)]],
                            constant DrawUniforms &D [[buffer(1)]],
                            uint vid [[vertex_id]]) {
    Grain g = grains[vid];
    float4 clip = D.viewProjection * float4(g.a.x, g.a.z, g.a.y, 1.0);
    uint h = pcgHash(as_type<uint>(g.b.z));
    float tone = 0.65 + 0.7 * float(h & 1023u) / 1023.0;

    // Each grain is a tiny crystal facet. It flashes when its normal bisects the light
    // and the eye, so the glitter wanders as the camera orbits.
    float3 facet = normalize(float3(float((h >> 10) & 255u) / 127.5 - 1.0, 1.4,
                                    float((h >> 18) & 255u) / 127.5 - 1.0));
    float glint = pow(saturate(dot(facet, D.halfVector.xyz)), 120.0) * D.halfVector.w;
    float lift = saturate(g.a.z / 0.012);
    float twinkle = 0.55 + 0.45 * sin(D.time * 19.0 + float(h & 4095u));

    GrainOut out;
    out.position = clip;
    out.pointSize = max(D.pointSize * (1.0 + 0.5 * lift) * (6.0 / clip.w), 1.0);
    out.color = D.sandColor.rgb * D.intensity * tone
              + D.sparkColor.rgb * (glint + D.sparkle * (lift * twinkle + 0.12 * g.b.w));
    return out;
}

fragment float4 grainFragment(GrainOut in [[stage_in]], float2 pc [[point_coord]]) {
    float falloff = saturate(1.0 - length(pc - 0.5) * 2.0);
    return float4(in.color * falloff * falloff, 0.0);
}

struct RimOut { float4 position [[position]]; };

vertex RimOut rimVertex(constant float4 *points [[buffer(0)]],
                        constant DrawUniforms &D [[buffer(1)]],
                        uint vid [[vertex_id]]) {
    RimOut out;
    out.position = D.viewProjection * float4(points[vid].xyz, 1.0);
    return out;
}

fragment float4 rimFragment(constant float4 &color [[buffer(0)]]) {
    return color;
}

// ---------------------------------------------------------------------------
// Bloom (dual filter) and composite
// ---------------------------------------------------------------------------

struct FullscreenOut { float4 position [[position]]; float2 uv; };

vertex FullscreenOut fullscreenVertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    FullscreenOut out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    out.uv = float2(p.x, 1.0 - p.y);
    return out;
}

fragment float4 bloomDownsample(FullscreenOut in [[stage_in]], texture2d<float> source [[texture(0)]]) {
    float2 o = 1.0 / float2(source.get_width(), source.get_height());
    float3 c = source.sample(linearClamp, in.uv).rgb * 4.0;
    c += source.sample(linearClamp, in.uv + float2(-o.x, -o.y)).rgb;
    c += source.sample(linearClamp, in.uv + float2( o.x, -o.y)).rgb;
    c += source.sample(linearClamp, in.uv + float2(-o.x,  o.y)).rgb;
    c += source.sample(linearClamp, in.uv + float2( o.x,  o.y)).rgb;
    return float4(c / 8.0, 1.0);
}

fragment float4 bloomUpsample(FullscreenOut in [[stage_in]], texture2d<float> source [[texture(0)]]) {
    float2 o = 1.0 / float2(source.get_width(), source.get_height());
    float3 c = source.sample(linearClamp, in.uv + float2(-o.x, 0.0)).rgb;
    c += source.sample(linearClamp, in.uv + float2( o.x, 0.0)).rgb;
    c += source.sample(linearClamp, in.uv + float2(0.0, -o.y)).rgb;
    c += source.sample(linearClamp, in.uv + float2(0.0,  o.y)).rgb;
    c += source.sample(linearClamp, in.uv + float2(-0.5 * o.x, -0.5 * o.y)).rgb * 2.0;
    c += source.sample(linearClamp, in.uv + float2( 0.5 * o.x, -0.5 * o.y)).rgb * 2.0;
    c += source.sample(linearClamp, in.uv + float2(-0.5 * o.x,  0.5 * o.y)).rgb * 2.0;
    c += source.sample(linearClamp, in.uv + float2( 0.5 * o.x,  0.5 * o.y)).rgb * 2.0;
    return float4(c / 12.0, 1.0);
}

fragment float4 compositeFragment(FullscreenOut in [[stage_in]],
                                  texture2d<float> scene [[texture(0)]],
                                  texture2d<float> bloom [[texture(1)]],
                                  constant CompositeUniforms &C [[buffer(0)]]) {
    float3 c = scene.sample(linearClamp, in.uv).rgb + bloom.sample(linearClamp, in.uv).rgb * C.bloomStrength;
    c *= C.exposure;
    // Linear up to 70% of the available headroom, then a soft shoulder (EDR on XDR).
    // Applied to the brightest channel and scaled back, so dense gold stays gold
    // instead of bleaching to white.
    float knee = C.headroom * 0.7;
    float span = C.headroom - knee;
    float peak = max(c.r, max(c.g, c.b));
    float mapped = min(peak, knee) + span * (1.0 - exp(-max(peak - knee, 0.0) / span));
    c *= mapped / max(peak, 1e-5);
    // Keep empty space at exactly zero so the mini-LED zones there stay off.
    c = max(c - C.blackFloor, 0.0);
    return float4(c, 1.0);
}
"""#
}
