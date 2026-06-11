use serde::{Deserialize, Serialize};

/// LoRA configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LoRAConfig {
    pub rank: usize,
    pub alpha: f32,
    pub dropout: f32,
    pub target_modules: Vec<String>,
}

impl Default for LoRAConfig {
    fn default() -> Self {
        Self {
            rank: 16,
            alpha: 32.0,
            dropout: 0.0,
            target_modules: vec![
                "q_proj".into(),
                "v_proj".into(),
            ],
        }
    }
}

impl LoRAConfig {
    pub fn scaling(&self) -> f32 {
        self.alpha / self.rank as f32
    }

    /// Full LoRA (all attention + FFN projections)
    pub fn full(rank: usize) -> Self {
        Self {
            rank,
            alpha: rank as f32 * 2.0,
            dropout: 0.0,
            target_modules: vec![
                "q_proj".into(),
                "k_proj".into(),
                "v_proj".into(),
                "o_proj".into(),
                "gate_proj".into(),
                "up_proj".into(),
                "down_proj".into(),
            ],
        }
    }
}

/// A single LoRA adapter pair (A, B matrices)
pub struct LoRAAdapter {
    pub config: LoRAConfig,
    pub in_dim: usize,
    pub out_dim: usize,

    /// Down projection: [rank, in_dim] (initialized with Kaiming)
    pub a: Vec<f32>,
    /// Up projection: [out_dim, rank] (initialized to zero)
    pub b: Vec<f32>,

    // Gradients
    pub grad_a: Vec<f32>,
    pub grad_b: Vec<f32>,

    // Adam state
    pub m_a: Vec<f32>,
    pub v_a: Vec<f32>,
    pub m_b: Vec<f32>,
    pub v_b: Vec<f32>,
}

impl LoRAAdapter {
    /// Create a new LoRA adapter with proper initialization
    pub fn new(config: &LoRAConfig, in_dim: usize, out_dim: usize) -> Self {
        let rank = config.rank;

        // Kaiming initialization for A
        let std_dev = (2.0 / in_dim as f64).sqrt() as f32;
        let a: Vec<f32> = (0..rank * in_dim)
            .map(|i| {
                // Simple deterministic pseudo-random for reproducibility
                let x = ((i as f32 * 0.618034 + 0.5) % 1.0) * 2.0 - 1.0;
                x * std_dev
            })
            .collect();

        // B initialized to zero (so initial LoRA output is zero)
        let b = vec![0.0; out_dim * rank];

        Self {
            config: config.clone(),
            in_dim,
            out_dim,
            a,
            b,
            grad_a: vec![0.0; rank * in_dim],
            grad_b: vec![0.0; out_dim * rank],
            m_a: vec![0.0; rank * in_dim],
            v_a: vec![0.0; rank * in_dim],
            m_b: vec![0.0; out_dim * rank],
            v_b: vec![0.0; out_dim * rank],
        }
    }

    /// CPU forward pass: y_lora = scale * B @ A @ x
    /// x shape: [seq_len, in_dim], output: [seq_len, out_dim]
    pub fn forward_cpu(&self, x: &[f32], seq_len: usize) -> Vec<f32> {
        let rank = self.config.rank;
        let scale = self.config.scaling();

        // Step 1: hidden = A @ x^T → [rank, seq_len]
        let mut hidden = vec![0.0f32; rank * seq_len];
        for r in 0..rank {
            for t in 0..seq_len {
                let mut sum = 0.0f32;
                for d in 0..self.in_dim {
                    sum += self.a[r * self.in_dim + d] * x[t * self.in_dim + d];
                }
                hidden[r * seq_len + t] = sum;
            }
        }

        // Step 2: output = B @ hidden → [out_dim, seq_len]
        let mut output = vec![0.0f32; self.out_dim * seq_len];
        for o in 0..self.out_dim {
            for t in 0..seq_len {
                let mut sum = 0.0f32;
                for r in 0..rank {
                    sum += self.b[o * rank + r] * hidden[r * seq_len + t];
                }
                output[t * self.out_dim + o] = sum * scale;
            }
        }

        output
    }

