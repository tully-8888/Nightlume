#include <metal_stdlib>
using namespace metal;

struct Vertex
{
    float4 position [[ position ]];
    float2 texCoords;
};

struct CscParams
{
    half3x3 matrix;
    half3 offsets;
    half2 chromaOffset;
    half bitnessScaleFactor;
};

constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);

vertex Vertex vs_draw(constant Vertex *vertices [[ buffer(0) ]], uint id [[ vertex_id ]])
{
    return vertices[id];
}

fragment half4 ps_draw_biplanar(Vertex v [[ stage_in ]],
                                constant CscParams &cscParams [[ buffer(0) ]],
                                texture2d<half> luminancePlane [[ texture(0) ]],
                                texture2d<half> chrominancePlane [[ texture(1) ]])
{
    float2 chromaOffset = float2(cscParams.chromaOffset) / float2(chrominancePlane.get_width(),
                                                                  chrominancePlane.get_height());
    half3 yuv = half3(luminancePlane.sample(s, v.texCoords).r,
                      chrominancePlane.sample(s, v.texCoords + chromaOffset).rg);
    yuv *= cscParams.bitnessScaleFactor;
    yuv -= cscParams.offsets;

    return half4(yuv * cscParams.matrix, 1.0h);
}

fragment half4 ps_draw_triplanar(Vertex v [[ stage_in ]],
                                 constant CscParams &cscParams [[ buffer(0) ]],
                                 texture2d<half> luminancePlane [[ texture(0) ]],
                                 texture2d<half> chrominancePlaneU [[ texture(1) ]],
                                 texture2d<half> chrominancePlaneV [[ texture(2) ]])
{
    float2 chromaOffset = float2(cscParams.chromaOffset) / float2(chrominancePlaneU.get_width(),
                                                                  chrominancePlaneU.get_height());
    half3 yuv = half3(luminancePlane.sample(s, v.texCoords).r,
                      chrominancePlaneU.sample(s, v.texCoords + chromaOffset).r,
                      chrominancePlaneV.sample(s, v.texCoords + chromaOffset).r);
    yuv *= cscParams.bitnessScaleFactor;
    yuv -= cscParams.offsets;

    return half4(yuv * cscParams.matrix, 1.0h);
}

fragment half4 ps_draw_rgb(Vertex v [[ stage_in ]],
                           texture2d<half> rgbTexture [[ texture(0) ]])
{
    return rgbTexture.sample(s, v.texCoords);
}

// Detail pass parameters
struct DetailParams
{
    float strength;  // -1.0 to +1.0 (negative = dehalo, positive = sharpen)
};

