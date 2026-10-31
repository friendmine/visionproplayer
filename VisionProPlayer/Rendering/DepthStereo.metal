#include <metal_stdlib>
using namespace metal;
constexpr sampler linearClamp(coord::normalized, address::clamp_to_edge, filter::linear);

kernel void stabilizeDepth(texture2d<float, access::sample> raw [[texture(0)]],
                           texture2d<float, access::sample> previous [[texture(1)]],
                           texture2d<half, access::write> output [[texture(2)]],
                           constant float4 &params [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
    if (p.x >= output.get_width() || p.y >= output.get_height()) return;
    float2 step = 1.0 / float2(output.get_width(), output.get_height());
    float2 uv = (float2(p) + 0.5) * step;
    float center = clamp((raw.sample(linearClamp, uv).r - params.x) * params.y, 0.0, 1.0);
    float value = center;
    float weight = 1.0;
    // Edge-aware smoothing: do not blend foreground depth into the background.
    const float2 offsets[4] = {float2(1,0), float2(-1,0), float2(0,1), float2(0,-1)};
    for (int i = 0; i < 4; ++i) {
        float neighbor = clamp((raw.sample(linearClamp, uv + offsets[i] * step).r - params.x) * params.y, 0.0, 1.0);
        float w = 0.25 * exp(-40.0 * abs(neighbor - center));
        value += neighbor * w; weight += w;
    }
    float d = value / weight;
    float old = previous.sample(linearClamp, uv).r;
    // Smooth small variations, but follow moving depth boundaries without a long trail.
    if (params.z < 0.5 && abs(old - d) < 0.08) d = mix(old, d, 0.4);
    output.write(half4(half(d),0,0,1), p);
}

float3 srgbToLinear(float3 c) {
    return select(c / 12.92, pow((c + 0.055) / 1.055, float3(2.4)), c > 0.04045);
}

// params: strength, pop-out, maximum front disparity, maximum rear disparity.
float disparity(float nearDepth, float2 source, float4 params) {
    float border = smoothstep(0.0, 0.04, min(source.x, 1.0 - source.x))
                 * smoothstep(0.0, 0.025, min(source.y, 1.0 - source.y));
    // Translate the full depth range so a subject need not be in the nearest
    // depth percentile to cross the screen plane. Fit the range before moving
    // it; clipping every near pixel to one disparity would flatten the scene.
    float span = min(0.012 * params.x, min(params.z, params.w));
    float relief = (nearDepth - 0.5) * span;
    float headroom = max(0.0, (params.z - span) * 0.5);
    float push = params.y * headroom * smoothstep(0.0, 0.25, params.x);
    return (relief + push) * border;
}

float2 sourceUV(float2 target, float eye, float4 params, texture2d<float, access::sample> depth,
                float pixelWidth) {
    if (params.x <= 0.0) return target;
    float2 uv = target;
    for (int i = 0; i < 3; ++i) {
        float shift = disparity(depth.sample(linearClamp, uv).r, uv, params);
        uv.x = clamp(target.x - eye * shift, 0.0, 1.0);
    }
    float bestDepth = -1.0;
    float bestError = 1e9;
    float2 chosen = uv;
    float backgroundDepth = 2.0;
    float2 background = target;
    // Resolve overlapping projections in favor of the foreground. If no source
    // covers the pixel, extend nearby background instead of smearing foreground.
    // This is bounded local reconstruction, not generated unseen image content.
    for (int i = 0; i < 6; ++i) {
        float2 probe = i == 0 ? uv : target;
        if (i >= 2) probe.x = clamp(target.x + (i % 2 == 0 ? -1.0 : 1.0) * (i >= 4 ? 0.25 : 0.5) * max(params.z, params.w), 0.0, 1.0);
        float sampled = depth.sample(linearClamp, probe).r;
        if (sampled < backgroundDepth) { backgroundDepth = sampled; background = probe; }
        float2 candidate = float2(clamp(target.x - eye * disparity(sampled, probe, params), 0.0, 1.0), target.y);
        float d = depth.sample(linearClamp, candidate).r;
        float error = abs(candidate.x + eye * disparity(d, candidate, params) - target.x);
        if (error <= pixelWidth && (d > bestDepth + 0.02 || (abs(d - bestDepth) <= 0.02 && error < bestError))) {
            chosen = candidate; bestDepth = d; bestError = error;
        }
    }
    return bestDepth >= 0.0 ? chosen : background;
}

kernel void synthesizeStereo(texture2d<float, access::sample> color [[texture(0)]],
                             texture2d<float, access::sample> depth [[texture(1)]],
                             texture2d<half, access::write> left [[texture(2)]],
                             texture2d<half, access::write> right [[texture(3)]],
                             constant float4 &params [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
    if (p.x >= left.get_width() || p.y >= left.get_height()) return;
    float2 uv = (float2(p) + 0.5) / float2(left.get_width(), left.get_height());
    // CVMetalTexture rows already match the final texture produced by the
    // existing Core Image path. Flipping again would turn the video upside down.
    float3 l = color.sample(linearClamp, sourceUV(uv, 1, params, depth, 1.0 / left.get_width())).rgb;
    float3 r = color.sample(linearClamp, sourceUV(uv, -1, params, depth, 1.0 / right.get_width())).rgb;
    left.write(half4(half3(srgbToLinear(l)), 1), p);
    right.write(half4(half3(srgbToLinear(r)), 1), p);
}
