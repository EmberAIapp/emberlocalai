use crate::model::{ModelConfig, ModelWeights};
use crate::lora::LoRAModel;
use crate::kernels::norm::rmsnorm;
use crate::kernels::attention::cpu_attention;

/// Activations stored during forward pass (needed for backward)
pub struct ForwardCache {
    pub x: Vec<Vec<f32>>,           // Input to each layer [n_layers][seq*dim]
    pub x_norm: Vec<Vec<f32>>,      // After attention RMSNorm
    pub q: Vec<Vec<f32>>,           // Q projections
    pub k: Vec<Vec<f32>>,           // K projections
    pub v: Vec<Vec<f32>>,           // V projections
    pub attn_out: Vec<Vec<f32>>,    // After attention
    pub ffn_in: Vec<Vec<f32>>,      // Input to FFN (after norm)
    pub h1: Vec<Vec<f32>>,          // FFN gate output
    pub h3: Vec<Vec<f32>>,          // FFN up output
    pub silu_out: Vec<Vec<f32>>,    // After SiLU activation
    pub logits: Vec<f32>,           // Final logits
}

impl ForwardCache {
    pub fn new(config: &ModelConfig, seq_len: usize) -> Self {
        let n = config.n_layers;
        let d = config.dim;
        let h = config.hidden_dim;
        let v = config.vocab_size;
        let s = seq_len;

        Self {
            x: (0..n).map(|_| vec![0.0; s * d]).collect(),
            x_norm: (0..n).map(|_| vec![0.0; s * d]).collect(),
            q: (0..n).map(|_| vec![0.0; s * d]).collect(),
            k: (0..n).map(|_| vec![0.0; s * d]).collect(),
            v: (0..n).map(|_| vec![0.0; s * d]).collect(),
            attn_out: (0..n).map(|_| vec![0.0; s * d]).collect(),
            ffn_in: (0..n).map(|_| vec![0.0; s * d]).collect(),
            h1: (0..n).map(|_| vec![0.0; s * h]).collect(),
            h3: (0..n).map(|_| vec![0.0; s * h]).collect(),
            silu_out: (0..n).map(|_| vec![0.0; s * h]).collect(),
            logits: vec![0.0; s * v],
        }
    }
}

pub struct ForwardPass;

