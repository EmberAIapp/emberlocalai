fn main() {
    // Link Apple's Accelerate framework for BLAS (cblas_sgemm) — turns the
    // naive triple-loop matmul into hardware-tuned SIMD/AMX, 10-50x faster.
    println!("cargo:rustc-link-lib=framework=Accelerate");
}
