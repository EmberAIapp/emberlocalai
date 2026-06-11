use crate::model::ModelWeights;
use crate::lora::LoRAModel;
use crate::forward::ForwardCache;
use crate::kernels::norm::rmsnorm_backward;

pub struct BackwardPass;

impl BackwardPass {
    /// Execute backward pass computing gradients for LoRA adapters
    /// Only computes gradients for LoRA A/B matrices (not base weights)
    pub fn backward(
        weights: &ModelWeights,
        lora: &mut LoRAModel,
        tokens: &[u32],
        cache: &ForwardCache,
        seq_len: usize,
    ) {
        let config = &weights.config;
        let dim = config.dim;
        let hidden_dim = config.hidden_dim;
        let n_heads = config.n_heads;
        let head_dim = config.head_dim;
        let vocab_size = config.vocab_size;

        // dL/dlogits from cross-entropy
        let mut d_logits = vec![0.0f32; seq_len * vocab_size];
        for t in 0..seq_len.saturating_sub(1) {
            let target = tokens[t + 1] as usize;
            if target >= vocab_size { continue; }

            let offset = t * vocab_size;
            let max_val = cache.logits[offset..offset + vocab_size]
                .iter()
                .cloned()
                .fold(f32::NEG_INFINITY, f32::max);

            let mut sum_exp = 0.0f32;
            for v in 0..vocab_size {
                let e = (cache.logits[offset + v] - max_val).exp();
                d_logits[offset + v] = e;
                sum_exp += e;
            }
            for v in 0..vocab_size {
                d_logits[offset + v] /= sum_exp;
            }
            d_logits[offset + target] -= 1.0;

            // Average over sequence
            let scale = 1.0 / (seq_len - 1) as f32;
            for v in 0..vocab_size {
                d_logits[offset + v] *= scale;
            }
        }

        // Backprop through classifier: dx = d_logits @ W_cls
        let mut dx = vec![0.0f32; seq_len * dim];
        cpu_matmul_backward_dx(&mut dx, &d_logits, &weights.classifier, seq_len, dim, vocab_size);

        // Backprop through final RMSNorm
        let mut dx_norm = vec![0.0f32; seq_len * dim];
        // Approximate: pass through
        dx_norm.copy_from_slice(&dx);

        // Backprop through transformer layers (reverse order)
        for layer in (0..config.n_layers).rev() {
            // --- FFN backward ---

            // Backprop through residual: dx_ffn = dx (copy)
            let dx_ffn = dx.clone();
            let lp = format!("layers.{layer}");

            // LoRA backward for down_proj: input=silu_out, dy=dx_ffn
            if let Some(a) = lora.get_mut(&format!("{lp}.down_proj")) {
                a.backward_cpu(&cache.silu_out[layer], &dx_ffn, seq_len);
            }

            // Backprop through w2 (down projection)
            let mut d_silu = vec![0.0f32; seq_len * hidden_dim];
            cpu_matmul_backward_dx(&mut d_silu, &dx_ffn, &weights.w2[layer], seq_len, hidden_dim, dim);

            // Backprop through SiLU activation
            let mut d_h1 = vec![0.0f32; seq_len * hidden_dim];
            let mut d_h3 = vec![0.0f32; seq_len * hidden_dim];
            for i in 0..d_silu.len() {
                let h1_val = cache.h1[layer][i];
                let sigmoid = 1.0 / (1.0 + (-h1_val).exp());
                let silu = h1_val * sigmoid;
                let silu_grad = sigmoid * (1.0 + h1_val * (1.0 - sigmoid));

                d_h3[i] = d_silu[i] * silu;
                d_h1[i] = d_silu[i] * cache.h3[layer][i] * silu_grad;
            }

            // LoRA backward for gate (w1) and up (w3): input=ffn_in
            if let Some(a) = lora.get_mut(&format!("{lp}.gate_proj")) {
                a.backward_cpu(&cache.ffn_in[layer], &d_h1, seq_len);
            }
            if let Some(a) = lora.get_mut(&format!("{lp}.up_proj")) {
                a.backward_cpu(&cache.ffn_in[layer], &d_h3, seq_len);
            }

            // Backprop through w1 and w3
            let mut dx_ffn_in = vec![0.0f32; seq_len * dim];
            let mut dx_ffn_in2 = vec![0.0f32; seq_len * dim];
            cpu_matmul_backward_dx(&mut dx_ffn_in, &d_h1, &weights.w1[layer], seq_len, dim, hidden_dim);
            cpu_matmul_backward_dx(&mut dx_ffn_in2, &d_h3, &weights.w3[layer], seq_len, dim, hidden_dim);
            for i in 0..dx_ffn_in.len() {
                dx_ffn_in[i] += dx_ffn_in2[i];
            }

            // Backprop through FFN RMSNorm
            let mut dx_pre_ffn = vec![0.0f32; seq_len * dim];
            rmsnorm_backward(
                &mut dx_pre_ffn, &dx_ffn_in,
                &cache.x[layer], // approximate: should be post-attn residual
                &weights.rms_ffn_w[layer],
                seq_len, dim, config.norm_eps,
            );

            // Accumulate through residual
            for i in 0..dx.len() {
                dx[i] = dx_ffn[i] + dx_pre_ffn[i];
            }

            // --- Attention backward ---

            // LoRA backward for o_proj: input=attn_out, dy=dx (grad at o_proj output)
            if let Some(a) = lora.get_mut(&format!("{lp}.o_proj")) {
                a.backward_cpu(&cache.attn_out[layer], &dx, seq_len);
            }

            // Backprop through output projection
            let mut d_attn_out = vec![0.0f32; seq_len * dim];
            cpu_matmul_backward_dx(&mut d_attn_out, &dx, &weights.wo[layer], seq_len, dim, dim);

            // Backprop through attention (simplified)
            let (mut dq, mut dk, dv) = cpu_attention_backward(
                &d_attn_out,
                &cache.q[layer], &cache.k[layer], &cache.v[layer],
                seq_len, n_heads, head_dim,
            );

            // Backprop through RoPE (inverse rotation)
            apply_rope_backward(&mut dq, &mut dk, seq_len, n_heads, head_dim, config.rope_theta);

            // LoRA backward for Q, K, V projections: input=x_norm
            if let Some(adapter) = lora.get_mut(&format!("{lp}.q_proj")) {
                adapter.backward_cpu(&cache.x_norm[layer], &dq, seq_len);
            }
            if let Some(adapter) = lora.get_mut(&format!("{lp}.k_proj")) {
                adapter.backward_cpu(&cache.x_norm[layer], &dk, seq_len);
            }
            if let Some(adapter) = lora.get_mut(&format!("{lp}.v_proj")) {
                adapter.backward_cpu(&cache.x_norm[layer], &dv, seq_len);
            }

            // Backprop through Q, K, V projections to get dx
            let mut dx_q = vec![0.0f32; seq_len * dim];
            let mut dx_k = vec![0.0f32; seq_len * dim];
            let mut dx_v = vec![0.0f32; seq_len * dim];
            cpu_matmul_backward_dx(&mut dx_q, &dq, &weights.wq[layer], seq_len, dim, dim);
            cpu_matmul_backward_dx(&mut dx_k, &dk, &weights.wk[layer], seq_len, dim, dim);
            cpu_matmul_backward_dx(&mut dx_v, &dv, &weights.wv[layer], seq_len, dim, dim);

            let mut dx_attn_norm = vec![0.0f32; seq_len * dim];
            for i in 0..dx_attn_norm.len() {
                dx_attn_norm[i] = dx_q[i] + dx_k[i] + dx_v[i];
            }

            // Backprop through attention RMSNorm
            let mut dx_pre_attn = vec![0.0f32; seq_len * dim];
            rmsnorm_backward(
                &mut dx_pre_attn, &dx_attn_norm,
                &cache.x[layer],
                &weights.rms_att_w[layer],
                seq_len, dim, config.norm_eps,
            );

            // Accumulate through residual
            for i in 0..dx.len() {
                dx[i] += dx_pre_attn[i];
            }
        }
    }
}

