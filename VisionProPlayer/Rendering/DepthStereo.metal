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
    float value = raw.sample(linearClamp, uv).r * 0.6;
    value += 0.1 * (raw.sample(linearClamp, uv + float2(step.x,0)).r + raw.sample(linearClamp, uv - float2(step.x,0)).r
                  + raw.sample(linearClamp, uv + float2(0,step.y)).r + raw.sample(linearClamp, uv - float2(0,step.y)).r);
    float d = clamp((value - params.x) * params.y, 0.0, 1.0);
    float old = previous.sample(linearClamp, uv).r;
    // Smooth small variations, but follow moving depth boundaries without a long trail.
    if (params.z < 0.5 && abs(old - d) < 0.08) d = mix(old, d, 0.4);
    output.write(half4(half(d),0,0,1), p);
}

float3 srgbToLinear(float3 c) {
    return select(c / 12.92, pow((c + 0.055) / 1.055, float3(2.4)), c > 0.04045);
}

float2 sourceUV(float2 target, float eye, float strength, texture2d<float, access::sample> depth) {
    float2 uv = target;
    float border = smoothstep(0.0, 0.04, min(target.x, 1.0 - target.x));
    for (int i = 0; i < 3; ++i) {
        float nearDepth = depth.sample(linearClamp, uv).r;
        // Near objects shift right in the left eye and left in the right eye.
        // Max total disparity = 1.2% of image width, with zero at the convergence plane.
        float shift = (nearDepth - 0.5) * 0.012 * strength * border;
        uv.x = clamp(target.x - eye * shift, 0.0, 1.0);
    }
    return uv;
}

kernel void synthesizeStereo(texture2d<float, access::sample> color [[texture(0)]],
                             texture2d<float, access::sample> depth [[texture(1)]],
                             texture2d<half, access::write> left [[texture(2)]],
                             texture2d<half, access::write> right [[texture(3)]],
                             constant float &strength [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
    if (p.x >= left.get_width() || p.y >= left.get_height()) return;
    float2 uv = (float2(p) + 0.5) / float2(left.get_width(), left.get_height());
    // CVMetalTexture rows already match the final texture produced by the
    // existing Core Image path. Flipping again would turn the video upside down.
    float3 l = color.sample(linearClamp, sourceUV(uv, 1, strength, depth)).rgb;
    float3 r = color.sample(linearClamp, sourceUV(uv, -1, strength, depth)).rgb;
    left.write(half4(half3(srgbToLinear(l)), 1), p);
    right.write(half4(half3(srgbToLinear(r)), 1), p);
}
