#include <metal_stdlib>
using namespace metal;

struct GlassUniforms {
    float4 tint;
    float4 capture;
    float4 mapping;
    float4 touch;
    float4 shape;
    float4 optics;
    float4 finish;
};

struct GlassVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex GlassVertexOut glassVertex(uint vertexID [[vertex_id]]) {
    float2 corner = float2((vertexID << 1) & 2, vertexID & 2);
    GlassVertexOut out;
    out.position = float4(corner * 2.0 - 1.0, 0.0, 1.0);
    out.uv = float2(corner.x, 1.0 - corner.y);
    return out;
}

static float roundedBoxDistance(float2 p, float2 halfSize, float radius) {
    float2 q = abs(p) - halfSize + radius;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

static float2 outwardGradient(float2 p, float2 halfSize, float radius) {
    const float e = 0.5;
    float2 g = float2(
        roundedBoxDistance(p + float2(e, 0), halfSize, radius) - roundedBoxDistance(p - float2(e, 0), halfSize, radius),
        roundedBoxDistance(p + float2(0, e), halfSize, radius) - roundedBoxDistance(p - float2(0, e), halfSize, radius)
    );
    float len = length(g);
    return len > 1e-5 ? g / len : float2(0.0);
}

fragment float4 glassFragment(
    GlassVertexOut in [[stage_in]],
    constant GlassUniforms &u [[buffer(0)]],
    texture2d<float> backdrop [[texture(0)]]
) {
    constexpr sampler backdropSampler(coord::normalized, address::clamp_to_edge, filter::linear);

    float2 size = u.shape.xy;
    float radius = u.shape.z;
    float bezel = max(u.shape.w, 1e-3);
    float2 local = in.uv * size;
    float2 halfSize = 0.5 * size;
    float2 p = local - halfSize;
    float pixel = max(fwidth(local.x), 1e-4);

    float distance = roundedBoxDistance(p, halfSize, radius);
    float coverage = 1.0 - smoothstep(-0.5 * pixel, 0.5 * pixel, distance);
    if (coverage <= 0.0) {
        return float4(0.0);
    }

    float press = saturate(u.mapping.w);
    float refraction = u.optics.x * (1.0 + 0.1 * press);
    float thickness = refraction * bezel;
    float2 gradient = outwardGradient(p, halfSize, radius);
    float rimDepth = 1.0 - clamp(-distance / bezel, 0.0, 1.0);
    // Sampling outward pulls content from past the edge into the rim; inward sampling only smears the rim.
    float2 refracted = gradient * thickness * rimDepth * rimDepth;

    float2 toTouch = local - u.touch.xy;
    float touchFalloff = 1.0 - smoothstep(0.0, max(u.touch.z, 1.0), length(toTouch));
    float2 bulge = -toTouch * u.touch.w * press * touchFalloff * touchFalloff;

    float aberration = u.optics.y;
    float3 color;
    for (int channel = 0; channel < 3; channel++) {
        float spread = 1.0 + aberration * float(1 - channel);
        float2 samplePoint = u.mapping.xy + (local + bulge + refracted * spread) * u.mapping.z;
        float2 uv = (samplePoint - u.capture.xy) / u.capture.zw;
        color[channel] = backdrop.sample(backdropSampler, uv)[channel];
    }

    float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
    color = mix(float3(luma), color, u.optics.z);
    color = mix(color, u.tint.rgb, u.tint.a);

    float2 light = normalize(float2(-0.6, -0.8));
    float rim = 1.0 - smoothstep(0.0, 2.5, -distance);
    float specular = pow(saturate(dot(gradient, light)), 2.0) + 0.4 * pow(saturate(dot(gradient, -light)), 2.0);
    float glow = press * 0.22 * touchFalloff * touchFalloff;
    color += float3(u.optics.w * rim * specular + glow);

    float alpha = coverage * u.finish.x;
    return float4(saturate(color) * alpha, alpha);
}