impl ForwardPass {
    /// Execute full forward pass on CPU (with optional LoRA)
    /// Returns (loss, cache)
    pub fn forward(
        weights: &ModelWeights,
        lora: Option<&LoRAModel>,
        tokens: &[u32],
        seq_len: usize,
    ) -> (f32, ForwardCache) {
        let config = &weights.config;
        let dim = config.dim;
        let hidden_dim = config.hidden_dim;
        let n_heads = config.n_heads;
        let head_dim = config.head_dim;
        let mut cache = ForwardCache::new(config, seq_len);

        // Token embedding lookup
        let mut x = vec![0.0f32; seq_len * dim];
        for t in 0..seq_len {
            let token = tokens[t] as usize;
            if token < config.vocab_size {
                let offset = token * dim;
                x[t * dim..(t + 1) * dim]
                    .copy_from_slice(&weights.token_embedding[offset..offset + dim]);
            }
        }

        // Transformer layers
        for layer in 0..config.n_layers {
            cache.x[layer].copy_from_slice(&x);

            // Attention RMSNorm
            rmsnorm(&mut cache.x_norm[layer], &x, &weights.rms_att_w[layer], seq_len, dim, config.norm_eps);

            // Q, K, V projections (CPU matmul)
            cpu_matmul(&mut cache.q[layer], &cache.x_norm[layer], &weights.wq[layer], seq_len, dim, dim);
            cpu_matmul(&mut cache.k[layer], &cache.x_norm[layer], &weights.wk[layer], seq_len, dim, dim);
            cpu_matmul(&mut cache.v[layer], &cache.x_norm[layer], &weights.wv[layer], seq_len, dim, dim);

            // Add LoRA on the attention input projections (q, k, v)
            let lp = format!("layers.{layer}");
            add_lora(lora, &format!("{lp}.q_proj"), &cache.x_norm[layer], &mut cache.q[layer], seq_len);
            add_lora(lora, &format!("{lp}.k_proj"), &cache.x_norm[layer], &mut cache.k[layer], seq_len);
            add_lora(lora, &format!("{lp}.v_proj"), &cache.x_norm[layer], &mut cache.v[layer], seq_len);

            // RoPE (rotary position embeddings)
            apply_rope(&mut cache.q[layer], &mut cache.k[layer], seq_len, n_heads, head_dim, config.rope_theta);

            // Multi-head attention
            cpu_attention(
                &mut cache.attn_out[layer],
                &cache.q[layer],
                &cache.k[layer],
                &cache.v[layer],
                seq_len, n_heads, head_dim,
            );

            // Output projection (+ LoRA on o_proj)
            let mut proj_out = vec![0.0f32; seq_len * dim];
            cpu_matmul(&mut proj_out, &cache.attn_out[layer], &weights.wo[layer], seq_len, dim, dim);
            add_lora(lora, &format!("{lp}.o_proj"), &cache.attn_out[layer], &mut proj_out, seq_len);

            // Residual connection
            for i in 0..x.len() {
                x[i] += proj_out[i];
            }

            // FFN RMSNorm
            rmsnorm(&mut cache.ffn_in[layer], &x, &weights.rms_ffn_w[layer], seq_len, dim, config.norm_eps);

            // FFN: gate (w1) and up (w3) projections (+ LoRA)
            cpu_matmul(&mut cache.h1[layer], &cache.ffn_in[layer], &weights.w1[layer], seq_len, dim, hidden_dim);
            cpu_matmul(&mut cache.h3[layer], &cache.ffn_in[layer], &weights.w3[layer], seq_len, dim, hidden_dim);
            add_lora(lora, &format!("{lp}.gate_proj"), &cache.ffn_in[layer], &mut cache.h1[layer], seq_len);
            add_lora(lora, &format!("{lp}.up_proj"), &cache.ffn_in[layer], &mut cache.h3[layer], seq_len);

            // SiLU activation: silu(h1) * h3
            for i in 0..cache.h1[layer].len() {
                let silu = cache.h1[layer][i] / (1.0 + (-cache.h1[layer][i]).exp());
                cache.silu_out[layer][i] = silu * cache.h3[layer][i];
            }

            // Down projection (w2) (+ LoRA on down_proj)
            let mut ffn_out = vec![0.0f32; seq_len * dim];
            cpu_matmul(&mut ffn_out, &cache.silu_out[layer], &weights.w2[layer], seq_len, hidden_dim, dim);
            add_lora(lora, &format!("{lp}.down_proj"), &cache.silu_out[layer], &mut ffn_out, seq_len);

            // Residual connection
            for i in 0..x.len() {
                x[i] += ffn_out[i];
            }
        }

        // Final RMSNorm
        let mut x_final = vec![0.0f32; seq_len * dim];
        rmsnorm(&mut x_final, &x, &weights.rms_final_w, seq_len, dim, config.norm_eps);

        // Classifier
        cpu_matmul(&mut cache.logits, &x_final, &weights.classifier, seq_len, dim, config.vocab_size);

        // Cross-entropy loss
        let loss = cross_entropy_loss(&cache.logits, tokens, seq_len, config.vocab_size);

        (loss, cache)
    }
}

/// CPU matrix multiplication: Y = X @ W^T  (BLAS-accelerated via Accelerate)
/// X: [seq_len, in_dim], W: [out_dim, in_dim], Y: [seq_len, out_dim]
fn cpu_matmul(y: &mut [f32], x: &[f32], w: &[f32], seq_len: usize, in_dim: usize, out_dim: usize) {
    crate::blas::matmul_nt(y, x, w, seq_len, in_dim, out_dim);
}

