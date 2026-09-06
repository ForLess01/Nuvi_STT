/// The ferrofluid fragment shader, embedded as source and compiled at runtime.
///
/// Dual-style ferrofluid model:
/// 1. Organic Liquid Style (u.style <= 0.5):
///    - Continuous scalar potential field with stretched metaballs and smooth undulating lobes.
///    - Analytical capillary catenoid bridges for surface tension without geometric cusps.
/// 2. Magnetic Spikes Style (u.style > 0.5):
///    - Conical Rosensweig instability spikes along magnetic field lines.
///    - Polynomial smooth minimum (smin) and dynamic satellite droplet ejections.
/// Shared between both styles:
/// - Multi-band real FFT acoustic driving (bass, mid, treble).
/// - PBR Magnetic Oil Shading (Schlick Fresnel F0=0.12, dual specular highlights,
///   crevice ambient occlusion/contact shadow, and rim lighting).
let FerrofluidShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float time;
    float level;
    float2 resolution;
    float coreSize;
    float reach;
    float spikiness;
    float viscosity;
    float speed;
    float spikeCount;
    // Colors as individual floats (not float3) to keep the Swift/Metal struct
    // layout identical — float3 would force 16-byte alignment and corrupt the
    // uniform buffer when appended after a run of scalars.
    float fluidR;
    float fluidG;
    float fluidB;
    float bgR;
    float bgG;
    float bgB;
    float bass;
    float mid;
    float treble;
    float style; // 0.0 = organic liquid, 1.0 = magnetic spikes
    float coreSens;
    float dropletSens;
};

struct VOut {
    float4 position [[position]];
    float2 uv;
};

vertex VOut nuvi_vertex(uint vid [[vertex_id]]) {
    float2 p[6] = { float2(-1,-1), float2(1,-1), float2(-1,1),
                    float2(-1, 1), float2(1,-1), float2( 1,1) };
    VOut o;
    o.position = float4(p[vid], 0.0, 1.0);
    o.uv = p[vid];
    return o;
}

static inline float hash21(float2 p) {
    p = fract(p * float2(234.34, 435.345));
    p += dot(p, p + 34.345);
    return fract(p.x * p.y);
}

static inline float vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float a = hash21(i);
    float b = hash21(i + float2(1, 0));
    float c = hash21(i + float2(0, 1));
    float d = hash21(i + float2(1, 1));
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

static inline float fbm(float2 p) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 4; i++) {
        v += a * vnoise(p);
        p = p * 2.03 + float2(7.13, -3.71);
        a *= 0.5;
    }
    return v;
}