    /// CPU backward pass: compute gradients for A and B
    pub fn backward_cpu(
        &mut self,
        x: &[f32],       // [seq_len, in_dim]
        dy: &[f32],      // [seq_len, out_dim]
        seq_len: usize,
    ) -> Vec<f32> {
        let rank = self.config.rank;
        let scale = self.config.scaling();

        // Recompute hidden = A @ x
        let mut hidden = vec![0.0f32; rank * seq_len];
        for r in 0..rank {
            for t in 0..seq_len {
                let mut sum = 0.0f32;
                for d in 0..self.in_dim {
                    sum += self.a[r * self.in_dim + d] * x[t * self.in_dim + d];
                }
                hidden[r * seq_len + t] = sum;
            }
        }

        // Gradient for B: dB = scale * dy^T @ hidden^T → [out_dim, rank]
        for o in 0..self.out_dim {
            for r in 0..rank {
                let mut sum = 0.0f32;
                for t in 0..seq_len {
                    sum += dy[t * self.out_dim + o] * hidden[r * seq_len + t];
                }
                self.grad_b[o * rank + r] += sum * scale;
            }
        }

        // d_hidden = B^T @ dy → [rank, seq_len]
        let mut d_hidden = vec![0.0f32; rank * seq_len];
        for r in 0..rank {
            for t in 0..seq_len {
                let mut sum = 0.0f32;
                for o in 0..self.out_dim {
                    sum += self.b[o * rank + r] * dy[t * self.out_dim + o];
                }
                d_hidden[r * seq_len + t] = sum * scale;
            }
        }

        // Gradient for A: dA = d_hidden @ x → [rank, in_dim]
        for r in 0..rank {
            for d in 0..self.in_dim {
                let mut sum = 0.0f32;
                for t in 0..seq_len {
                    sum += d_hidden[r * seq_len + t] * x[t * self.in_dim + d];
                }
                self.grad_a[r * self.in_dim + d] += sum;
            }
        }

        // dx (gradient for input) = A^T @ d_hidden → [seq_len, in_dim]
        let mut dx = vec![0.0f32; seq_len * self.in_dim];
        for t in 0..seq_len {
            for d in 0..self.in_dim {
                let mut sum = 0.0f32;
                for r in 0..rank {
                    sum += self.a[r * self.in_dim + d] * d_hidden[r * seq_len + t];
                }
                dx[t * self.in_dim + d] = sum;
            }
        }

        dx
    }

    /// Zero gradients
    pub fn zero_grad(&mut self) {
        self.grad_a.fill(0.0);
        self.grad_b.fill(0.0);
    }

    /// Number of trainable parameters
    pub fn num_params(&self) -> usize {
        self.a.len() + self.b.len()
    }
}

/// Collection of LoRA adapters for an entire model
pub struct LoRAModel {
    pub config: LoRAConfig,
    pub adapters: Vec<(String, LoRAAdapter)>, // (layer_name, adapter)
}

impl LoRAModel {
    /// Create LoRA adapters for all target modules across all layers
    pub fn new(
        config: &LoRAConfig,
        n_layers: usize,
        dim: usize,
        hidden_dim: usize,
    ) -> Self {
        let mut adapters = Vec::new();

        for layer in 0..n_layers {
            for module in &config.target_modules {
                let (in_d, out_d) = match module.as_str() {
                    "q_proj" | "k_proj" | "v_proj" | "o_proj" => (dim, dim),
                    "gate_proj" | "up_proj" => (dim, hidden_dim),
                    "down_proj" => (hidden_dim, dim),
                    _ => continue,
                };

                let name = format!("layers.{layer}.{module}");
                let adapter = LoRAAdapter::new(config, in_d, out_d);
                adapters.push((name, adapter));
            }
        }

        Self {
            config: config.clone(),
            adapters,
        }
    }

    /// Total trainable parameters
    pub fn total_params(&self) -> usize {
        self.adapters.iter().map(|(_, a)| a.num_params()).sum()
    }

    /// Zero all gradients
    pub fn zero_grad(&mut self) {
        for (_, adapter) in &mut self.adapters {
            adapter.zero_grad();
        }
    }

    /// Get adapter by name
    pub fn get(&self, name: &str) -> Option<&LoRAAdapter> {
        self.adapters.iter().find(|(n, _)| n == name).map(|(_, a)| a)
    }

    /// Get mutable adapter by name
    pub fn get_mut(&mut self, name: &str) -> Option<&mut LoRAAdapter> {
        self.adapters.iter_mut().find(|(n, _)| n == name).map(|(_, a)| a)
    }
}
