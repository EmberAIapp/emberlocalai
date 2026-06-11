/// SiLU (Swish) activation: x * sigmoid(x)
pub fn silu(x: f32) -> f32 {
    x / (1.0 + (-x).exp())
}

/// SiLU derivative: sigmoid(x) * (1 + x * (1 - sigmoid(x)))
pub fn silu_backward(x: f32) -> f32 {
    let sigmoid = 1.0 / (1.0 + (-x).exp());
    sigmoid * (1.0 + x * (1.0 - sigmoid))
}

/// SwiGLU FFN forward: output = w2 @ (silu(w1 @ x) * (w3 @ x))
pub fn swiglu_forward(
    out: &mut [f32],
    h1: &mut [f32],
    h3: &mut [f32],
    silu_out: &mut [f32],
    x: &[f32],
    w1: &[f32], w2: &[f32], w3: &[f32],
    seq_len: usize, dim: usize, hidden_dim: usize,
) {
    // Gate projection: h1 = x @ w1^T
    cpu_matmul(h1, x, w1, seq_len, dim, hidden_dim);

    // Up projection: h3 = x @ w3^T
    cpu_matmul(h3, x, w3, seq_len, dim, hidden_dim);

    // SiLU gate: silu_out = silu(h1) * h3
    for i in 0..seq_len * hidden_dim {
        silu_out[i] = silu(h1[i]) * h3[i];
    }

    // Down projection: out = silu_out @ w2^T
    cpu_matmul(out, silu_out, w2, seq_len, hidden_dim, dim);
}

fn cpu_matmul(y: &mut [f32], x: &[f32], w: &[f32], s: usize, in_d: usize, out_d: usize) {
    for t in 0..s {
        for o in 0..out_d {
            let mut sum = 0.0f32;
            for d in 0..in_d {
                sum += x[t * in_d + d] * w[o * in_d + d];
            }
            y[t * out_d + o] = sum;
        }
    }
}