// Polynomial smooth minimum (surface tension / coalescence blend for Spikes style)
static inline float smin(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

// -----------------------------------------------------------------------------
// STYLE 1: ORGANIC LIQUID (Smooth Metaballs & Capillary Catenoid Bridges)
// -----------------------------------------------------------------------------

static inline float organicLobes(float2 sample, float2 center, float radius,
                                 float energy, float lobes, float index, float time,
                                 float spikiness) {
    float2 d = sample - center;
    float dist = length(d);
    if (dist > radius * 2.8) { return 0.0; }

    float angle = atan2(d.y, d.x);
    float smoothWave = 0.5 + 0.5 * sin(angle * lobes + time * (1.35 + index * 0.12));
    float detail = fbm(d * (2.4 + index * 0.18) + float2(time * 0.16, -time * 0.14));
    float rounded = mix(smoothWave, detail, 0.28);
    float spikeFactor = clamp(spikiness / 3.5, 0.6, 1.4);
    return (rounded - 0.45) * energy * radius * (0.32 * spikeFactor);
}

static inline float stretchedMetaball(float2 sample, float2 center, float radius,
                                      float2 velocityAxis, float stretch) {
    float2 d = sample - center;
    float speed = length(velocityAxis);
    if (speed > 0.0001) {
        float2 axis = velocityAxis / speed;
        float2 normal = float2(-axis.y, axis.x);
        float along = dot(d, axis);
        float across = dot(d, normal);
        d = axis * (along / stretch) + normal * (across * stretch);
    }

    float dd = dot(d, d) + 0.00012;
    return pow((radius * radius) / dd, 1.15);
}

static inline float organicChamberField(float2 uv, constant Uniforms& u) {
    float t = u.time * max(0.08, u.speed);
    float lvl = clamp(u.level, 0.0, 1.0);
    float bass = clamp(u.bass, 0.0, 1.0);
    float mid = clamp(u.mid, 0.0, 1.0);
    float treble = clamp(u.treble, 0.0, 1.0);

    float breath = 0.5 + 0.5 * sin(t * 1.5);
    float energy = smoothstep(0.02, 0.72, lvl);

    float2 warp = float2(fbm(uv * 1.8 + float2(0.0, t * 0.22)),
                         fbm(uv * 1.8 + float2(4.7, -t * 0.19))) - 0.5;
    float2 p = uv + warp * (0.028 + (0.055 * energy + 0.035 * bass) * u.coreSens);

    float field = 0.0;
    float2 cCore = float2(0.0, -0.045);

    float coreRadius = u.coreSize * (1.08 + (0.22 * energy + 0.22 * bass) * u.coreSens) + 0.010 * breath;
    float coreLobe = organicLobes(p, cCore, coreRadius,
                                  (0.16 + energy * 0.24 + bass * 0.15) * u.coreSens, 3.0, 0.0, t, u.spikiness);
    field += stretchedMetaball(p, cCore, coreRadius + coreLobe,
                               float2(0.025 * sin(t), 0.018 * cos(t * 0.8)) * (1.0 + (energy * 0.40 + bass * 0.40) * u.coreSens),
                               1.0 + (energy * 0.06 + bass * 0.05) * u.coreSens);

    for (int i = 1; i < 8; i++) {
        float fi = float(i);
        float seed = hash21(float2(fi, 9.17));
        float baseAngle = fi * 2.399963 + seed * 0.9;
        float orbit = t * (0.16 + 0.04 * seed) + sin(t * 0.25 + fi) * 0.12;
        float angle = baseAngle + orbit;

        // Dedicated acoustic frequency mapping per satellite:
        // i = 1, 2: Bass (chest resonance, low pitch)
        // i = 3, 4, 5: Mid (speech fundamental, vowel formants)
        // i = 6, 7: Treble (sibilants, consonants, breath)
        float freqBand = (i <= 2) ? bass : ((i <= 5) ? mid : treble);

        // Direct real-time audio drive without synthetic sine multipliers
        float band = clamp((freqBand * 1.30 + energy * 0.15) * u.dropletSens, 0.0, 1.0);

        float restDistance = u.coreSize * (0.35 + 0.10 * seed);
        float pushedDistance = u.coreSize * (0.65 + seed * 0.32) + u.reach * band * (0.35 * u.dropletSens);
        float cohesion = 1.0 - exp(-3.2 * (energy * 0.70 + freqBand * 0.70) * u.dropletSens);
        float distance = mix(restDistance, pushedDistance, cohesion);

        float2 radial = float2(cos(angle), sin(angle));
        float2 tangent = float2(-radial.y, radial.x);
        float2 center = cCore + radial * distance + tangent * (0.012 * sin(t * 1.2 + fi));

        float baseRadius = u.coreSize * mix(0.28, 0.52, hash21(float2(fi, 2.4)));
        baseRadius *= (1.0 + band * 0.25 * u.dropletSens);

        float lobes = mix(2.0, 5.0, hash21(float2(fi, 5.8)));
        float lobeOffset = organicLobes(p, center, baseRadius, band * u.dropletSens, lobes, fi, t, u.spikiness);

        float2 velocityAxis = normalize(radial * (0.55 + band) + tangent * (0.28 + seed * 0.34));
        float stretch = clamp(1.0 + band * (0.16 + u.reach * 0.18) * u.dropletSens, 1.0, 1.35);

        field += stretchedMetaball(p, center, baseRadius + lobeOffset, velocityAxis, stretch);

        float2 toSat = center - cCore;
        float satDist = length(toSat);
        if (satDist > 0.001 && cohesion > 0.05) {
            float2 satAxis = toSat / satDist;
            float proj = clamp(dot(p - cCore, satAxis), 0.0, satDist);
            float2 bridgePoint = cCore + satAxis * proj;
            float dBridge = length(p - bridgePoint);

            float waist = sin((proj / satDist) * 3.14159265);
            float bridgeRadius = mix(coreRadius, baseRadius, proj / satDist) * (0.30 + 0.16 * (1.0 - waist));
            float bridgeField = (bridgeRadius * bridgeRadius) / (dBridge * dBridge + 0.00035);
            field += bridgeField * (cohesion * (0.26 + 0.10 * band));
        }
    }

    return field;
}

// -----------------------------------------------------------------------------
// STYLE 2: MAGNETIC SPIKES (Rosensweig Instability & Conical Spikes)
// -----------------------------------------------------------------------------

static inline float dropletSDF(float2 p, float2 center, float radius, float2 velocity, float stretch) {
    float2 d = p - center;
    float speed = length(velocity);
    if (speed > 0.001) {
        float2 dir = velocity / speed;
        float2 norm = float2(-dir.y, dir.x);
        float along = dot(d, dir);
        float across = dot(d, norm);
        d = dir * (along / stretch) + norm * (across * stretch);
    }
    return length(d) - radius;
}

static inline float spikesFluidSDF(float2 p, constant Uniforms& u, float t, float k) {
    float lvl = clamp(u.level, 0.0, 1.0);
    float bass = clamp(u.bass, 0.0, 1.0);
    float mid = clamp(u.mid, 0.0, 1.0);
    float treble = clamp(u.treble, 0.0, 1.0);

    float2 warp = float2(fbm(p * 2.1 + float2(0.0, t * 0.22)),
                         fbm(p * 2.1 + float2(4.7, -t * 0.19))) - 0.5;
    float2 wp = p + warp * (0.025 + 0.065 * bass * u.coreSens);

    float2 cCore = float2(0.0, -0.045);
    float2 dCoreVec = wp - cCore;
    float coreDist = length(dCoreVec);
    float theta = atan2(dCoreVec.y, dCoreVec.x);

    // Subtle magnetic micro-ripples: reduced by ~75% so it's not pointy or aggressive
    float spikeCount = max(6.0, u.spikeCount);
    float spikePhase = theta * spikeCount + t * 0.55;
    float cone = pow(max(0.0, cos(spikePhase)), max(1.1, u.spikiness * 2.0));
    float cone2 = pow(max(0.0, cos(spikePhase * 2.0 - 1.2)), max(1.0, u.spikiness * 1.2)) * 0.25;
    float spikeHeight = (u.spikiness * 0.008 + treble * 0.016 * u.coreSens) * (cone + cone2);
    float microSpikes = sin(theta * (spikeCount * 2.5) + t * 4.2) * (treble * 0.006 * u.coreSens);

    float breath = 0.5 + 0.5 * sin(t * 1.5);
    float coreRadius = u.coreSize * (1.02 + (0.30 * bass + 0.12 * lvl) * u.coreSens) + 0.010 * breath;
    float dFluid = coreDist - (coreRadius + spikeHeight + microSpikes);

    for (int i = 1; i < 8; i++) {
        float fi = float(i);
        float seed = hash21(float2(fi, 9.17));
        float baseAngle = fi * 2.399963 + seed * 0.9;
        float orbit = t * (0.16 + 0.04 * seed) + sin(t * 0.25 + fi) * 0.12;
        float angle = baseAngle + orbit;

        float freqBand = (i <= 2) ? bass : ((i <= 5) ? mid : treble);
        float ejection = clamp((freqBand * 1.30 + lvl * 0.15) * u.dropletSens, 0.0, 1.0);

        float restDist = u.coreSize * (0.35 + 0.10 * seed);
        float pushedDist = u.coreSize * (0.70 + seed * 0.35) + u.reach * (0.28 + 0.38 * ejection) * u.dropletSens + bass * 0.10;
        float dist = mix(restDist, pushedDist, ejection);

        float2 radial = float2(cos(angle), sin(angle));
        float2 tangent = float2(-radial.y, radial.x);
        float2 center = cCore + radial * dist + tangent * (0.014 * sin(t * 1.2 + fi));

        float radius = u.coreSize * mix(0.24, 0.48, hash21(float2(fi, 2.4)));
        radius *= (1.0 + ejection * 0.20 * u.dropletSens + bass * 0.08);

        float2 velocity = normalize(radial * (0.50 + ejection) + tangent * (0.28 + seed * 0.32));
        float stretch = clamp(1.0 + ejection * (0.20 + u.reach * 0.18) * u.dropletSens, 1.0, 1.45);

        // Subtle micro-surface ripple on satellite
        float satTheta = atan2(wp.y - center.y, wp.x - center.x);
        float satSpike = pow(max(0.0, cos(satTheta * 4.0 + t * 2.2 + fi)), 2.2) * (treble * 0.005 * u.spikiness);

        float dSat = dropletSDF(wp, center, radius + satSpike, velocity, stretch);
        dFluid = smin(dFluid, dSat, k);
    }

    return dFluid;
}

// -----------------------------------------------------------------------------
// UNIFIED FRAGMENT SHADER (PBR Magnetic Liquid Shading)
// -----------------------------------------------------------------------------

fragment float4 nuvi_fragment(VOut in [[stage_in]],
                              constant Uniforms& u [[buffer(0)]]) {
    float2 uv = in.uv;
    float distFromCenter = length(uv);

    float disk = smoothstep(1.0, 0.972, distFromCenter);
    if (disk <= 0.001) { return float4(0.0); }

    float t = u.time * max(0.08, u.speed);
    float ink = 0.0;
    float contact = 0.0;
    float3 normal = float3(0.0, 0.0, 1.0);

    if (u.style > 0.5) {
        // --- Magnetic Spikes Style ---
        float k = mix(0.06, 0.18, clamp(u.viscosity * 2.5, 0.0, 1.0));
        float d = spikesFluidSDF(uv, u, t, k);
        float pixelSize = 2.0 / max(u.resolution.x, 1.0);
        float edge = clamp(0.003 + u.viscosity * 0.006, pixelSize, 0.018);
        ink = smoothstep(edge, -edge, d);
        contact = smoothstep(0.08, 0.0, d) * (1.0 - ink) * 0.28;

        float2 eps = float2(0.008, 0.0);
        float dX = spikesFluidSDF(uv + eps.xy, u, t, k) - spikesFluidSDF(uv - eps.xy, u, t, k);
        float dY = spikesFluidSDF(uv + eps.yx, u, t, k) - spikesFluidSDF(uv - eps.yx, u, t, k);
        float2 grad = float2(dX, dY) / (2.0 * eps.x);
        float nz = max(0.22, 1.0 - clamp(-d / 0.08, 0.0, 0.95));
        normal = normalize(float3(grad.x, grad.y, nz));
    } else {
        // --- Organic Liquid Style ---
        float field = organicChamberField(uv, u);
        float edgeWidth = clamp(0.045 + u.viscosity * 2.6, 0.035, 0.18);
        ink = smoothstep(1.05 - edgeWidth, 1.05 + edgeWidth, field);
        contact = smoothstep(0.20, 1.08, field) * (1.0 - ink);

        float2 eps = float2(0.008, 0.0);
        float fx = organicChamberField(uv + eps.xy, u) - organicChamberField(uv - eps.xy, u);
        float fy = organicChamberField(uv + eps.yx, u) - organicChamberField(uv - eps.yx, u);
        normal = normalize(float3(fx, fy, 0.40));
    }

    ink *= smoothstep(0.97, 0.76, distFromCenter);

    float3 bgColor = float3(u.bgR, u.bgG, u.bgB);
    float3 fluidColor = float3(u.fluidR, u.fluidG, u.fluidB);

    // Backlit chamber background with contact shadow
    float vignette = smoothstep(1.0, 0.15, distFromCenter);
    float3 chamber = bgColor - vignette * 0.045 - contact * 0.20;

    float3 lightA = normalize(float3(-0.45, -0.62, 1.0));
    float3 lightB = normalize(float3(0.72, 0.34, 0.85));
    float diffuse = max(dot(normal, lightA), 0.0) * 0.38 + max(dot(normal, lightB), 0.0) * 0.16;
    float3 view = float3(0.0, 0.0, 1.0);

    // Schlick Fresnel approximation for magnetic liquid
    float F0 = 0.12;
    float cosTheta = max(dot(normal, view), 0.0);
    float fresnel = F0 + (1.0 - F0) * pow(1.0 - cosTheta, 5.0);

    float specA = pow(max(dot(reflect(-lightA, normal), view), 0.0), 42.0);
    float specB = pow(max(dot(reflect(-lightB, normal), view), 0.0), 24.0) * 0.24;

    float rim = pow(1.0 - cosTheta, 3.2);

    float fluidLum = dot(fluidColor, float3(0.299, 0.587, 0.114));
    float darkLift = mix(0.16, 0.06, smoothstep(0.0, 0.5, fluidLum));
    float3 fluid = fluidColor + diffuse * darkLift;

    float3 specTint = mix(float3(0.95, 0.97, 1.0), normalize(fluidColor + 0.001), 0.35);
    fluid += (specA + specB) * specTint * (1.0 + fresnel * 0.5);

    fluid += rim * (fluidColor * 0.35 + 0.03) * (0.6 + u.level);

    float3 color = mix(chamber, fluid, ink);

    float bgLum = dot(bgColor, float3(0.299, 0.587, 0.114));
    float rimShade = smoothstep(0.78, 1.0, distFromCenter);
    color -= rimShade * mix(0.04, 0.11, smoothstep(0.2, 0.9, bgLum));
    color += smoothstep(0.22, 0.0, length(uv - float2(-0.32, -0.42))) * 0.045 * (0.3 + bgLum);

    return float4(clamp(color, 0.0, 1.0), disk);
}
"""