// Compute kernel for detail pass (dehalo/sharpen) on luma texture
// Runs AFTER MetalFX spatial upscaling to reduce halos or enhance sharpness
kernel void detail_pass(
    texture2d<half, access::read> inputTexture [[texture(0)]],
    texture2d<half, access::write> outputTexture [[texture(1)]],
    constant DetailParams &params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint width = min(inputTexture.get_width(), outputTexture.get_width());
    uint height = min(inputTexture.get_height(), outputTexture.get_height());
    if (gid.x >= width || gid.y >= height) {
        return;
    }
    
    half center = inputTexture.read(gid).r;
    half result;
    
    if (params.strength < 0.0f) {
        half minVal = center;
        half maxVal = center;
        
        for (int dy = -2; dy <= 2; dy++) {
            for (int dx = -2; dx <= 2; dx++) {
                if (dx == 0 && dy == 0) continue;
                
                uint2 samplePos = uint2(
                    clamp(int(gid.x) + dx, 0, int(width) - 1),
                    clamp(int(gid.y) + dy, 0, int(height) - 1)
                );
                
                half sample = inputTexture.read(samplePos).r;
                minVal = min(minVal, sample);
                maxVal = max(maxVal, sample);
            }
        }
        
        half clamped = clamp(center, minVal, maxVal);
        
        half blur = 0.0h;
        half blurWeight = 0.0h;
        for (int dy = -1; dy <= 1; dy++) {
            for (int dx = -1; dx <= 1; dx++) {
                uint2 samplePos = uint2(
                    clamp(int(gid.x) + dx, 0, int(width) - 1),
                    clamp(int(gid.y) + dy, 0, int(height) - 1)
                );
                half sample = inputTexture.read(samplePos).r;
                half w = (dx == 0 && dy == 0) ? 4.0h : ((dx == 0 || dy == 0) ? 2.0h : 1.0h);
                blur += sample * w;
                blurWeight += w;
            }
        }
        blur /= blurWeight;
        
        // Blend: stronger negative = more effect
        // First apply clamp, then optionally blend toward blur
        float absStrength = -params.strength;  // 0.0 to 1.0
        
        // At low strength, mostly just clamp. At high strength, also soften
        half dehaloResult = mix(center, clamped, half(absStrength));
        
        // Add subtle softening at higher strengths
        if (absStrength > 0.5f) {
            float softBlend = (absStrength - 0.5f) * 0.4f;  // 0 to 0.2 blend toward blur
            dehaloResult = mix(dehaloResult, blur, half(softBlend));
        }
        
        result = dehaloResult;
    }
    else if (params.strength > 0.0f) {
        half s00 = inputTexture.read(uint2(clamp(int(gid.x) - 1, 0, int(width) - 1), clamp(int(gid.y) - 1, 0, int(height) - 1))).r;
        half s10 = inputTexture.read(uint2(gid.x, clamp(int(gid.y) - 1, 0, int(height) - 1))).r;
        half s20 = inputTexture.read(uint2(clamp(int(gid.x) + 1, 0, int(width) - 1), clamp(int(gid.y) - 1, 0, int(height) - 1))).r;
        half s01 = inputTexture.read(uint2(clamp(int(gid.x) - 1, 0, int(width) - 1), gid.y)).r;
        half s11 = center;
        half s21 = inputTexture.read(uint2(clamp(int(gid.x) + 1, 0, int(width) - 1), gid.y)).r;
        half s02 = inputTexture.read(uint2(clamp(int(gid.x) - 1, 0, int(width) - 1), clamp(int(gid.y) + 1, 0, int(height) - 1))).r;
        half s12 = inputTexture.read(uint2(gid.x, clamp(int(gid.y) + 1, 0, int(height) - 1))).r;
        half s22 = inputTexture.read(uint2(clamp(int(gid.x) + 1, 0, int(width) - 1), clamp(int(gid.y) + 1, 0, int(height) - 1))).r;
        
        half blur = (1.0h * s00 + 2.0h * s10 + 1.0h * s20 +
                     2.0h * s01 + 4.0h * s11 + 2.0h * s21 +
                     1.0h * s02 + 2.0h * s12 + 1.0h * s22) * (1.0h / 16.0h);
        
        half highPass = center - blur;
        half limit = 0.08h + half(params.strength) * 0.04h;
        half limitedHighPass = clamp(highPass, -limit, limit);
        result = clamp(center + limitedHighPass * half(params.strength) * 2.0h, 0.0h, 1.0h);
    }
    else {
        // strength == 0, pass through
        result = center;
    }
    
    outputTexture.write(half4(result, 0.0h, 0.0h, 1.0h), gid);
}

// Denoise pass parameters
struct DenoiseParams {
    float strength;  // 0.0 to 1.0
};

// Compute kernel for denoise pass on luma texture
// Runs BEFORE MetalFX spatial upscaling to reduce H.264/HEVC compression artifacts
constant float kSpatialWeights[25] = {
    0.1353f, 0.3679f, 0.6065f, 0.3679f, 0.1353f,
    0.3679f, 1.0000f, 0.6065f, 1.0000f, 0.3679f,
    0.6065f, 0.6065f, 1.0000f, 0.6065f, 0.6065f,
    0.3679f, 1.0000f, 0.6065f, 1.0000f, 0.3679f,
    0.1353f, 0.3679f, 0.6065f, 0.3679f, 0.1353f
};

kernel void denoise_pass(
    texture2d<half, access::read> inputTexture [[texture(0)]],
    texture2d<half, access::write> outputTexture [[texture(1)]],
    constant DenoiseParams &params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 lid [[thread_position_in_threadgroup]])
{
    constexpr uint TG_SIZE = 16;
    constexpr uint RADIUS = 2;
    constexpr uint TILE_SIZE = TG_SIZE + 2 * RADIUS;
    
    threadgroup half tile[TILE_SIZE][TILE_SIZE];
    
    uint width = min(inputTexture.get_width(), outputTexture.get_width());
    uint height = min(inputTexture.get_height(), outputTexture.get_height());
    
    uint2 groupOrigin = uint2(gid.x - lid.x, gid.y - lid.y);
    
    for (uint ty = lid.y; ty < TILE_SIZE; ty += TG_SIZE) {
        for (uint tx = lid.x; tx < TILE_SIZE; tx += TG_SIZE) {
            int srcX = int(groupOrigin.x) + int(tx) - int(RADIUS);
            int srcY = int(groupOrigin.y) + int(ty) - int(RADIUS);
            srcX = clamp(srcX, 0, int(width) - 1);
            srcY = clamp(srcY, 0, int(height) - 1);
            tile[ty][tx] = inputTexture.read(uint2(srcX, srcY)).r;
        }
    }
    
    threadgroup_barrier(mem_flags::mem_threadgroup);
    
    if (gid.x >= width || gid.y >= height) return;
    
    half center = tile[lid.y + RADIUS][lid.x + RADIUS];
    float centerF = float(center);
    
    float inv2SigmaI2 = 0.5f / ((0.05f + params.strength * 0.15f) * (0.05f + params.strength * 0.15f));
    
    float weightedSum = 0.0f;
    float weightTotal = 0.0f;
    
    int k = 0;
    for (int dy = -2; dy <= 2; dy++) {
        for (int dx = -2; dx <= 2; dx++) {
            half sampleVal = tile[lid.y + RADIUS + dy][lid.x + RADIUS + dx];
            float s = float(sampleVal);
            float d = s - centerF;
            float iw = fast::exp(-(d * d) * inv2SigmaI2);
            float w = kSpatialWeights[k] * iw;
            weightedSum += s * w;
            weightTotal += w;
            k++;
        }
    }
    
    half filtered = half(weightedSum / max(weightTotal, 1e-6f));
    half result = mix(center, filtered, half(params.strength));
    
    outputTexture.write(half4(result, 0.0h, 0.0h, 1.0h), gid);
}


