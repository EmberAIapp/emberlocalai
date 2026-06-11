use pyo3::prelude::*;
use ane_core::Optimizer;

/// Python bindings for ANEForge core engine
#[pymodule]
fn _core(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_class::<PyChipInfo>()?;
    m.add_class::<PyModelConfig>()?;
    m.add_class::<PyLoRAConfig>()?;
    m.add_class::<PyTrainer>()?;
    m.add_function(wrap_pyfunction!(detect_hardware, m)?)?;
    m.add_function(wrap_pyfunction!(available_models, m)?)?;
    m.add_function(wrap_pyfunction!(version, m)?)?;
    Ok(())
}

#[pyfunction]
fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

#[pyfunction]
fn detect_hardware() -> PyResult<PyChipInfo> {
    // Use ane-sys detection
    let info = ane_sys::detect::ChipInfo::detect()
        .map_err(|e| PyErr::new::<pyo3::exceptions::PyRuntimeError, _>(e))?;

    let mem_gb = info.memory_gb();
    let has_ane = info.has_ane();
    let lora_rank = info.generation.recommended_lora_rank();
    let seq_len = info.generation.recommended_seq_len();
    let batch_size = info.generation.recommended_batch_size();
    let generation_str = format!("{}", info.generation);

    Ok(PyChipInfo {
        chip_name: info.chip_name,
        generation: generation_str,
        ane_cores: info.ane_cores,
        peak_tops: info.peak_tops,
        memory_gb: mem_gb,
        has_ane,
        recommended_lora_rank: lora_rank,
        recommended_seq_len: seq_len,
        recommended_batch_size: batch_size,
    })
}

#[pyfunction]
fn available_models() -> Vec<String> {
    vec![
        "SmolLM2-135M".into(),
        "SmolLM2-360M".into(),
        "Qwen2.5-0.5B".into(),
        "Phi-3-mini".into(),
        "TinyLlama-1.1B".into(),
        "Llama-3.2-1B".into(),
    ]
}

#[pyclass]
#[derive(Clone)]
struct PyChipInfo {
    #[pyo3(get)]
    chip_name: String,
    #[pyo3(get)]
    generation: String,
    #[pyo3(get)]
    ane_cores: i32,
    #[pyo3(get)]
    peak_tops: f32,
    #[pyo3(get)]
    memory_gb: f64,
    #[pyo3(get)]
    has_ane: bool,
    #[pyo3(get)]
    recommended_lora_rank: usize,
    #[pyo3(get)]
    recommended_seq_len: usize,
    #[pyo3(get)]
    recommended_batch_size: usize,
}

#[pymethods]
impl PyChipInfo {
    fn __repr__(&self) -> String {
        format!(
            "ChipInfo(chip='{}', gen='{}', ane_cores={}, tops={:.1}, mem={:.1}GB, ane={})",
            self.chip_name, self.generation, self.ane_cores,
            self.peak_tops, self.memory_gb, self.has_ane
        )
    }
}

#[pyclass]
#[derive(Clone)]
struct PyModelConfig {
    #[pyo3(get, set)]
    name: String,
    #[pyo3(get, set)]
    n_layers: usize,
    #[pyo3(get, set)]
    dim: usize,
    #[pyo3(get, set)]
    hidden_dim: usize,
    #[pyo3(get, set)]
    n_heads: usize,
    #[pyo3(get, set)]
    vocab_size: usize,
}

#[pymethods]
impl PyModelConfig {
    #[new]
    fn new(name: String) -> PyResult<Self> {
        let config = ane_core::ModelConfig::from_name(&name)
            .ok_or_else(|| PyErr::new::<pyo3::exceptions::PyValueError, _>(
                format!("Unknown model: {name}. Use aneforge.available_models() to see options.")
            ))?;

        Ok(Self {
            name: config.name,
            n_layers: config.n_layers,
            dim: config.dim,
            hidden_dim: config.hidden_dim,
            n_heads: config.n_heads,
            vocab_size: config.vocab_size,
        })
    }

    fn total_params(&self) -> usize {
        let config = ane_core::ModelConfig::from_name(&self.name).unwrap();
        config.total_params()
    }

    fn __repr__(&self) -> String {
        let params = self.total_params();
        let params_m = params as f64 / 1_000_000.0;
        format!(
            "ModelConfig(name='{}', layers={}, dim={}, params={:.1}M)",
            self.name, self.n_layers, self.dim, params_m
        )
    }
}

#[pyclass]
#[derive(Clone)]
struct PyLoRAConfig {
    #[pyo3(get, set)]
    rank: usize,
    #[pyo3(get, set)]
    alpha: f32,
    #[pyo3(get, set)]
    dropout: f32,
    #[pyo3(get, set)]
    target_modules: Vec<String>,
}

