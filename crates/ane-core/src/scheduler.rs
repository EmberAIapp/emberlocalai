/// Multi-layer training scheduler
/// Handles the pipeline of compiling and executing across transformer layers

use crate::model::ModelConfig;

pub struct TrainingScheduler {
    pub config: ModelConfig,
    pub current_layer: usize,
    pub grad_accum_steps: usize,
    pub current_accum: usize,
}

impl TrainingScheduler {
    pub fn new(config: ModelConfig, grad_accum_steps: usize) -> Self {
        Self {
            config,
            current_layer: 0,
            grad_accum_steps,
            current_accum: 0,
        }
    }

    /// Check if we should perform an optimizer step
    pub fn should_step(&self) -> bool {
        self.current_accum >= self.grad_accum_steps
    }

    /// Advance the accumulation counter
    pub fn advance(&mut self) {
        self.current_accum += 1;
    }

    /// Reset accumulation counter after optimizer step
    pub fn reset(&mut self) {
        self.current_accum = 0;
    }

    /// Compute effective learning rate with warmup and decay
    pub fn get_lr(&self, base_lr: f32, step: usize, warmup_steps: usize, total_steps: usize) -> f32 {
        if step < warmup_steps {
            // Linear warmup
            base_lr * step as f32 / warmup_steps as f32
        } else {
            // Cosine decay
            let progress = (step - warmup_steps) as f32 / (total_steps - warmup_steps) as f32;
            let decay = 0.5 * (1.0 + (std::f32::consts::PI * progress).cos());
            base_lr * decay.max(0.1) // Don't decay below 10% of base LR
        }
    }
}
