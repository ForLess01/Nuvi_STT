/// The ferrofluid fragment shader, embedded as source and compiled at runtime.
///
/// Organic chamber model: one cohesive core plus seven satellite droplets. Audio
/// energy pushes satellites outward, magnetic cohesion pulls them back, and each
/// droplet deforms with unique lobes and velocity-like teardrop stretching. This
/// is intentionally inspired by physical ferrofluid/metaball behavior rather
/// than a decorative radial star.
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
    p = fract(p * float2(123.34, 345.45));
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
    for (int i = 0; i < 5; i++) {
        v += a * vnoise(p);
        p = p * 2.03 + float2(7.13, -3.71);
        a *= 0.5;
    }
    return v;
}

static inline float organicLobes(float2 sample, float2 center, float radius,
                                 float energy, float lobes, float index, float time,
                                 float spikiness) {
    float2 d = sample - center;
    float dist = length(d);
    if (dist > radius * 3.2) { return 0.0; }

    float angle = atan2(d.y, d.x);
    float wave = sin(angle * lobes + time * (1.7 + index * 0.13));
    float detail = fbm(d * (5.4 + index * 0.37) + float2(time * 0.22, -time * 0.18));
    float rounded = pow(abs(wave) * 0.72 + detail * 0.35, max(1.0, spikiness * 0.58));
    return (rounded - 0.28) * energy * radius * 0.56;
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

    float dd = dot(d, d) + 0.00008;
    return pow((radius * radius) / dd, 1.18);
}

static inline float chamberField(float2 uv, constant Uniforms& u) {
    float t = u.time * max(0.08, u.speed);
    float lvl = clamp(u.level, 0.0, 1.0);
    float breath = 0.5 + 0.5 * sin(t * 1.65);
    float energy = smoothstep(0.02, 0.72, lvl);

    // Low-frequency domain warp: the entire chamber breathes like viscous oil.
    float2 warp = float2(fbm(uv * 2.05 + float2(0.0, t * 0.28)),
                         fbm(uv * 2.05 + float2(4.7, -t * 0.24))) - 0.5;
    float2 p = uv + warp * (0.035 + 0.095 * energy);

    float field = 0.0;

    // Core: heavy, cohesive, almost always near center.
    float coreRadius = u.coreSize * (1.08 + 0.22 * energy) + 0.011 * breath;
    float coreLobe = organicLobes(p, float2(0.0, -0.045), coreRadius,
                                  0.18 + energy * 0.28, 3.0, 0.0, t, u.spikiness);
    field += stretchedMetaball(p, float2(0.0, -0.045), coreRadius + coreLobe,
                               float2(0.03 * sin(t), 0.02 * cos(t * 0.8)),
                               1.0 + energy * 0.10);

    // Seven satellites. They separate with audio, orbit subtly, then visually
    // fuse back through the metaball threshold.
    for (int i = 1; i < 8; i++) {
        float fi = float(i);
        float seed = hash21(float2(fi, 9.17));
        float baseAngle = fi * 2.399963 + seed * 0.9;
        float orbit = t * (0.24 + 0.08 * seed) + sin(t * 0.41 + fi) * 0.22;
        float angle = baseAngle + orbit;

        float band = 0.52 + 0.48 * sin(t * (1.1 + seed * 1.6) + fi * 1.37);
        band = smoothstep(0.12, 1.0, band * energy + lvl * (0.45 + seed * 0.25));

        float restDistance = u.coreSize * (0.36 + 0.12 * seed);
        float pushedDistance = u.coreSize * (0.68 + seed * 0.35) + u.reach * band * 0.31;
        float cohesion = 1.0 - exp(-2.8 * energy);
        float distance = mix(restDistance, pushedDistance, cohesion);

        float2 radial = float2(cos(angle), sin(angle));
        float2 tangent = float2(-radial.y, radial.x);
        float2 center = float2(0.0, -0.045) + radial * distance + tangent * (0.018 * sin(t * 1.4 + fi));

        float baseRadius = u.coreSize * mix(0.27, 0.58, hash21(float2(fi, 2.4)));
        baseRadius *= 1.0 + band * 0.24;

        float lobes = mix(2.0, 6.0, hash21(float2(fi, 5.8)));
        float lobeOffset = organicLobes(p, center, baseRadius, band, lobes, fi, t, u.spikiness);

        // Velocity-like direction: outward plus orbit tangent, enough to form
        // teardrops without needing persistent CPU physics state.
        float2 velocityAxis = normalize(radial * (0.55 + band) + tangent * (0.28 + seed * 0.34));
        float stretch = clamp(1.0 + band * (0.32 + u.reach * 0.32), 1.0, 1.95);

        field += stretchedMetaball(p, center, baseRadius + lobeOffset, velocityAxis, stretch);
    }

    // Thin bridge reinforcement near active speech creates the sticky oil necks
    // from the reference without producing random disconnected noise.
    float bridgeNoise = fbm(p * (4.8 + u.spikeCount * 0.22) + float2(t * 0.35, -t * 0.31));
    float ridge = 1.0 - abs(2.0 * bridgeNoise - 1.0);
    field += pow(clamp(ridge, 0.0, 1.0), 2.2) * clamp(field, 0.0, 1.0) * energy * 0.34;

    return field;
}

