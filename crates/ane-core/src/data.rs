use serde::{Deserialize, Serialize};

/// A single training sample
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Sample {
    pub tokens: Vec<u32>,
}

/// Chat format sample
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChatSample {
    pub messages: Vec<ChatMessage>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChatMessage {
    pub role: String,
    pub content: String,
}

/// Data pipeline configuration
pub struct DataPipeline {
    pub samples: Vec<Sample>,
    pub seq_len: usize,
    current_idx: usize,
}

impl DataPipeline {
    pub fn new(seq_len: usize) -> Self {
        Self {
            samples: Vec::new(),
            seq_len,
            current_idx: 0,
        }
    }

    /// Load samples from tokenized data
    pub fn from_tokens(tokens: Vec<u32>, seq_len: usize) -> Self {
        let mut samples = Vec::new();

        // Split into chunks of seq_len ( <= so an exact-length input still yields a sample)
        let mut i = 0;
        while i + seq_len <= tokens.len() {
            samples.push(Sample {
                tokens: tokens[i..i + seq_len].to_vec(),
            });
            i += seq_len;
        }

        // Guarantee at least one sample: if the corpus is shorter than seq_len,
        // use the whole thing rather than producing an empty (panicking) pipeline.
        if samples.is_empty() && !tokens.is_empty() {
            samples.push(Sample { tokens: tokens.clone() });
        }

        Self {
            samples,
            seq_len,
            current_idx: 0,
        }
    }

    /// Get next batch of samples
    pub fn next_batch(&mut self, batch_size: usize) -> Vec<&Sample> {
        let mut batch = Vec::with_capacity(batch_size);
        for _ in 0..batch_size {
            if self.current_idx >= self.samples.len() {
                self.current_idx = 0; // Wrap around
            }
            batch.push(&self.samples[self.current_idx]);
            self.current_idx += 1;
        }
        batch
    }

    /// Number of samples
    pub fn len(&self) -> usize {
        self.samples.len()
    }

    /// Check if empty
    pub fn is_empty(&self) -> bool {
        self.samples.is_empty()
    }

    /// Total tokens in dataset
    pub fn total_tokens(&self) -> usize {
        self.samples.iter().map(|s| s.tokens.len()).sum()
    }

    /// Number of complete epochs for given number of steps
    pub fn steps_per_epoch(&self) -> usize {
        self.samples.len()
    }

    /// Reset to beginning
    pub fn reset(&mut self) {
        self.current_idx = 0;
    }
}
