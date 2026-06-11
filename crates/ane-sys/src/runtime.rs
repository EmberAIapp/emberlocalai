use std::ffi::c_void;
use thiserror::Error;

#[derive(Error, Debug)]
pub enum ANEError {
    #[error("ANE framework not available")]
    FrameworkNotFound,
    #[error("ANE initialization failed (code: {0})")]
    InitFailed(i32),
    #[error("Compilation failed (code: {0})")]
    CompileFailed(i32),
    #[error("Evaluation failed (code: {0})")]
    EvalFailed(i32),
    #[error("Surface I/O error (code: {0})")]
    SurfaceError(i32),
    #[error("Compilation limit reached ({0}/119)")]
    CompileLimitReached(i32),
}

/// Raw FFI handle from ObjC bridge
#[repr(C)]
pub struct ANEKernelHandleRaw {
    pub model: *mut c_void,
    pub request: *mut c_void,
    pub client: *mut c_void,
    pub input_surface: *mut c_void,
    pub output_surface: *mut c_void,
    pub input_numel: i32,
    pub output_numel: i32,
}

// FFI declarations for the ObjC bridge
unsafe extern "C" {
    fn ane_init() -> i32;
    fn ane_compile(
        handle: *mut ANEKernelHandleRaw,
        mil_text: *const u8,
        weights: *const u8,
        weight_bytes: i32,
        input_numel: i32,
        output_numel: i32,
        element_size: i32,
    ) -> i32;
    fn ane_eval(handle: *mut ANEKernelHandleRaw) -> i32;
    fn ane_kernel_destroy(handle: *mut ANEKernelHandleRaw);
    fn ane_get_compilation_count() -> i32;
    fn ane_reset_compilation_count();
    fn ane_shutdown();
}

/// Safe wrapper around ANE kernel handle with RAII cleanup
pub struct ANEKernelHandle {
    raw: ANEKernelHandleRaw,
}

impl ANEKernelHandle {
    /// Write data to input surface
    pub fn write_input(&self, data: &[f32]) -> Result<(), ANEError> {
        let bytes = unsafe {
            std::slice::from_raw_parts(data.as_ptr() as *const u8, data.len() * 4)
        };
        let ret = unsafe {
            ane_surface_write(self.raw.input_surface, bytes.as_ptr(), bytes.len() as i32)
        };
        if ret != 0 { Err(ANEError::SurfaceError(ret)) } else { Ok(()) }
    }

    /// Read data from output surface
    pub fn read_output(&self, data: &mut [f32]) -> Result<(), ANEError> {
        let ret = unsafe {
            ane_surface_read(
                self.raw.output_surface,
                data.as_mut_ptr() as *mut u8,
                (data.len() * 4) as i32,
            )
        };
        if ret != 0 { Err(ANEError::SurfaceError(ret)) } else { Ok(()) }
    }

    /// Execute the kernel on ANE
    pub fn eval(&mut self) -> Result<(), ANEError> {
        let ret = unsafe { ane_eval(&mut self.raw) };
        if ret != 0 { Err(ANEError::EvalFailed(ret)) } else { Ok(()) }
    }
}

impl Drop for ANEKernelHandle {
    fn drop(&mut self) {
        unsafe { ane_kernel_destroy(&mut self.raw) };
    }
}

// FFI for surface operations
unsafe extern "C" {
    fn ane_surface_write(surface: *mut c_void, data: *const u8, nbytes: i32) -> i32;
    fn ane_surface_read(surface: *mut c_void, data: *mut u8, nbytes: i32) -> i32;
}

/// Main ANE runtime - singleton managing the ANE connection
pub struct ANERuntime {
    initialized: bool,
}

impl ANERuntime {
    /// Initialize the ANE runtime. Call once at startup.
    pub fn new() -> Result<Self, ANEError> {
        let ret = unsafe { ane_init() };
        if ret != 0 {
            return Err(ANEError::InitFailed(ret));
        }
        Ok(Self { initialized: true })
    }

    /// Compile a MIL program into an ANE kernel
    pub fn compile(
        &self,
        mil_text: &str,
        weights: Option<&[u8]>,
        input_numel: usize,
        output_numel: usize,
    ) -> Result<ANEKernelHandle, ANEError> {
        // Check compilation limit
        let count = unsafe { ane_get_compilation_count() };
        if count >= 110 {
            return Err(ANEError::CompileLimitReached(count));
        }

        let mut raw = ANEKernelHandleRaw {
            model: std::ptr::null_mut(),
            request: std::ptr::null_mut(),
            client: std::ptr::null_mut(),
            input_surface: std::ptr::null_mut(),
            output_surface: std::ptr::null_mut(),
            input_numel: input_numel as i32,
            output_numel: output_numel as i32,
        };

        let mil_cstr = std::ffi::CString::new(mil_text)
            .map_err(|_| ANEError::CompileFailed(-99))?;

        let (weight_ptr, weight_len) = match weights {
            Some(w) => (w.as_ptr(), w.len() as i32),
            None => (std::ptr::null(), 0),
        };

        let ret = unsafe {
            ane_compile(
                &mut raw,
                mil_cstr.as_ptr() as *const u8,
                weight_ptr,
                weight_len,
                input_numel as i32,
                output_numel as i32,
                4, // sizeof(float)
            )
        };

        if ret != 0 {
            return Err(ANEError::CompileFailed(ret));
        }

        Ok(ANEKernelHandle { raw })
    }

    /// Get current compilation count
    pub fn compilation_count(&self) -> i32 {
        unsafe { ane_get_compilation_count() }
    }

    /// Reset compilation count (after process restart)
    pub fn reset_compilation_count(&self) {
        unsafe { ane_reset_compilation_count() }
    }
}

impl Drop for ANERuntime {
    fn drop(&mut self) {
        if self.initialized {
            unsafe { ane_shutdown() };
        }
    }
}

unsafe impl Send for ANEKernelHandle {}
unsafe impl Send for ANERuntime {}
