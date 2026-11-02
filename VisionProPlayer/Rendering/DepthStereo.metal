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
    // Anchor distant scenery behind the screen instead of translating the
    // entire picture. A bounded, monotonic curve gives mid-foreground more
    // separation while retaining distinct layers at the nearest end.
    float strength = clamp(params.x, 0.0, 1.0);
    float amount = clamp(params.y, 0.0, 1.0);
    float relief = strength * (2.0 - strength);
    float activation = smoothstep(0.0, 0.25, strength);
    float nearRange = mix(min(0.012, params.z) * relief, params.z * activation, amount);
    float farRange = min(0.012, params.w) * relief;
    float convergence = mix(0.5, 0.35, amount);
    float offset = clamp(nearDepth, 0.0, 1.0) - convergence;
    float t = abs(offset) / (offset >= 0.0 ? 1.0 - convergence : convergence);
    float shaped = t * (2.0 - t);
    // Return per-eye displacement; nearRange/farRange are total binocular
    // disparities. Never clip all near layers to the same output disparity.
    float binocular = offset >= 0.0 ? shaped * nearRange : -shaped * farRange;
    return 0.5 * binocular * border;
}

// Bound the local warp gradient before projection. A noisy/offset depth edge
// must not fold the image over itself: such folds turn a single color contour
// into thin alternating islands, even with perfect temporal stability.
// Separate passes publish upper/lower envelopes between the two scans.
// Texture reads must not depend on writes earlier in the same invocation.
// Protected projection removes the top/bottom disparity taper: a row-dependent
// horizontal shift can shear a face or arm even though vertical UV is unchanged.
// Horizontal border coverage is still constrained to exactly zero at both ends.
float projectionDisparity(float d, float2 uv, float4 params, float4 protection) {
    return disparity(d, protection.z > 0.5 ? float2(uv.x, 0.5) : uv, params);
}

kernel void regularizeDisparityForward(texture2d<float, access::sample> depth [[texture(0)]],
    texture2d<float, access::write> scratch [[texture(1)]],
    constant float4 &params [[buffer(0)]], constant float4 &protection [[buffer(1)]],
    uint row [[thread_position_in_grid]]) {
    uint width = scratch.get_width(), height = scratch.get_height();
    if (row >= height) return;
    float step = protection.x / float(width - 1);
    float upper = -1.0, lower = 1.0;
    for (uint x = 0; x < width; ++x) {
        float2 uv = float2(x, row) / float2(width - 1, height - 1);
        float value = projectionDisparity(depth.sample(linearClamp, uv).r, uv, params, protection);
        upper = max(value, upper - step); lower = min(value, lower + step);
        scratch.write(float4(upper, lower, 0, 1), uint2(x, row));
    }
}

kernel void regularizeDisparity(texture2d<float, access::sample> depth [[texture(0)]],
    texture2d<float, access::read> scratch [[texture(1)]],
    texture2d<float, access::write> result [[texture(2)]],
    constant float4 &params [[buffer(0)]], constant float4 &protection [[buffer(1)]],
    uint row [[thread_position_in_grid]]) {
    uint width = result.get_width(), height = result.get_height();
    if (row >= height) return;
    float step = protection.x / float(width - 1);
    float upper = -1.0, lower = 1.0;
    for (int x = int(width) - 1; x >= 0; --x) {
        float2 uv = float2(x, row) / float2(width - 1, height - 1);
        float value = projectionDisparity(depth.sample(linearClamp, uv).r, uv, params, protection);
        upper = max(value, upper - step); lower = min(value, lower + step);
        float2 forward = scratch.read(uint2(x, row)).rg;
        float bounded = 0.5 * (max(upper, forward.x) + min(lower, forward.y));
        // Preserve exact outer-border coverage, without introducing a fold.
        float boundary = step * min(float(x), float(width - 1 - x));
        bounded = clamp(bounded, -boundary, boundary);
        result.write(float4(bounded, 0, 0, 1), uint2(x, row));
    }
}

