use crate::runtime::{ANERuntime, ANEKernelHandle, ANEError};

/// High-level ANE compiler wrapping MIL generation and compilation
pub struct ANECompiler<'a> {
    runtime: &'a ANERuntime,
}

impl<'a> ANECompiler<'a> {
    pub fn new(runtime: &'a ANERuntime) -> Self {
        Self { runtime }
    }

    /// Compile a 1x1 convolution kernel (linear layer) for ANE
    /// This is the fundamental operation: Y = X @ W^T
    /// ANE treats this as a conv2d with kernel_size=1
    pub fn compile_linear(
        &self,
        weights: &[f32],
        in_dim: usize,
        out_dim: usize,
        seq_len: usize,
    ) -> Result<ANEKernelHandle, ANEError> {
        let mil = generate_conv_mil(in_dim, out_dim, seq_len);
        let weight_bytes = weights_to_fp16_blob(weights);
        self.runtime.compile(
            &mil,
            Some(&weight_bytes),
            in_dim * seq_len,
            out_dim * seq_len,
        )
    }

    /// Compile a fused LoRA kernel: Y = base(X) + scale * B @ A @ X
    /// Single MIL program with both A (down) and B (up) projections
    pub fn compile_lora(
        &self,
        base_weights: &[f32],
        lora_a: &[f32],
        lora_b: &[f32],
        in_dim: usize,
        out_dim: usize,
        rank: usize,
        scale: f32,
        seq_len: usize,
    ) -> Result<ANEKernelHandle, ANEError> {
        let mil = generate_lora_mil(in_dim, out_dim, rank, scale, seq_len);

        // Pack all weights: [base | lora_a | lora_b]
        let mut all_weights = Vec::with_capacity(
            base_weights.len() + lora_a.len() + lora_b.len()
        );
        all_weights.extend_from_slice(base_weights);
        all_weights.extend_from_slice(lora_a);
        all_weights.extend_from_slice(lora_b);

        let weight_bytes = weights_to_fp16_blob(&all_weights);
        self.runtime.compile(
            &mil,
            Some(&weight_bytes),
            in_dim * seq_len,
            out_dim * seq_len,
        )
    }

    /// Compile QKV fused projection: computes Q, K, V in one kernel
    pub fn compile_qkv(
        &self,
        wq: &[f32],
        wk: &[f32],
        wv: &[f32],
        dim: usize,
        seq_len: usize,
    ) -> Result<ANEKernelHandle, ANEError> {
        let mil = generate_qkv_mil(dim, seq_len);

        let mut all_weights = Vec::with_capacity(wq.len() + wk.len() + wv.len());
        all_weights.extend_from_slice(wq);
        all_weights.extend_from_slice(wk);
        all_weights.extend_from_slice(wv);

        let weight_bytes = weights_to_fp16_blob(&all_weights);
        self.runtime.compile(
            &mil,
            Some(&weight_bytes),
            dim * seq_len,
            3 * dim * seq_len, // Q, K, V concatenated
        )
    }

    pub fn compilation_count(&self) -> i32 {
        self.runtime.compilation_count()
    }
}

/// Generate MIL code for a 1x1 convolution (linear layer)
fn generate_conv_mil(in_dim: usize, out_dim: usize, seq_len: usize) -> String {
    format!(
        r#"program("aneforge_conv")
{{
    func main(
        input: tensor<fp32, [1, {in_dim}, 1, {seq_len}]>
    ) -> tensor<fp32, [1, {out_dim}, 1, {seq_len}]>
    {{
        // Cast to fp16 for ANE
        let x_fp16 = cast(x=input, dtype="fp16");

        // 1x1 convolution = linear layer
        let conv_out = conv(
            x=x_fp16,
            weight=weights("weight", [{out_dim}, {in_dim}, 1, 1], "fp16"),
            strides=[1, 1],
            pad_type="valid",
            dilations=[1, 1]
        );

        // Cast back to fp32
        let output = cast(x=conv_out, dtype="fp32");
        return output;
    }}
}}"#
    )
}