struct DebandParams {
    float strength;
    float threshold;
    float range;
};

inline uint wang_hash(uint seed) {
    seed = (seed ^ 61u) ^ (seed >> 16u);
    seed *= 9u;
    seed = seed ^ (seed >> 4u);
    seed *= 0x27d4eb2du;
    seed = seed ^ (seed >> 15u);
    return seed;
}

inline float4 hash4(uint2 co) {
    uint h = wang_hash(co.x + co.y * 65536u);
    return float4(
        float(h & 0xFFu) / 255.0f,
        float((h >> 8u) & 0xFFu) / 255.0f,
        float((h >> 16u) & 0xFFu) / 255.0f,
        float((h >> 24u) & 0xFFu) / 255.0f
    ) * 2.0f - 1.0f;
}

kernel void deband_pass(
    texture2d<half, access::read> inputTexture [[texture(0)]],
    texture2d<half, access::write> outputTexture [[texture(1)]],
    constant DebandParams &params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint width = min(inputTexture.get_width(), outputTexture.get_width());
    uint height = min(inputTexture.get_height(), outputTexture.get_height());
    if (gid.x >= width || gid.y >= height) return;
    
    half center = inputTexture.read(gid).r;
    
    float range = params.range * params.strength;
    float4 rnd = hash4(gid);
    
    int2 offset1 = int2(int(rnd.x * range), int(rnd.y * range));
    int2 offset2 = int2(int(rnd.z * range), int(rnd.w * range));
    int2 offset3 = -offset1;
    int2 offset4 = -offset2;
    
    uint2 pos1 = uint2(clamp(int(gid.x) + offset1.x, 0, int(width)-1), 
                       clamp(int(gid.y) + offset1.y, 0, int(height)-1));
    uint2 pos2 = uint2(clamp(int(gid.x) + offset2.x, 0, int(width)-1), 
                       clamp(int(gid.y) + offset2.y, 0, int(height)-1));
    uint2 pos3 = uint2(clamp(int(gid.x) + offset3.x, 0, int(width)-1), 
                       clamp(int(gid.y) + offset3.y, 0, int(height)-1));
    uint2 pos4 = uint2(clamp(int(gid.x) + offset4.x, 0, int(width)-1), 
                       clamp(int(gid.y) + offset4.y, 0, int(height)-1));
    
    half s1 = inputTexture.read(pos1).r;
    half s2 = inputTexture.read(pos2).r;
    half s3 = inputTexture.read(pos3).r;
    half s4 = inputTexture.read(pos4).r;
    
    // Average of samples
    half avg = (s1 + s2 + s3 + s4) * 0.25h;
    
    // Only apply if we're in a "flat" area (potential banding)
    half maxDiff = max(max(abs(s1 - avg), abs(s2 - avg)), 
                       max(abs(s3 - avg), abs(s4 - avg)));
    
    half threshold = half(params.threshold);
    
    half result;
    if (maxDiff < threshold && abs(center - avg) < threshold) {
        result = mix(center, avg, half(params.strength * 0.5));
        
        uint dh = wang_hash(gid.x * 3 + gid.y * 65537u);
        float dither = (float(dh & 0xFFFFu) / 65535.0f - 0.5f) * params.strength * 0.02f;
        result += half(dither);
    } else {
        result = center;
    }
    
    outputTexture.write(half4(result, 0.0h, 0.0h, 1.0h), gid);
}
