use crate::lora::LoRAModel;

pub trait Optimizer {
    fn step(&mut self, lora: &mut LoRAModel);
}

/// AdamW optimizer for LoRA parameters
pub struct AdamW {
    pub lr: f32,
    pub beta1: f32,
    pub beta2: f32,
    pub eps: f32,
    pub weight_decay: f32,
    pub step_count: usize,
    pub max_grad_norm: f32,
}

impl Default for AdamW {
    fn default() -> Self {
        Self {
            lr: 1e-4,
            beta1: 0.9,
            beta2: 0.999,
            eps: 1e-8,
            weight_decay: 0.01,
            step_count: 0,
            max_grad_norm: 1.0,
        }
    }
}

impl AdamW {
    pub fn new(lr: f32) -> Self {
        Self { lr, ..Default::default() }
    }

    /// Clip gradients by global norm
    fn clip_gradients(&self, lora: &mut LoRAModel) {
        let mut total_norm_sq = 0.0f32;

        for (_, adapter) in &lora.adapters {
            for &g in &adapter.grad_a {
                total_norm_sq += g * g;
            }
            for &g in &adapter.grad_b {
                total_norm_sq += g * g;
            }
        }

        let total_norm = total_norm_sq.sqrt();
        if total_norm > self.max_grad_norm {
            let scale = self.max_grad_norm / (total_norm + 1e-6);
            for (_, adapter) in &mut lora.adapters {
                for g in &mut adapter.grad_a {
                    *g *= scale;
                }
                for g in &mut adapter.grad_b {
                    *g *= scale;
                }
            }
        }
    }
}

impl Optimizer for AdamW {
    fn step(&mut self, lora: &mut LoRAModel) {
        self.step_count += 1;
        let t = self.step_count as f32;

        // Gradient clipping
        self.clip_gradients(lora);

        let bias_correction1 = 1.0 - self.beta1.powf(t);
        let bias_correction2 = 1.0 - self.beta2.powf(t);

        for (_, adapter) in &mut lora.adapters {
            // Update A weights
            adam_update_params(
                &mut adapter.a,
                &adapter.grad_a,
                &mut adapter.m_a,
                &mut adapter.v_a,
                self.lr, self.beta1, self.beta2, self.eps,
                self.weight_decay, bias_correction1, bias_correction2,
            );

            // Update B weights
            adam_update_params(
                &mut adapter.b,
                &adapter.grad_b,
                &mut adapter.m_b,
                &mut adapter.v_b,
                self.lr, self.beta1, self.beta2, self.eps,
                self.weight_decay, bias_correction1, bias_correction2,
            );
        }
    }
}

fn adam_update_params(
    params: &mut [f32],
    grads: &[f32],
    m: &mut [f32],
    v: &mut [f32],
    lr: f32, beta1: f32, beta2: f32, eps: f32,
    weight_decay: f32, bc1: f32, bc2: f32,
) {
    for i in 0..params.len() {
        let g = grads[i];

        // AdamW: decoupled weight decay
        params[i] *= 1.0 - lr * weight_decay;

        // Momentum
        m[i] = beta1 * m[i] + (1.0 - beta1) * g;
        // Velocity
        v[i] = beta2 * v[i] + (1.0 - beta2) * g * g;

        // Bias-corrected estimates
        let m_hat = m[i] / bc1;
        let v_hat = v[i] / bc2;

        // Update
        params[i] -= lr * m_hat / (v_hat.sqrt() + eps);
    }
}
