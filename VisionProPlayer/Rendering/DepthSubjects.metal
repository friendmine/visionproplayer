#include <metal_stdlib>
using namespace metal;
constexpr sampler subjectLinear(coord::normalized, address::clamp_to_edge, filter::linear);

// Restore the model's valid content to the original full-frame coordinates.
// Keep finite near-tail differences that the old hard 95th-percentile clip lost.
kernel void prepareSubjectDepth(texture2d<float, access::sample> raw [[texture(0)]],
    texture2d<half, access::write> output [[texture(1)]],
    constant float4 &crop [[buffer(0)]], constant float2 &range [[buffer(1)]],
    uint2 p [[thread_position_in_grid]]) {
    if (p.x >= output.get_width() || p.y >= output.get_height()) return;
    float2 uv = (float2(p) + 0.5) / float2(output.get_width(), output.get_height());
    float2 rawSize = float2(raw.get_width(), raw.get_height());
    float2 firstCenter = (ceil(crop.xy * rawSize - 0.5) + 0.5) / rawSize;
    float2 lastCenter = (floor((crop.xy + crop.zw) * rawSize - 0.5) + 0.5) / rawSize;
    float2 at = clamp(crop.xy + uv * crop.zw, firstCenter, lastCenter);
    float d = max(0.0, (raw.sample(subjectLinear, at).r - range.x) * range.y);
    // Continuous value AND slope at the shoulder. No foreground boost or
    // reversal: most of the range is unchanged, the near tail rolls off smoothly.
    if (d > 0.8) d = 0.8 + 0.2 * (1.0 - exp(-(d - 0.8) / 0.2));
    output.write(half4(half(min(d, 1.0)), 0, 0, 1), p);
}