/// Backward matmul: dx[seq,in] = dy[seq,out] @ W[out,in]  (BLAS-accelerated)
fn cpu_matmul_backward_dx(
    dx: &mut [f32], dy: &[f32], w: &[f32],
    seq_len: usize, in_dim: usize, out_dim: usize,
) {
    // Y[m,n] = X[m,k] @ W[k,n] with X=dy, W viewed as [out,in]=[k,n]
    crate::blas::matmul_nn(dx, dy, w, seq_len, out_dim, in_dim);
}

/// Simplified attention backward
fn cpu_attention_backward(
    dy: &[f32],
    q: &[f32], k: &[f32], v: &[f32],
    seq_len: usize, n_heads: usize, head_dim: usize,
) -> (Vec<f32>, Vec<f32>, Vec<f32>) {
    let dim = n_heads * head_dim;
    let mut dq = vec![0.0f32; seq_len * dim];
    let mut dk = vec![0.0f32; seq_len * dim];
    let mut dv = vec![0.0f32; seq_len * dim];

    let scale = 1.0 / (head_dim as f32).sqrt();

    for h in 0..n_heads {
        // Recompute attention scores for this head
        let mut scores = vec![0.0f32; seq_len * seq_len];

        for t in 0..seq_len {
            // Compute attention scores
            let mut max_score = f32::NEG_INFINITY;
            for s in 0..=t {
                let mut dot = 0.0f32;
                for d in 0..head_dim {
                    dot += q[t * dim + h * head_dim + d] * k[s * dim + h * head_dim + d];
                }
                scores[t * seq_len + s] = dot * scale;
                max_score = max_score.max(scores[t * seq_len + s]);
            }

            // Softmax
            let mut sum_exp = 0.0f32;
            for s in 0..=t {
                scores[t * seq_len + s] = (scores[t * seq_len + s] - max_score).exp();
                sum_exp += scores[t * seq_len + s];
            }
            for s in 0..=t {
                scores[t * seq_len + s] /= sum_exp;
            }

            // dV += scores^T @ dy
            for s in 0..=t {
                let w = scores[t * seq_len + s];
                for d in 0..head_dim {
                    dv[s * dim + h * head_dim + d] += w * dy[t * dim + h * head_dim + d];
                }
            }

            // d_scores = dy @ V^T
            let mut d_scores = vec![0.0f32; seq_len];
            for s in 0..=t {
                let mut dot = 0.0f32;
                for d in 0..head_dim {
                    dot += dy[t * dim + h * head_dim + d] * v[s * dim + h * head_dim + d];
                }
                d_scores[s] = dot;
            }

            // Softmax backward: ds_pre = scores * (ds - sum(scores * ds))
            let mut weighted_sum = 0.0f32;
            for s in 0..=t {
                weighted_sum += scores[t * seq_len + s] * d_scores[s];
            }

            for s in 0..=t {
                let ds = scores[t * seq_len + s] * (d_scores[s] - weighted_sum) * scale;

                // dQ
                for d in 0..head_dim {
                    dq[t * dim + h * head_dim + d] += ds * k[s * dim + h * head_dim + d];
                }
                // dK
                for d in 0..head_dim {
                    dk[s * dim + h * head_dim + d] += ds * q[t * dim + h * head_dim + d];
                }
            }
        }
    }

    (dq, dk, dv)
}

/// Backward pass through RoPE
fn apply_rope_backward(
    dq: &mut [f32], dk: &mut [f32],
    seq_len: usize, n_heads: usize, head_dim: usize, theta: f32,
) {
    let dim = n_heads * head_dim;
    for t in 0..seq_len {
        for h in 0..n_heads {
            for i in (0..head_dim).step_by(2) {
                let freq = 1.0 / theta.powf(i as f32 / head_dim as f32);
                let angle = t as f32 * freq;
                // Inverse rotation (transpose of rotation matrix)
                let cos_a = angle.cos();
                let sin_a = -angle.sin(); // Negative for inverse

                let qi = t * dim + h * head_dim + i;
                let qi1 = qi + 1;

                let dq0 = dq[qi];
                let dq1 = dq[qi1];
                dq[qi] = dq0 * cos_a - dq1 * sin_a;
                dq[qi1] = dq0 * sin_a + dq1 * cos_a;

                let dk0 = dk[qi];
                let dk1 = dk[qi1];
                dk[qi] = dk0 * cos_a - dk1 * sin_a;
                dk[qi1] = dk0 * sin_a + dk1 * cos_a;
            }
        }
    }
}