/// Add a LoRA adapter's contribution into `out` (in place) if it exists.
fn add_lora(lora: Option<&LoRAModel>, name: &str, x: &[f32], out: &mut [f32], seq_len: usize) {
    if let Some(model) = lora {
        if let Some(adapter) = model.get(name) {
            let delta = adapter.forward_cpu(x, seq_len);
            for i in 0..out.len() {
                out[i] += delta[i];
            }
        }
    }
}

/// Apply Rotary Position Embeddings — HuggingFace "rotate_half" convention
/// (Llama / SmolLM2 / Qwen). Pairs dimension i with i+head_dim/2 (NOT interleaved).
fn apply_rope(q: &mut [f32], k: &mut [f32], seq_len: usize, n_heads: usize, head_dim: usize, theta: f32) {
    let dim = n_heads * head_dim;
    let half = head_dim / 2;
    for t in 0..seq_len {
        for h in 0..n_heads {
            let base = t * dim + h * head_dim;
            for i in 0..half {
                let freq = 1.0 / theta.powf((2 * i) as f32 / head_dim as f32);
                let angle = t as f32 * freq;
                let cos_a = angle.cos();
                let sin_a = angle.sin();

                let i0 = base + i;        // first half
                let i1 = base + i + half; // second half

                let q0 = q[i0];
                let q1 = q[i1];
                q[i0] = q0 * cos_a - q1 * sin_a;
                q[i1] = q1 * cos_a + q0 * sin_a;

                let k0 = k[i0];
                let k1 = k[i1];
                k[i0] = k0 * cos_a - k1 * sin_a;
                k[i1] = k1 * cos_a + k0 * sin_a;
            }
        }
    }
}

#[allow(dead_code)]
fn _apply_rope_old(q: &mut [f32], k: &mut [f32], seq_len: usize, n_heads: usize, head_dim: usize, theta: f32) {
    let dim = n_heads * head_dim;
    for t in 0..seq_len {
        for h in 0..n_heads {
            for i in (0..head_dim).step_by(2) {
                let freq = 1.0 / theta.powf(i as f32 / head_dim as f32);
                let angle = t as f32 * freq;
                let cos_a = angle.cos();
                let sin_a = angle.sin();

                let qi = t * dim + h * head_dim + i;
                let qi1 = qi + 1;

                // Rotate Q
                let q0 = q[qi];
                let q1 = q[qi1];
                q[qi] = q0 * cos_a - q1 * sin_a;
                q[qi1] = q0 * sin_a + q1 * cos_a;

                // Rotate K
                let k0 = k[qi];
                let k1 = k[qi1];
                k[qi] = k0 * cos_a - k1 * sin_a;
                k[qi1] = k0 * sin_a + k1 * cos_a;
            }
        }
    }
}

/// Cross-entropy loss
fn cross_entropy_loss(logits: &[f32], tokens: &[u32], seq_len: usize, vocab_size: usize) -> f32 {
    let mut total_loss = 0.0f32;
    let mut count = 0;

    for t in 0..seq_len.saturating_sub(1) {
        let target = tokens[t + 1] as usize;
        if target >= vocab_size { continue; }

        // Log-softmax
        let offset = t * vocab_size;
        let max_logit = logits[offset..offset + vocab_size]
            .iter()
            .cloned()
            .fold(f32::NEG_INFINITY, f32::max);

        let mut log_sum_exp = 0.0f32;
        for v in 0..vocab_size {
            log_sum_exp += (logits[offset + v] - max_logit).exp();
        }
        let log_sum_exp = log_sum_exp.ln() + max_logit;

        let loss = log_sum_exp - logits[offset + target];
        total_loss += loss;
        count += 1;
    }

    if count > 0 { total_loss / count as f32 } else { 0.0 }
}
