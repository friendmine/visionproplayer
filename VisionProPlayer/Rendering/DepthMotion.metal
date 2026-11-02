#include <metal_stdlib>
using namespace metal;
constexpr sampler motionLinear(coord::normalized, address::clamp_to_edge, filter::linear);

float motionLuma(texture2d<float, access::sample> image, float2 uv) {
    return dot(image.sample(motionLinear, uv).rgb, float3(0.2126, 0.7152, 0.0722));
}

float patchError(texture2d<float, access::sample> source,
                 texture2d<float, access::sample> target, float2 uv, float2 delta, float2 step) {
    float error = 0;
    for (int y = -2; y <= 2; ++y) for (int x = -2; x <= 2; ++x) {
        float2 offset = float2(x, y) * step;
        error += abs(motionLuma(target, uv + offset) - motionLuma(source, uv + offset + delta * step));
    }
    return error / 25.0;
}

// Each vector maps a TARGET location back into SOURCE coordinates. Search is
// bounded to six guide pixels and refined to quarter-pixel precision.
kernel void matchDepthMotion(texture2d<float, access::sample> source [[texture(0)]],
    texture2d<float, access::sample> target [[texture(1)]],
    texture2d<half, access::write> result [[texture(2)]], uint2 p [[thread_position_in_grid]]) {
    if (p.x >= result.get_width() || p.y >= result.get_height()) return;
    float2 uv = (float2(p) + 0.5) / float2(result.get_width(), result.get_height());
    float2 step = 1.0 / float2(source.get_width(), source.get_height());
    float zero = patchError(source, target, uv, float2(0), step);
    float best = zero, score = zero;
    float2 displacement = 0;
    float errors[6]; float2 alternatives[6];
    for (int i = 0; i < 6; ++i) { errors[i] = 1e6; alternatives[i] = 0; }
    // Exact unchanged frames have a deterministic identity, including flat
    // regions. No arbitrary displacement is invented for matching ties.
    if (zero > 0.001) {
        for (int y = -6; y <= 6; ++y) for (int x = -6; x <= 6; ++x) {
            float2 delta = float2(x, y), at = uv + delta * step;
            if (any(at < step * 2) || any(at > 1.0 - step * 2)) continue;
            float error = patchError(source, target, uv, delta, step);
            // Keep independent matching evidence, without the displacement
            // prior. Repeated texture must not acquire high confidence merely
            // because the nearest of several lookalikes won the search.
            if (error < errors[5]) {
                int slot = 5;
                while (slot > 0 && error < errors[slot - 1]) {
                    errors[slot] = errors[slot - 1]; alternatives[slot] = alternatives[slot - 1]; --slot;
                }
                errors[slot] = error; alternatives[slot] = delta;
            }
            // Prefer the nearest explanation of repeated fine texture. A
            // barely better distant match must not cause a large depth jump.
            float candidate = error + 0.001 * dot(delta, delta);
            if (candidate < score) { score = candidate; best = error; displacement = delta; }
        }
        for (int pass = 0; pass < 2; ++pass) {
            float2 center = displacement;
            float spacing = pass == 0 ? 0.5 : 0.25;
            for (int y = -1; y <= 1; ++y) for (int x = -1; x <= 1; ++x) {
                float2 delta = center + float2(x, y) * spacing, at = uv + delta * step;
                if (any(abs(delta) > 6) || any(at < step * 2) || any(at > 1.0 - step * 2)) continue;
                float error = patchError(source, target, uv, delta, step);
                float candidate = error + 0.001 * dot(delta, delta);
                if (candidate < score) { score = candidate; best = error; displacement = delta; }
            }
        }
    }
    float lo = 1, hi = 0;
    for (int y = -1; y <= 1; ++y) for (int x = -1; x <= 1; ++x) {
        float l = motionLuma(target, uv + float2(x, y) * step * 2);
        lo = min(lo, l); hi = max(hi, l);
    }
    float confidence = (1 - smoothstep(0.015, 0.08, best)) * smoothstep(0.015, 0.08, hi - lo);
    float other = 1e6;
    for (int i = 0; i < 6; ++i) {
        if (length(alternatives[i] - displacement) > 1.5) other = min(other, errors[i]);
    }
    confidence *= smoothstep(0.003, 0.025, other - best);
    if (zero <= 0.001) confidence = 1;
    if (any(abs(displacement) >= 5.9)) confidence = 0;
    result.write(half4(half2(displacement * step), half(confidence), half(zero)), p);
}

kernel void warpMotionDepth(texture2d<float, access::sample> depth [[texture(0)]],
    texture2d<float, access::sample> backward [[texture(1)]],
    texture2d<float, access::sample> forward [[texture(2)]],
    texture2d<half, access::write> output [[texture(3)]],
    constant float4 &params [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
    if (p.x >= output.get_width() || p.y >= output.get_height()) return;
    float2 uv = (float2(p) + 0.5) / float2(output.get_width(), output.get_height());
    float4 back = backward.sample(motionLinear, uv);
    float2 at = uv + back.xy;
    float4 ahead = forward.sample(motionLinear, at);
    float roundTrip = length((back.xy + ahead.xy) * params.xy);
    float reliable = back.z * ahead.z * (1 - smoothstep(0.5, 1.5, roundTrip));
    if (any(at < 0) || any(at > 1)) reliable = 0;
    float aligned = depth.sample(motionLinear, clamp(at, 0.0, 1.0)).r;
    float original = depth.sample(motionLinear, uv).r;
    float transport = smoothstep(0.15, 0.65, reliable);
    float value = mix(original, aligned, transport);
    if (params.w > 0.5) {
        // Unchanged/textureless regions preserve relief. A changed region with
        // unreliable correspondence contracts toward zero disparity, rather
        // than confidently projecting an old foreground into newly seen pixels.
        float risk = smoothstep(0.025, 0.12, back.w) * (1 - transport);
        value = mix(value, params.z, risk * 0.65);
    }
    output.write(half4(half(value), half(reliable), 0, 1), p);
}

// History has already been transported to the new prediction's source image.
// Its second channel carries correspondence reliability, never inferred depth.
kernel void stabilizeMotionDepth(texture2d<float, access::sample> raw [[texture(0)]],
    texture2d<float, access::sample> history [[texture(1)]],
    texture2d<half, access::write> output [[texture(2)]],
    constant float4 &params [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
    if (p.x >= output.get_width() || p.y >= output.get_height()) return;
    float2 step = 1.0 / float2(output.get_width(), output.get_height());
    float2 uv = (float2(p) + 0.5) * step;
    float center = clamp((raw.sample(motionLinear, uv).r - params.x) * params.y, 0.0, 1.0);
    float value = center, weight = 1;
    const float2 offsets[4] = {float2(1,0), float2(-1,0), float2(0,1), float2(0,-1)};
    for (int i = 0; i < 4; ++i) {
        float neighbor = clamp((raw.sample(motionLinear, uv + offsets[i] * step).r - params.x) * params.y, 0.0, 1.0);
        float w = 0.25 * exp(-40.0 * abs(neighbor - center));
        value += neighbor * w; weight += w;
    }
    float d = value / weight;
    if (params.z < 0.5) {
        float2 old = history.sample(motionLinear, uv).rg;
        float blend = 0.70 * (1 - smoothstep(0.025, 0.10, abs(old.r - d))) * old.g;
        d = mix(d, old.r, blend);
    }
    output.write(half4(half(d), 0, 0, 1), p);
}
