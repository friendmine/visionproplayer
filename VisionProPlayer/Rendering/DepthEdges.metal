#include <metal_stdlib>
using namespace metal;
constexpr sampler edgeLinear(coord::normalized, address::clamp_to_edge, filter::linear);
constexpr sampler edgeNearest(coord::normalized, address::clamp_to_edge, filter::nearest);

kernel void makeDepthEdgeGuide(texture2d<float, access::sample> color [[texture(0)]],
    texture2d<half, access::write> guide [[texture(1)]], uint2 p [[thread_position_in_grid]]) {
    if (p.x >= guide.get_width() || p.y >= guide.get_height()) return;
    float2 uv = (float2(p) + 0.5) / float2(guide.get_width(), guide.get_height());
    guide.write(half4(half3(log(1.0 + 32.0 * max(color.sample(edgeLinear, uv).rgb, 0.0))), 1), p);
}

kernel void refineDepthEdges(texture2d<float, access::sample> color [[texture(0)]],
    texture2d<float, access::sample> depth [[texture(1)]],
    texture2d<half, access::write> output [[texture(2)]],
    texture2d<float, access::sample> guideTexture [[texture(3)]],
    constant uint &hasConfidence [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
    if (p.x >= output.get_width() || p.y >= output.get_height()) return;
    float2 uv = (float2(p) + 0.5) / float2(output.get_width(), output.get_height());
    float2 size = float2(depth.get_width(), depth.get_height());
    float2 center = uv * size - 0.5;
    float2 base = floor(center);
    float2 original = depth.sample(edgeLinear, uv).rg;
    // Work in a perceptual RGB approximation so dark skin/clothing edges
    // still provide evidence, while exposure changes don't sharpen depth globally.
    float3 reference = log(1.0 + 32.0 * max(color.sample(edgeLinear, uv).rgb, 0.0));
    float weighted = 0, weight = 0, spatialDepth = 0, spatialWeight = 0;
    float low = original.r, high = original.r, nearestColor = 1e6;
    for (int y = -1; y <= 2; ++y) for (int x = -1; x <= 2; ++x) {
        float2 pixel = clamp(base + float2(x, y), 0.0, size - 1.0);
        float2 at = (pixel + 0.5) / size;
        float value = depth.sample(edgeNearest, at).r;
        float3 guide = guideTexture.sample(edgeNearest, at).rgb;
        float3 difference = guide - reference;
        float colorError = dot(difference, difference);
        float2 distance = pixel - center;
        float spatial = exp(-0.8 * dot(distance, distance));
        float w = spatial * exp(-32.0 * colorError);
        weighted += value * w; weight += w;
        spatialDepth += value * spatial; spatialWeight += spatial;
        low = min(low, value); high = max(high, value);
        nearestColor = min(nearestColor, colorError);
    }
    float guided = weighted / max(weight, 1e-6);
    float unguided = spatialDepth / max(spatialWeight, 1e-6);
    // Apply only the color-supported correction, not a general blur. Texture
    // on a constant-depth face stays flat; unsupported hair/background colors
    // and uncertain motion keep the old depth rather than inventing a surface.
    float support = 1.0 - smoothstep(0.02, 0.12, nearestColor);
    float confidence = hasConfidence != 0 ? smoothstep(0.15, 0.7, original.g) : 1.0;
    float edge = smoothstep(0.015, 0.08, high - low);
    float correction = clamp(guided - unguided, -0.35, 0.35);
    float result = clamp(original.r + correction * support * confidence * edge, low, high);
    output.write(half4(half(result), 0, 0, 1), p);
}
