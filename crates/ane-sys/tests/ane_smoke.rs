//! Empirical smoke test: does the private-API ANE path actually work on this machine?
//! Run with: cargo test -p ane-sys --test ane_smoke -- --nocapture

use ane_sys::runtime::ANERuntime;
use ane_sys::compiler::ANECompiler;

#[test]
fn ane_init_and_matmul() {
    println!("=== Step 1: ane_init (load private framework, create _ANEClient) ===");
    let runtime = match ANERuntime::new() {
        Ok(r) => {
            println!("OK: ANE runtime initialized");
            r
        }
        Err(e) => {
            println!("FAILED at init: {e:?}");
            panic!("init failed");
        }
    };

    println!("=== Step 2: compile a tiny linear kernel (4x4 identity, seq=2) ===");
    let mut weights = vec![0.0f32; 16];
    for i in 0..4 {
        weights[i * 4 + i] = 1.0; // identity
    }
    let compiler = ANECompiler::new(&runtime);
    let mut kernel = match compiler.compile_linear(&weights, 4, 4, 2) {
        Ok(k) => {
            println!("OK: kernel compiled (count={})", runtime.compilation_count());
            k
        }
        Err(e) => {
            println!("FAILED at compile: {e:?}");
            panic!("compile failed");
        }
    };

    println!("=== Step 3: write input, eval on ANE, read output ===");
    let input: Vec<f32> = (0..8).map(|i| i as f32).collect();
    kernel.write_input(&input).expect("write_input failed");
    match kernel.eval() {
        Ok(_) => println!("OK: eval succeeded"),
        Err(e) => {
            println!("FAILED at eval: {e:?}");
            panic!("eval failed");
        }
    }
    let mut output = vec![0.0f32; 8];
    kernel.read_output(&mut output).expect("read_output failed");
    println!("input:  {input:?}");
    println!("output: {output:?}");
    println!("(identity weights => output should equal input)");
}
