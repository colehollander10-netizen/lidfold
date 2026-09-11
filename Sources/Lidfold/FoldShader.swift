import Foundation

/// The whole effect in one fragment pass, compiled at runtime so no Metal
/// toolchain is needed to build.
///
/// Model: the desktop is a plane fixed in space at the position it had when
/// the lid was open. The glass rotates about the hinge (bottom edge) toward
/// the viewer; each glass pixel shows what the viewer's ray through it hits on
/// the fixed desktop, so the picture stays anchored from the viewer's seat
/// while the glass sweeps over it, stretching toward the far edge. Height
/// above the hinge then drives progressive blur and a gradient of shadow that
/// dissolves the far edge into black as the lid shuts.
enum FoldShader {
    static let source = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float4 c0;      // screen uv (y down) -> content uv (y down) homography, column 0
        float4 c1;
        float4 c2;
        float4 blur;    // x: max radius in level-0 texels, y: strength 0..1, z: hinge floor, w: max lod
        float4 dim;     // x: gradient dim 0..1, y: corner shadow 0..1, z: final fade 0..1, w: aspect (w/h)
        float4 size;    // xy: content texels, zw: output pixels
    };

    struct VOut { float4 position [[position]]; float2 uv; };

    vertex VOut foldVertex(uint vid [[vertex_id]]) {
        const float2 p[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
        VOut o;
        o.position = float4(p[vid], 0.0, 1.0);
        o.uv = float2(p[vid].x * 0.5 + 0.5, 0.5 - p[vid].y * 0.5);   // y down
        return o;
    }

    static float hash(float2 p) {
        return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
    }

    // 16-tap Vogel disc over a trilinear mip chain. Cheap, ring-free, and
    // stays smooth at every angle because the lod is tied to the tap spacing.
    static float3 discBlur(texture2d<float> tex, sampler s, float2 uv, float radiusTexels,
                           float2 texelSize, float maxLod, float2 seed) {
        if (radiusTexels < 0.6) { return tex.sample(s, uv, level(0.0)).rgb; }
        const int N = 16;
        const float GOLDEN = 2.39996323;
        float rot = hash(seed) * 6.2831853;
        float lod = clamp(log2(max(radiusTexels / 2.6, 1.0)), 0.0, maxLod);
        float3 acc = float3(0.0);
        float wsum = 0.0;
        for (int i = 0; i < N; i++) {
            float fi = float(i);
            float r = sqrt((fi + 0.5) / float(N));
            float a = fi * GOLDEN + rot;
            float2 off = float2(cos(a), sin(a)) * (r * radiusTexels) * texelSize;
            float2 suv = uv + off;
            // Taps past the picture edge would repeat the border texel and
            // smear it into the black surround; leave them out instead.
            if (suv.x < 0.0 || suv.x > 1.0 || suv.y < 0.0 || suv.y > 1.0) { continue; }
            float w = exp(-2.0 * r * r);
            acc += tex.sample(s, suv, level(lod)).rgb * w;
            wsum += w;
        }
        return wsum > 0.0 ? acc / wsum : tex.sample(s, uv, level(lod)).rgb;
    }

    fragment float4 foldFragment(VOut in [[stage_in]],
                                 constant Uniforms &u [[buffer(0)]],
                                 texture2d<float> content [[texture(0)]]) {
        constexpr sampler smp(filter::linear, mip_filter::linear, address::clamp_to_edge);

        float3x3 M = float3x3(u.c0.xyz, u.c1.xyz, u.c2.xyz);
        float3 m = M * float3(in.uv, 1.0);
        if (abs(m.z) < 1e-6) { return float4(0.0, 0.0, 0.0, 1.0); }
        float2 cuv = m.xy / m.z;

        // Anti-aliased edge of the tilted picture against the black void.
        float2 aa = fwidth(cuv) * 0.75;
        float edge = smoothstep(-aa.x, aa.x, cuv.x) * smoothstep(-aa.x, aa.x, 1.0 - cuv.x)
                   * smoothstep(-aa.y, aa.y, cuv.y) * smoothstep(-aa.y, aa.y, 1.0 - cuv.y);
        if (edge <= 0.0) { return float4(0.0, 0.0, 0.0, 1.0); }
        cuv = clamp(cuv, 0.0, 1.0);

        // Height above the hinge, 0 at the bottom edge and 1 at the far edge.
        float h = 1.0 - cuv.y;

        // Depth of field: the far edge sits farther from the eye, so it softens first.
        float spread = pow(smoothstep(0.0, 0.9, h), 1.15);
        float radius = u.blur.x * u.blur.y * (u.blur.z + (1.0 - u.blur.z) * spread);
        float2 texel = 1.0 / u.size.xy;
        float3 rgb = discBlur(content, smp, cuv, radius, texel, u.blur.w, in.position.xy);

        // Light falls off toward the far edge; the hinge keeps most of its light.
        float grad = 0.12 + 0.88 * smoothstep(0.0, 0.85, h);
        float dimFactor = 1.0 - 0.82 * u.dim.x * grad;

        // Two soft shadows falling in from the top corners of the glass.
        float2 sp = float2(in.uv.x * u.dim.w, in.uv.y);          // aspect-correct screen space
        float2 cornerL = float2(0.0, 0.0), cornerR = float2(u.dim.w, 0.0);
        float sigma = 0.55;
        float sh = exp(-dot(sp - cornerL, sp - cornerL) / (sigma * sigma))
                 + exp(-dot(sp - cornerR, sp - cornerR) / (sigma * sigma));
        float shadowFactor = 1.0 - 0.55 * u.dim.y * clamp(sh, 0.0, 1.0);

        // Samples are linear light; shaping the factors by 2.2 keeps the
        // sliders roughly perceptual.
        rgb *= pow(clamp(dimFactor * shadowFactor, 0.0, 1.0), 2.2);
        rgb *= pow(1.0 - u.dim.z, 2.2);

        return float4(rgb * edge, 1.0);
    }
    """#
}
