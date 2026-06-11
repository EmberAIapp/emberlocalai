/// RMS Normalization: y = x / sqrt(mean(x^2) + eps) * weight
pub fn rmsnorm(
    out: &mut [f32],
    x: &[f32],
    weight: &[f32],
    seq_len: usize,
    dim: usize,
    eps: f32,
) {
    for t in 0..seq_len {
        let offset = t * dim;

        // Compute RMS
        let mut sum_sq = 0.0f32;
        for d in 0..dim {
            sum_sq += x[offset + d] * x[offset + d];
        }
        let rms = (sum_sq / dim as f32 + eps).sqrt();
        let inv_rms = 1.0 / rms;

        // Normalize and scale
        for d in 0..dim {
            out[offset + d] = x[offset + d] * inv_rms * weight[d];
        }
    }
}

/// RMSNorm backward pass
pub fn rmsnorm_backward(
    dx: &mut [f32],
    dy: &[f32],
    x: &[f32],
    weight: &[f32],
    seq_len: usize,
    dim: usize,
    eps: f32,
) {
    for t in 0..seq_len {
        let offset = t * dim;

        // Recompute forward values
        let mut sum_sq = 0.0f32;
        for d in 0..dim {
            sum_sq += x[offset + d] * x[offset + d];
        }
        let variance = sum_sq / dim as f32;
        let rms = (variance + eps).sqrt();
        let inv_rms = 1.0 / rms;

        // Compute intermediate
        let mut dy_x_sum = 0.0f32;
        for d in 0..dim {
            dy_x_sum += dy[offset + d] * weight[d] * x[offset + d];
        }

        let coeff = dy_x_sum / (dim as f32 * rms * rms);

        for d in 0..dim {
            dx[offset + d] = (dy[offset + d] * weight[d] - x[offset + d] * coeff) * inv_rms;
        }
    }
}
