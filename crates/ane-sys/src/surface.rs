use std::ffi::c_void;
use crate::runtime::ANEError;

// FFI declarations
unsafe extern "C" {
    fn ane_surface_create(num_elements: i32, element_size: i32) -> *mut c_void;
    fn ane_surface_write(surface: *mut c_void, data: *const u8, nbytes: i32) -> i32;
    fn ane_surface_read(surface: *mut c_void, data: *mut u8, nbytes: i32) -> i32;
    fn ane_surface_destroy(surface: *mut c_void);
}

/// Safe wrapper around IOSurface for tensor I/O with ANE
pub struct ANESurface {
    ptr: *mut c_void,
    num_elements: usize,
    _element_size: usize,
}

impl ANESurface {
    /// Create a new IOSurface for ANE tensor data
    pub fn new(num_elements: usize, element_size: usize) -> Result<Self, ANEError> {
        let ptr = unsafe { ane_surface_create(num_elements as i32, element_size as i32) };
        if ptr.is_null() {
            return Err(ANEError::SurfaceError(-1));
        }
        Ok(Self { ptr, num_elements, _element_size: element_size })
    }

    /// Write f32 data to the surface
    pub fn write_f32(&self, data: &[f32]) -> Result<(), ANEError> {
        assert!(data.len() <= self.num_elements);
        let nbytes = (data.len() * 4) as i32;
        let ret = unsafe {
            ane_surface_write(self.ptr, data.as_ptr() as *const u8, nbytes)
        };
        if ret != 0 { Err(ANEError::SurfaceError(ret)) } else { Ok(()) }
    }

    /// Read f32 data from the surface
    pub fn read_f32(&self, data: &mut [f32]) -> Result<(), ANEError> {
        assert!(data.len() <= self.num_elements);
        let nbytes = (data.len() * 4) as i32;
        let ret = unsafe {
            ane_surface_read(self.ptr, data.as_mut_ptr() as *mut u8, nbytes)
        };
        if ret != 0 { Err(ANEError::SurfaceError(ret)) } else { Ok(()) }
    }

    /// Raw pointer for FFI
    pub fn as_ptr(&self) -> *mut c_void {
        self.ptr
    }

    pub fn num_elements(&self) -> usize {
        self.num_elements
    }
}

impl Drop for ANESurface {
    fn drop(&mut self) {
        if !self.ptr.is_null() {
            unsafe { ane_surface_destroy(self.ptr) };
        }
    }
}

unsafe impl Send for ANESurface {}
