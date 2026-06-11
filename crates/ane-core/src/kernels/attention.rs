/// CPU multi-head causal attention
/// q, k, v: [seq_len, dim], output: [seq_len, dim]
pub fn cpu_attention(
    out: &mut [f32],
    q: &[f32], k: &[f32], v: &[f32],
    seq_len: usize, n_heads: usize, head_dim: usize,
) {
    let dim = n_heads * head_dim;
    let scale = 1.0 / (head_dim as f32).sqrt();

    out.fill(0.0);

    for h in 0..n_heads {
        for t in 0..seq_len {
            // Compute attention scores for position t, head h
            let mut max_score = f32::NEG_INFINITY;
            let mut scores = vec![0.0f32; t + 1];

            for s in 0..=t {
                let mut dot = 0.0f32;
                for d in 0..head_dim {
                    dot += q[t * dim + h * head_dim + d] * k[s * dim + h * head_dim + d];
                }
                scores[s] = dot * scale;
                max_score = max_score.max(scores[s]);
            }

            // Softmax
            let mut sum_exp = 0.0f32;
            for s in 0..=t {
                scores[s] = (scores[s] - max_score).exp();
                sum_exp += scores[s];
            }
            let inv_sum = 1.0 / sum_exp;
            for s in 0..=t {
                scores[s] *= inv_sum;
            }

            // Weighted sum of values
            for d in 0..head_dim {
                let mut val = 0.0f32;
                for s in 0..=t {
                    val += scores[s] * v[s * dim + h * head_dim + d];
                }
                out[t * dim + h * head_dim + d] = val;
            }
        }
    }
}