// Column scans bound vertical shear as well as horizontal scaling. Min/max
// envelopes and their average preserve the row bound already established.
// Both passes use separate encoders and separate input/output textures.
kernel void protectProportionsForward(texture2d<float, access::read> field [[texture(0)]],
    texture2d<float, access::write> scratch [[texture(1)]],
    constant float4 &protection [[buffer(1)]], uint x [[thread_position_in_grid]]) {
    uint width = field.get_width(), height = field.get_height();
    if (x >= width) return;
    float step = protection.y / float(height - 1);
    float upper = -1.0, lower = 1.0;
    for (uint y = 0; y < height; ++y) {
        float value = field.read(uint2(x, y)).r;
        upper = max(value, upper - step); lower = min(value, lower + step);
        scratch.write(float4(upper, lower, 0, 1), uint2(x, y));
    }
}

kernel void protectProportions(texture2d<float, access::read> field [[texture(0)]],
    texture2d<float, access::read> scratch [[texture(1)]],
    texture2d<float, access::write> result [[texture(2)]],
    constant float4 &protection [[buffer(1)]], uint x [[thread_position_in_grid]]) {
    uint width = field.get_width(), height = field.get_height();
    if (x >= width) return;
    float step = protection.y / float(height - 1);
    float upper = -1.0, lower = 1.0;
    for (int y = int(height) - 1; y >= 0; --y) {
        float value = field.read(uint2(x, y)).r;
        upper = max(value, upper - step); lower = min(value, lower + step);
        float2 forward = scratch.read(uint2(x, y)).rg;
        float bounded = 0.5 * (max(upper, forward.x) + min(lower, forward.y));
        result.write(float4(bounded, 0, 0, 1), uint2(x, y));
    }
}

struct ProjectedVertex {
    float4 position [[position]];
    float2 uv;
};

vertex ProjectedVertex projectStereoVertex(uint id [[vertex_id]],
    texture2d<float, access::sample> field [[texture(0)]],
    constant float4 &grid [[buffer(1)]]) {
    const uint2 corners[6] = {uint2(0,0), uint2(1,0), uint2(0,1),
                             uint2(1,0), uint2(1,1), uint2(0,1)};
    uint cell = id / 6;
    float2 uv = (float2(cell % uint(grid.x), cell / uint(grid.x)) + float2(corners[id % 6])) / grid.xy;
    float2 size = float2(field.get_width(), field.get_height());
    float2 sampleUV = (uv * (size - 1.0) + 0.5) / size;
    // A shared field drives both eyes. A short vertical average preserves the
    // horizontal gradient bound while softening row-to-row depth quantization.
    float shift = field.sample(linearClamp, sampleUV).r * 0.5
        + field.sample(linearClamp, sampleUV + float2(0, 1.0 / size.y)).r * 0.25
        + field.sample(linearClamp, sampleUV - float2(0, 1.0 / size.y)).r * 0.25;
    ProjectedVertex out;
    out.position = float4(2.0 * (uv.x + grid.z * shift) - 1.0, 1.0 - 2.0 * uv.y, 0.5, 1.0);
    out.uv = uv;
    return out;
}

fragment half4 projectStereoFragment(ProjectedVertex in [[stage_in]],
                                      texture2d<float, access::sample> color [[texture(0)]]) {
    float2 dx = dfdx(in.uv), dy = dfdy(in.uv);
    float2 size = float2(color.get_width(), color.get_height());
    float footprint = max(length(dx * size), length(dy * size));
    float3 value = srgbToLinear(color.sample(linearClamp, in.uv).rgb);
    // Integrate texture coverage when the warp compresses pixels. MSAA alone
    // only filters triangle coverage, not fine detail within a triangle.
    if (footprint > 1.05) {
        float3 integrated = 0;
        for (int y = 0; y < 2; ++y) for (int x = 0; x < 2; ++x) {
            float2 offset = (float(x) - 0.5) * 0.5 * dx + (float(y) - 0.5) * 0.5 * dy;
            integrated += srgbToLinear(color.sample(linearClamp, in.uv + offset).rgb);
        }
        value = mix(value, integrated * 0.25, smoothstep(1.05, 1.4, footprint));
    }
    return half4(half3(value), 1);
}
