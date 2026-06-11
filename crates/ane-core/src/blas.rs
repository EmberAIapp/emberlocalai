//! Shared BLAS helpers backed by Apple's Accelerate framework (linked in build.rs).
//! Replaces naive triple-loop matmuls with hardware-tuned SIMD/AMX kernels.

#[allow(non_camel_case_types)]
type CblasOrder = u32;
#[allow(non_camel_case_types)]
type CblasTranspose = u32;
const ROW_MAJOR: CblasOrder = 101;
const NO_TRANS: CblasTranspose = 111;
const TRANS: CblasTranspose = 112;

unsafe extern "C" {
    #[allow(clippy::too_many_arguments)]
    fn cblas_sgemm(
        order: CblasOrder,
        transa: CblasTranspose,
        transb: CblasTranspose,
        m: i32, n: i32, k: i32,
        alpha: f32,
        a: *const f32, lda: i32,
        b: *const f32, ldb: i32,
        beta: f32,
        c: *mut f32, ldc: i32,
    );
}

/// Y[m,n] = X[m,k] @ W[n,k]^T  — the "linear layer" form (weights stored [out,in]).
pub fn matmul_nt(y: &mut [f32], x: &[f32], w: &[f32], m: usize, k: usize, n: usize) {
    unsafe {
        cblas_sgemm(
            ROW_MAJOR, NO_TRANS, TRANS,
            m as i32, n as i32, k as i32,
            1.0,
            x.as_ptr(), k as i32,
            w.as_ptr(), k as i32,
            0.0,
            y.as_mut_ptr(), n as i32,
        );
    }
}

/// Y[m,n] = X[m,k] @ W[k,n]  — plain row-major product (no transpose).
pub fn matmul_nn(y: &mut [f32], x: &[f32], w: &[f32], m: usize, k: usize, n: usize) {
    unsafe {
        cblas_sgemm(
            ROW_MAJOR, NO_TRANS, NO_TRANS,
            m as i32, n as i32, k as i32,
            1.0,
            x.as_ptr(), k as i32,
            w.as_ptr(), n as i32,
            0.0,
            y.as_mut_ptr(), n as i32,
        );
    }
}