#[pymethods]
impl PyLoRAConfig {
    #[new]
    #[pyo3(signature = (rank=16, alpha=32.0, dropout=0.0, target_modules=None))]
    fn new(rank: usize, alpha: f32, dropout: f32, target_modules: Option<Vec<String>>) -> Self {
        Self {
            rank,
            alpha,
            dropout,
            target_modules: target_modules.unwrap_or_else(|| {
                vec!["q_proj".into(), "v_proj".into()]
            }),
        }
    }

    fn scaling(&self) -> f32 {
        self.alpha / self.rank as f32
    }

    fn __repr__(&self) -> String {
        format!(
            "LoRAConfig(rank={}, alpha={}, targets={:?})",
            self.rank, self.alpha, self.target_modules
        )
    }
}

#[pyclass]
struct PyTrainer {
    model_name: String,
    lora_config: PyLoRAConfig,
    step: usize,
    loss: f32,
    weights: Option<ane_core::ModelWeights>,
    lora: Option<ane_core::lora::LoRAModel>,
    optimizer: Option<ane_core::AdamW>,
}

#[pymethods]
impl PyTrainer {
    #[new]
    #[pyo3(signature = (model, lora=None))]
    fn new(model: String, lora: Option<PyLoRAConfig>) -> PyResult<Self> {
        // Validate model exists
        let _config = ane_core::ModelConfig::from_name(&model)
            .ok_or_else(|| PyErr::new::<pyo3::exceptions::PyValueError, _>(
                format!("Unknown model: {model}")
            ))?;

        Ok(Self {
            model_name: model,
            lora_config: lora.unwrap_or_else(|| PyLoRAConfig::new(16, 32.0, 0.0, None)),
            step: 0,
            loss: f32::INFINITY,
            weights: None,
            lora: None,
            optimizer: None,
        })
    }

    /// Load a weight tensor from raw f32 little-endian bytes.
    /// Names: token_embedding, classifier, rms_final,
    /// wq.{i}, wk.{i}, wv.{i}, wo.{i}, w1.{i}, w2.{i}, w3.{i}, rms_att.{i}, rms_ffn.{i}
    fn set_tensor(&mut self, name: &str, data: &[u8]) -> PyResult<()> {
        let config = ane_core::ModelConfig::from_name(&self.model_name).unwrap();
        if self.weights.is_none() {
            self.weights = Some(ane_core::ModelWeights::zeros(&config));
        }
        let w = self.weights.as_mut().unwrap();

        if data.len() % 4 != 0 {
            return Err(PyErr::new::<pyo3::exceptions::PyValueError, _>(
                format!("{name}: byte length {} not a multiple of 4", data.len())));
        }
        let values: Vec<f32> = data
            .chunks_exact(4)
            .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
            .collect();

        let target: &mut Vec<f32> = match name {
            "token_embedding" => &mut w.token_embedding,
            "classifier" => &mut w.classifier,
            "rms_final" => &mut w.rms_final_w,
            _ => {
                let (kind, idx) = name.rsplit_once('.').ok_or_else(|| {
                    PyErr::new::<pyo3::exceptions::PyValueError, _>(format!("Unknown tensor: {name}"))
                })?;
                let i: usize = idx.parse().map_err(|_| {
                    PyErr::new::<pyo3::exceptions::PyValueError, _>(format!("Bad layer index in: {name}"))
                })?;
                if i >= config.n_layers {
                    return Err(PyErr::new::<pyo3::exceptions::PyValueError, _>(
                        format!("{name}: layer {i} >= n_layers {}", config.n_layers)));
                }
                match kind {
                    "wq" => &mut w.wq[i],
                    "wk" => &mut w.wk[i],
                    "wv" => &mut w.wv[i],
                    "wo" => &mut w.wo[i],
                    "w1" => &mut w.w1[i],
                    "w2" => &mut w.w2[i],
                    "w3" => &mut w.w3[i],
                    "rms_att" => &mut w.rms_att_w[i],
                    "rms_ffn" => &mut w.rms_ffn_w[i],
                    _ => return Err(PyErr::new::<pyo3::exceptions::PyValueError, _>(
                        format!("Unknown tensor: {name}"))),
                }
            }
        };

        if values.len() != target.len() {
            return Err(PyErr::new::<pyo3::exceptions::PyValueError, _>(
                format!("{name}: got {} values, expected {}", values.len(), target.len())));
        }
        target.copy_from_slice(&values);
        Ok(())
    }

    fn has_weights(&self) -> bool {
        self.weights.is_some()
    }

