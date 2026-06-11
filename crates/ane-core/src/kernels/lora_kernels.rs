/// LoRA-specific kernel helpers for ANE acceleration
/// These functions generate optimized MIL programs for LoRA operations

/// Generate MIL for fused LoRA forward: Y = W@X + scale * B@A@X
pub fn generate_fused_lora_mil(
    in_dim: usize,
    out_dim: usize,
    rank: usize,
    scale: f32,
    seq_len: usize,
) -> String {
    format!(
        r#"program("aneforge_fused_lora")
{{
    func main(
        input: tensor<fp32, [1, {in_dim}, 1, {seq_len}]>
    ) -> tensor<fp32, [1, {out_dim}, 1, {seq_len}]>
    {{
        let x = cast(x=input, dtype="fp16");

        // Base linear: W @ x
        let base = conv(
            x=x,
            weight=weights("W", [{out_dim}, {in_dim}, 1, 1], "fp16"),
            strides=[1, 1], pad_type="valid", dilations=[1, 1]
        );

        // LoRA down: A @ x -> [rank, seq]
        let down = conv(
            x=x,
            weight=weights("A", [{rank}, {in_dim}, 1, 1], "fp16"),
            strides=[1, 1], pad_type="valid", dilations=[1, 1]
        );

        // LoRA up: B @ down -> [out_dim, seq]
        let up = conv(
            x=down,
            weight=weights("B", [{out_dim}, {rank}, 1, 1], "fp16"),
            strides=[1, 1], pad_type="valid", dilations=[1, 1]
        );

        // Fuse: base + scale * up
        let scaled = mul(x=up, y=const({scale}));
        let fused = add(x=base, y=scaled);

        let output = cast(x=fused, dtype="fp32");
        return output;
    }}
}}"#
    )
}

/// Generate MIL for LoRA adapter only (no base weights)
/// Used when base weights are already compiled separately
pub fn generate_lora_adapter_mil(
    in_dim: usize,
    out_dim: usize,
    rank: usize,
    scale: f32,
    seq_len: usize,
) -> String {
    format!(
        r#"program("aneforge_lora_adapter")
{{
    func main(
        input: tensor<fp32, [1, {in_dim}, 1, {seq_len}]>
    ) -> tensor<fp32, [1, {out_dim}, 1, {seq_len}]>
    {{
        let x = cast(x=input, dtype="fp16");

        let down = conv(
            x=x,
            weight=weights("A", [{rank}, {in_dim}, 1, 1], "fp16"),
            strides=[1, 1], pad_type="valid", dilations=[1, 1]
        );

        let up = conv(
            x=down,
            weight=weights("B", [{out_dim}, {rank}, 1, 1], "fp16"),
            strides=[1, 1], pad_type="valid", dilations=[1, 1]
        );

        let scaled = mul(x=up, y=const({scale}));
        let output = cast(x=scaled, dtype="fp32");
        return output;
    }}
}}"#
    )
}
