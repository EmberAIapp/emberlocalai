/// Process management for ANE compilation limit workaround
///
/// ANE has a ~119 compilation limit per process. When approaching this limit,
/// we need to checkpoint and restart the worker process transparently.

use std::path::PathBuf;

const MAX_COMPILATIONS: i32 = 110; // Leave 9 as safety margin
const CHECKPOINT_DIR: &str = "/tmp/aneforge_checkpoints";

pub struct ProcessManager {
    compilation_count: i32,
    checkpoint_path: PathBuf,
}

impl ProcessManager {
    pub fn new() -> Self {
        std::fs::create_dir_all(CHECKPOINT_DIR).ok();
        Self {
            compilation_count: 0,
            checkpoint_path: PathBuf::from(CHECKPOINT_DIR),
        }
    }

    /// Track a compilation
    pub fn track_compilation(&mut self) {
        self.compilation_count += 1;
    }

    /// Check if we're approaching the limit
    pub fn near_limit(&self) -> bool {
        self.compilation_count >= MAX_COMPILATIONS
    }

    /// Get remaining compilations
    pub fn remaining(&self) -> i32 {
        MAX_COMPILATIONS - self.compilation_count
    }

    /// Reset count (after process restart)
    pub fn reset(&mut self) {
        self.compilation_count = 0;
    }

    /// Get checkpoint path for saving state
    pub fn checkpoint_path(&self) -> PathBuf {
        self.checkpoint_path.join("aneforge_state.bin")
    }
}

impl Default for ProcessManager {
    fn default() -> Self {
        Self::new()
    }
}