fragment float4 nuvi_fragment(VOut in [[stage_in]],
                              constant Uniforms& u [[buffer(0)]]) {
    float2 uv = in.uv;
    float distFromCenter = length(uv);

    // Round white chamber mask with soft hardware-like falloff.
    float disk = smoothstep(1.0, 0.972, distFromCenter);
    if (disk <= 0.001) { return float4(0.0); }

    float field = chamberField(uv, u);
    float lvl = clamp(u.level, 0.0, 1.0);
    float edgeWidth = clamp(0.045 + u.viscosity * 2.6, 0.035, 0.18);
    float ink = smoothstep(1.05 - edgeWidth, 1.05 + edgeWidth, field);
    ink *= smoothstep(0.97, 0.76, distFromCenter);

    float3 bgColor = float3(u.bgR, u.bgG, u.bgB);
    float3 fluidColor = float3(u.fluidR, u.fluidG, u.fluidB);

    // Contact shadow on the backlit chamber before fluid appears.
    float contact = smoothstep(0.20, 1.08, field) * (1.0 - ink);
    float vignette = smoothstep(1.0, 0.15, distFromCenter);
    float3 chamber = bgColor - vignette * 0.045 - contact * 0.20;

    // Surface normal from field derivatives for wet highlights.
    float2 eps = float2(0.010, 0.0);
    float fx = chamberField(uv + eps.xy, u) - chamberField(uv - eps.xy, u);
    float fy = chamberField(uv + eps.yx, u) - chamberField(uv - eps.yx, u);
    float3 normal = normalize(float3(fx, fy, 0.42));

    float3 lightA = normalize(float3(-0.45, -0.62, 1.0));
    float3 lightB = normalize(float3(0.72, 0.34, 0.85));
    float diffuse = max(dot(normal, lightA), 0.0) * 0.38 + max(dot(normal, lightB), 0.0) * 0.16;
    float3 view = float3(0.0, 0.0, 1.0);
    float specA = pow(max(dot(reflect(-lightA, normal), view), 0.0), 42.0);
    float specB = pow(max(dot(reflect(-lightB, normal), view), 0.0), 24.0) * 0.24;

    float rim = smoothstep(1.10, 1.45, field) * (1.0 - smoothstep(1.48, 2.3, field));

    // Base fluid is the chosen color, lifted slightly by diffuse light. Darker
    // fluids get a touch more lift so they don't read as a flat silhouette.
    float fluidLum = dot(fluidColor, float3(0.299, 0.587, 0.114));
    float darkLift = mix(0.16, 0.06, smoothstep(0.0, 0.5, fluidLum));
    float3 fluid = fluidColor + diffuse * darkLift;

    // Specular stays near-white but is tinted toward the fluid so colored fluids
    // keep wet, believable highlights instead of washing out to gray.
    float3 specTint = mix(float3(0.95, 0.97, 1.0), normalize(fluidColor + 0.001), 0.35);
    fluid += (specA + specB) * specTint;

    // Rim light picks up the fluid hue so the edge glows in-color.
    fluid += rim * (fluidColor * 0.35 + 0.03) * (0.6 + lvl);

    float3 color = mix(chamber, fluid, ink);

    // Subtle glass/chamber boundary shading, scaled by background brightness so
    // it darkens light chambers without crushing dark ones to black.
    float bgLum = dot(bgColor, float3(0.299, 0.587, 0.114));
    float rimShade = smoothstep(0.78, 1.0, distFromCenter);
    color -= rimShade * mix(0.04, 0.11, smoothstep(0.2, 0.9, bgLum));
    color += smoothstep(0.22, 0.0, length(uv - float2(-0.32, -0.42))) * 0.045 * (0.3 + bgLum);

    return float4(clamp(color, 0.0, 1.0), disk);
}
"""
