//! `PoseidonRust` — toolchain spike for the incremental C++ -> Rust migration.
//!
//! This crate exists only to prove the end-to-end build seam: a Rust
//! `staticlib` compiled by Cargo, imported into the `CMake` build via Corrosion,
//! and called across a C ABI from the C++ engine. It deliberately contains
//! nothing but trivial round-trip functions — the real modules (formats,
//! `ParamFile`, preprocessor) come later behind this same boundary.
//!
//! FFI ground rules established here, to be reused by every future module:
//!   * No panic may unwind across an `extern "C"` boundary — that is undefined
//!     behaviour. Every entry point wraps its body in [`catch_unwind`] and
//!     converts a panic into a benign error value (null / sentinel).
//!   * Every pointer handed to C++ is *owned* by Rust and freed by Rust
//!     (`prs_string_free`). C++ never frees a Rust allocation, and vice versa.
//!   * `unsafe` lives only in the thin boundary functions; everything they call
//!     is safe Rust.

use std::ffi::{c_char, c_int, CStr, CString};
use std::panic::catch_unwind;
use std::ptr;

/// ABI handshake value. C++ asserts the linked crate matches its header
/// (`PRS_ABI_VERSION` in `poseidon_rust.h`). Bump on any breaking ABI change.
pub const PRS_ABI_VERSION: c_int = 1;

/// Returns [`PRS_ABI_VERSION`] as compiled into this crate.
#[no_mangle]
pub extern "C" fn prs_abi_version() -> c_int {
    PRS_ABI_VERSION
}

/// Trivial numeric round-trip: proves arguments and return values cross the
/// boundary correctly. Wrapping add so it can never panic on overflow.
#[no_mangle]
pub extern "C" fn prs_add(a: c_int, b: c_int) -> c_int {
    a.wrapping_add(b)
}

/// String round-trip demonstrating cross-language allocation ownership.
///
/// Borrows a NUL-terminated UTF-8 string from C++ and returns a freshly
/// allocated NUL-terminated string owned by Rust. The caller **must** return it
/// to [`prs_string_free`]. Returns null on a null pointer, non-UTF-8 input, an
/// embedded NUL, or a panic.
///
/// # Safety
/// `name` must be null or point to a valid NUL-terminated C string that stays
/// alive for the duration of the call.
#[no_mangle]
pub unsafe extern "C" fn prs_greet(name: *const c_char) -> *mut c_char {
    catch_unwind(|| {
        if name.is_null() {
            return ptr::null_mut();
        }
        // SAFETY: non-null checked above; lifetime guaranteed by the caller per
        // the safety contract.
        let Ok(name) = unsafe { CStr::from_ptr(name) }.to_str() else {
            return ptr::null_mut();
        };
        match CString::new(format!("Hello from Rust, {name}!")) {
            Ok(s) => s.into_raw(),
            Err(_) => ptr::null_mut(),
        }
    })
    .unwrap_or(ptr::null_mut())
}

/// Frees a string previously returned by [`prs_greet`]. Null is a no-op.
///
/// # Safety
/// `s` must be null, or a pointer returned by [`prs_greet`] that has not already
/// been freed.
#[no_mangle]
pub unsafe extern "C" fn prs_string_free(s: *mut c_char) {
    if !s.is_null() {
        // SAFETY: reconstitutes the CString this crate created in `prs_greet`,
        // per the safety contract; dropping it frees the same allocation.
        drop(unsafe { CString::from_raw(s) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn add_wraps() {
        assert_eq!(prs_add(2, 3), 5);
        assert_eq!(prs_add(i32::MAX, 1), i32::MIN);
    }

    #[test]
    fn greet_round_trips() {
        let name = CString::new("world").unwrap();
        // SAFETY: `name` is a valid NUL-terminated string alive for the call.
        unsafe {
            let p = prs_greet(name.as_ptr());
            assert!(!p.is_null());
            assert_eq!(CStr::from_ptr(p).to_str().unwrap(), "Hello from Rust, world!");
            prs_string_free(p);
        }
    }

    #[test]
    fn greet_null_is_null() {
        // SAFETY: null is explicitly handled.
        unsafe {
            assert!(prs_greet(ptr::null()).is_null());
            prs_string_free(ptr::null_mut()); // no-op, must not crash
        }
    }
}