    /// Real autoregressive generation with the actual forward pass + trained LoRA.
    /// Decoding quality controls (prevent the repetition collapse of pure greedy):
    ///   - repetition_penalty: divides the logit of already-seen tokens (1.0 = off, ~1.3 typical)
    ///   - no_repeat_ngram: blocks repeating any n-gram of this size (0 = off, 2-3 typical)
    /// This is REAL inference — not random sampling.
    #[pyo3(signature = (prompt_tokens, max_new_tokens=32, eos_token=None,
                        repetition_penalty=1.3, no_repeat_ngram=3))]
    fn generate(
        &self,
        prompt_tokens: Vec<u32>,
        max_new_tokens: usize,
        eos_token: Option<u32>,
        repetition_penalty: f32,
        no_repeat_ngram: usize,
    ) -> PyResult<Vec<u32>> {
        let weights = self.weights.as_ref().ok_or_else(|| {
            PyErr::new::<pyo3::exceptions::PyRuntimeError, _>(
                "No weights loaded. Call set_tensor() first.")
        })?;
        let config = &weights.config;
        let vocab = config.vocab_size;

        let mut tokens = prompt_tokens;
        if tokens.is_empty() {
            return Ok(vec![]);
        }
        let prompt_len = tokens.len();
        let mut generated = Vec::with_capacity(max_new_tokens);

        for _ in 0..max_new_tokens {
            let seq = tokens.len().min(config.max_seq_len);
            let ctx = &tokens[tokens.len() - seq..];

            let (_loss, cache) = ane_core::ForwardPass::forward(weights, self.lora.as_ref(), ctx, seq);

            let last = (seq - 1) * vocab;
            let mut logits = cache.logits[last..last + vocab].to_vec();

            // Repetition penalty: discourage tokens already in the sequence.
            if (repetition_penalty - 1.0).abs() > 1e-6 {
                for &tok in tokens.iter() {
                    let t = tok as usize;
                    if t < vocab {
                        let l = logits[t];
                        logits[t] = if l > 0.0 { l / repetition_penalty } else { l * repetition_penalty };
                    }
                }
            }

            // No-repeat n-gram: forbid completing an n-gram that already occurred.
            if no_repeat_ngram >= 2 && tokens.len() >= no_repeat_ngram {
                let n = no_repeat_ngram;
                let prefix = &tokens[tokens.len() - (n - 1)..]; // last n-1 tokens
                for i in 0..=tokens.len().saturating_sub(n) {
                    if &tokens[i..i + n - 1] == prefix {
                        let banned = tokens[i + n - 1] as usize;
                        if banned < vocab {
                            logits[banned] = f32::NEG_INFINITY;
                        }
                    }
                }
            }

            // Argmax over the adjusted logits
            let mut best = 0usize;
            let mut best_v = f32::NEG_INFINITY;
            for (i, &v) in logits.iter().enumerate() {
                if v > best_v {
                    best_v = v;
                    best = i;
                }
            }
            let next = best as u32;
            generated.push(next);
            if Some(next) == eos_token {
                break;
            }
            tokens.push(next);
        }

        let _ = prompt_len;
        Ok(generated)
    }

    /// Train on tokenized data (list of token IDs)
    #[pyo3(signature = (tokens, steps=100, lr=1e-4, seq_len=256))]
    fn train_on_tokens(
        &mut self,
        tokens: Vec<u32>,
        steps: usize,
        lr: f32,
        seq_len: usize,
    ) -> PyResult<Vec<f32>> {
        let config = ane_core::ModelConfig::from_name(&self.model_name).unwrap();
        if self.weights.is_none() {
            self.weights = Some(ane_core::ModelWeights::zeros(&config));
        }

        let lora_config = ane_core::LoRAConfig {
            rank: self.lora_config.rank,
            alpha: self.lora_config.alpha,
            dropout: self.lora_config.dropout,
            target_modules: self.lora_config.target_modules.clone(),
        };

        // Reuse the existing adapter if we're continuing training (incremental
        // learning), otherwise start fresh.
        let mut lora = self.lora.take().unwrap_or_else(|| {
            ane_core::lora::LoRAModel::new(
                &lora_config,
                config.n_layers,
                config.dim,
                config.hidden_dim,
            )
        });

        let weights = self.weights.take().unwrap();
        // Persist the optimizer across calls so Adam's moment estimates and
        // step counter stay continuous (correct incremental learning, no divergence).
        let mut optimizer = self.optimizer.take().unwrap_or_else(|| ane_core::AdamW::new(lr));
        optimizer.lr = lr;
        let mut losses = Vec::with_capacity(steps);

        // Create data pipeline
        let mut data = ane_core::DataPipeline::from_tokens(tokens, seq_len);

        let base_lr = lr;
        let mut best_loss = f32::INFINITY;
        // Snapshot of the best (lowest-loss) adapter state, so a late divergence
        // never corrupts the result we keep.
        let mut best_snapshot: Option<Vec<(Vec<f32>, Vec<f32>)>> = None;
        let pi = std::f32::consts::PI;

        for step in 0..steps {
            // Cosine LR decay: large steps early, tiny steps near the minimum.
            // Prevents the classic overshoot-and-diverge once loss gets low.
            let progress = if steps > 1 { step as f32 / (steps - 1) as f32 } else { 0.0 };
            optimizer.lr = base_lr * 0.5 * (1.0 + (pi * progress).cos());

            let batch = data.next_batch(1);
            let sample_tokens = &batch[0].tokens;
            let actual_seq = sample_tokens.len().min(seq_len);

            // Forward pass
            let (loss, cache) = ane_core::ForwardPass::forward(
                &weights,
                Some(&lora),
                sample_tokens,
                actual_seq,
            );

            // Backward pass
            lora.zero_grad();
            ane_core::BackwardPass::backward(
                &weights,
                &mut lora,
                sample_tokens,
                &cache,
                actual_seq,
            );

            // Optimizer step
            optimizer.step(&mut lora);

            // Keep the best-loss adapter snapshot
            if loss.is_finite() && loss < best_loss {
                best_loss = loss;
                best_snapshot = Some(
                    lora.adapters.iter().map(|(_, a)| (a.a.clone(), a.b.clone())).collect()
                );
            }

            self.step = step + 1;
            self.loss = loss;
            losses.push(loss);
        }

        // Restore the best-loss adapter (discard any late divergence)
        if let Some(snap) = best_snapshot {
            for ((_, adapter), (a, b)) in lora.adapters.iter_mut().zip(snap) {
                adapter.a.copy_from_slice(&a);
                adapter.b.copy_from_slice(&b);
            }
            self.loss = best_loss;
        }

        self.weights = Some(weights);
        self.lora = Some(lora);
        self.optimizer = Some(optimizer);
        Ok(losses)
    }

    /// Export trained LoRA adapters as (name, in_dim, out_dim, rank, a_bytes, b_bytes).
    /// Bytes are f32 little-endian. Returns empty if no adapter trained yet.
    fn get_lora(&self) -> Vec<(String, usize, usize, usize, Vec<u8>, Vec<u8>)> {
        let mut out = Vec::new();
        if let Some(lora) = &self.lora {
            for (name, ad) in &lora.adapters {
                let a_bytes: Vec<u8> = ad.a.iter().flat_map(|v| v.to_le_bytes()).collect();
                let b_bytes: Vec<u8> = ad.b.iter().flat_map(|v| v.to_le_bytes()).collect();
                out.push((name.clone(), ad.in_dim, ad.out_dim, ad.config.rank, a_bytes, b_bytes));
            }
        }
        out
    }

    /// Load a trained LoRA adapter back in (for inference or resumed training).
    fn set_lora(&mut self, name: String, a_bytes: &[u8], b_bytes: &[u8]) -> PyResult<()> {
        let config = ane_core::ModelConfig::from_name(&self.model_name).unwrap();
        let lora_config = ane_core::LoRAConfig {
            rank: self.lora_config.rank,
            alpha: self.lora_config.alpha,
            dropout: self.lora_config.dropout,
            target_modules: self.lora_config.target_modules.clone(),
        };
        if self.lora.is_none() {
            self.lora = Some(ane_core::lora::LoRAModel::new(
                &lora_config, config.n_layers, config.dim, config.hidden_dim,
            ));
        }
        let to_f32 = |b: &[u8]| -> Vec<f32> {
            b.chunks_exact(4).map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]])).collect()
        };
        let a = to_f32(a_bytes);
        let b = to_f32(b_bytes);
        let lora = self.lora.as_mut().unwrap();
        let ad = lora.get_mut(&name).ok_or_else(|| {
            PyErr::new::<pyo3::exceptions::PyValueError, _>(format!("Unknown adapter: {name}"))
        })?;
        if a.len() != ad.a.len() || b.len() != ad.b.len() {
            return Err(PyErr::new::<pyo3::exceptions::PyValueError, _>(format!(
                "{name}: size mismatch (a {} vs {}, b {} vs {})",
                a.len(), ad.a.len(), b.len(), ad.b.len())));
        }
        ad.a.copy_from_slice(&a);
        ad.b.copy_from_slice(&b);
        Ok(())
    }

    fn get_step(&self) -> usize {
        self.step
    }

    fn get_loss(&self) -> f32 {
        self.loss
    }

    fn __repr__(&self) -> String {
        format!(
            "Trainer(model='{}', lora_rank={}, step={}, loss={:.4})",
            self.model_name, self.lora_config.rank, self.step, self.loss
        )
    }
}