/// Generate MIL code for fused LoRA kernel
fn generate_lora_mil(
    in_dim: usize,
    out_dim: usize,
    rank: usize,
    scale: f32,
    seq_len: usize,
) -> String {
    format!(
        r#"program("aneforge_lora")
{{
    func main(
        input: tensor<fp32, [1, {in_dim}, 1, {seq_len}]>
    ) -> tensor<fp32, [1, {out_dim}, 1, {seq_len}]>
    {{
        let x_fp16 = cast(x=input, dtype="fp16");

        // Base projection
        let base_out = conv(
            x=x_fp16,
            weight=weights("base_weight", [{out_dim}, {in_dim}, 1, 1], "fp16"),
            strides=[1, 1],
            pad_type="valid",
            dilations=[1, 1]
        );

        // LoRA down-projection: A @ x  [in_dim -> rank]
        let lora_down = conv(
            x=x_fp16,
            weight=weights("lora_a", [{rank}, {in_dim}, 1, 1], "fp16"),
            strides=[1, 1],
            pad_type="valid",
            dilations=[1, 1]
        );

        // LoRA up-projection: B @ (A @ x)  [rank -> out_dim]
        let lora_up = conv(
            x=lora_down,
            weight=weights("lora_b", [{out_dim}, {rank}, 1, 1], "fp16"),
            strides=[1, 1],
            pad_type="valid",
            dilations=[1, 1]
        );

        // Scale and add: base + scale * lora
        let scaled = mul(x=lora_up, y=const({scale}));
        let combined = add(x=base_out, y=scaled);

        let output = cast(x=combined, dtype="fp32");
        return output;
    }}
}}"#
    )
}

/// Generate MIL code for fused QKV projection
fn generate_qkv_mil(dim: usize, seq_len: usize) -> String {
    format!(
        r#"program("aneforge_qkv")
{{
    func main(
        input: tensor<fp32, [1, {dim}, 1, {seq_len}]>
    ) -> tensor<fp32, [1, {three_dim}, 1, {seq_len}]>
    {{
        let x_fp16 = cast(x=input, dtype="fp16");

        let q = conv(
            x=x_fp16,
            weight=weights("wq", [{dim}, {dim}, 1, 1], "fp16"),
            strides=[1, 1], pad_type="valid", dilations=[1, 1]
        );
        let k = conv(
            x=x_fp16,
            weight=weights("wk", [{dim}, {dim}, 1, 1], "fp16"),
            strides=[1, 1], pad_type="valid", dilations=[1, 1]
        );
        let v = conv(
            x=x_fp16,
            weight=weights("wv", [{dim}, {dim}, 1, 1], "fp16"),
            strides=[1, 1], pad_type="valid", dilations=[1, 1]
        );

        // Concatenate along channel dimension
        let qkv = concat(values=[q, k, v], axis=1);

        let output = cast(x=qkv, dtype="fp32");
        return output;
    }}
}}"#,
        three_dim = dim * 3,
    )
}

/// Convert f32 weights to fp16 blob with ANE header
fn weights_to_fp16_blob(weights: &[f32]) -> Vec<u8> {
    let mut blob = Vec::with_capacity(16 + weights.len() * 2);

    // ANE weight blob header
    blob.extend_from_slice(&[0xDE, 0xAD, 0xBE, 0xEF]); // Magic
    blob.extend_from_slice(&(weights.len() as u32).to_le_bytes()); // Count
    blob.extend_from_slice(&2u32.to_le_bytes()); // Element size (fp16)
    blob.extend_from_slice(&[0u8; 4]); // Padding

    // Convert f32 -> fp16
    for &w in weights {
        let fp16 = half::f16::from_f32(w);
        blob.extend_from_slice(&fp16.to_le_bytes());
    }

    blob
}
