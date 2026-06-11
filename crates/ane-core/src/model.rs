use serde::{Deserialize, Serialize};

/// Configuration for a transformer model
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelConfig {
    pub name: String,
    pub n_layers: usize,
    pub dim: usize,
    pub hidden_dim: usize,
    pub n_heads: usize,
    pub n_kv_heads: usize,
    pub head_dim: usize,
    pub vocab_size: usize,
    pub max_seq_len: usize,
    pub norm_eps: f32,
    pub rope_theta: f32,
}

impl ModelConfig {
    /// SmolLM2-135M configuration
    pub fn smollm2_135m() -> Self {
        Self {
            name: "SmolLM2-135M".into(),
            n_layers: 30,
            dim: 576,
            hidden_dim: 1536,
            n_heads: 9,
            n_kv_heads: 3,
            head_dim: 64,
            vocab_size: 49152,
            max_seq_len: 2048,
            norm_eps: 1e-5,
            rope_theta: 10000.0,
        }
    }

    /// SmolLM2-360M configuration
    pub fn smollm2_360m() -> Self {
        Self {
            name: "SmolLM2-360M".into(),
            n_layers: 32,
            dim: 960,
            hidden_dim: 2560,
            n_heads: 15,
            n_kv_heads: 5,
            head_dim: 64,
            vocab_size: 49152,
            max_seq_len: 2048,
            norm_eps: 1e-5,
            rope_theta: 10000.0,
        }
    }

    /// Qwen2.5-0.5B configuration
    pub fn qwen25_05b() -> Self {
        Self {
            name: "Qwen2.5-0.5B".into(),
            n_layers: 24,
            dim: 896,
            hidden_dim: 4864,
            n_heads: 14,
            n_kv_heads: 2,
            head_dim: 64,
            vocab_size: 151936,
            max_seq_len: 4096,
            norm_eps: 1e-6,
            rope_theta: 1000000.0,
        }
    }

    /// Phi-3-mini configuration
    pub fn phi3_mini() -> Self {
        Self {
            name: "Phi-3-mini".into(),
            n_layers: 32,
            dim: 3072,
            hidden_dim: 8192,
            n_heads: 32,
            n_kv_heads: 32,
            head_dim: 96,
            vocab_size: 32064,
            max_seq_len: 4096,
            norm_eps: 1e-5,
            rope_theta: 10000.0,
        }
    }

    /// TinyLlama-1.1B configuration
    pub fn tinyllama() -> Self {
        Self {
            name: "TinyLlama-1.1B".into(),
            n_layers: 22,
            dim: 2048,
            hidden_dim: 5632,
            n_heads: 32,
            n_kv_heads: 4,
            head_dim: 64,
            vocab_size: 32000,
            max_seq_len: 2048,
            norm_eps: 1e-5,
            rope_theta: 10000.0,
        }
    }

    /// Llama-3.2-1B configuration
    pub fn llama32_1b() -> Self {
        Self {
            name: "Llama-3.2-1B".into(),
            n_layers: 16,
            dim: 2048,
            hidden_dim: 8192,
            n_heads: 32,
            n_kv_heads: 8,
            head_dim: 64,
            vocab_size: 128256,
            max_seq_len: 8192,
            norm_eps: 1e-5,
            rope_theta: 500000.0,
        }
    }

    /// Total parameters (approximate)
    pub fn total_params(&self) -> usize {
        let embed = self.vocab_size * self.dim;
        let attn_per_layer = 4 * self.dim * self.dim; // Q, K, V, O
        let ffn_per_layer = 3 * self.dim * self.hidden_dim; // w1, w2, w3
        let norm_per_layer = 2 * self.dim; // attn_norm, ffn_norm
        let layer = attn_per_layer + ffn_per_layer + norm_per_layer;
        embed + self.n_layers * layer + self.dim + self.vocab_size * self.dim
    }

    /// Estimated memory in bytes (FP32)
    pub fn memory_bytes_f32(&self) -> usize {
        self.total_params() * 4
    }

    /// Find config by name (case-insensitive)
    pub fn from_name(name: &str) -> Option<Self> {
        let lower = name.to_lowercase();
        if lower.contains("smollm") && lower.contains("135") {
            Some(Self::smollm2_135m())
        } else if lower.contains("smollm") && lower.contains("360") {
            Some(Self::smollm2_360m())
        } else if lower.contains("qwen") && lower.contains("0.5") {
            Some(Self::qwen25_05b())
        } else if lower.contains("phi") && lower.contains("3") {
            Some(Self::phi3_mini())
        } else if lower.contains("tinyllama") {
            Some(Self::tinyllama())
        } else if lower.contains("llama") && lower.contains("1b") {
            Some(Self::llama32_1b())
        } else {
            None
        }
    }
}

/// Stores model weights in memory
pub struct ModelWeights {
    pub config: ModelConfig,

    // Embeddings
    pub token_embedding: Vec<f32>,

    // Per-layer weights
    pub wq: Vec<Vec<f32>>,
    pub wk: Vec<Vec<f32>>,
    pub wv: Vec<Vec<f32>>,
    pub wo: Vec<Vec<f32>>,
    pub w1: Vec<Vec<f32>>,  // FFN gate
    pub w2: Vec<Vec<f32>>,  // FFN down
    pub w3: Vec<Vec<f32>>,  // FFN up
    pub rms_att_w: Vec<Vec<f32>>,
    pub rms_ffn_w: Vec<Vec<f32>>,

    // Final
    pub rms_final_w: Vec<f32>,
    pub classifier: Vec<f32>,
}

impl ModelWeights {
    /// Create uninitialized weights for a config
    pub fn zeros(config: &ModelConfig) -> Self {
        let n = config.n_layers;
        let d = config.dim;
        let h = config.hidden_dim;
        let v = config.vocab_size;

        Self {
            config: config.clone(),
            token_embedding: vec![0.0; v * d],
            wq: (0..n).map(|_| vec![0.0; d * d]).collect(),
            wk: (0..n).map(|_| vec![0.0; d * d]).collect(),
            wv: (0..n).map(|_| vec![0.0; d * d]).collect(),
            wo: (0..n).map(|_| vec![0.0; d * d]).collect(),
            w1: (0..n).map(|_| vec![0.0; d * h]).collect(),
            w2: (0..n).map(|_| vec![0.0; h * d]).collect(),
            w3: (0..n).map(|_| vec![0.0; d * h]).collect(),
            rms_att_w: (0..n).map(|_| vec![0.0; d]).collect(),
            rms_ffn_w: (0..n).map(|_| vec![0.0; d]).collect(),
            rms_final_w: vec![0.0; d],
            classifier: vec![0.0; d * v],
        }
    }
}

/// Full transformer model with weights and compiled ANE kernels
pub struct TransformerModel {
    pub weights: ModelWeights,
    pub config: ModelConfig,
}

impl TransformerModel {
    pub fn new(weights: ModelWeights) -> Self {
        let config = weights.config.clone();
        Self { weights, config }
    }
}
