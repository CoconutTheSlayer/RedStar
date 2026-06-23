//! `PoseidonArchive` — first real C++ -> Rust module: PBO archive reading.
//!
//! A thin C-ABI wrapper over the standalone, safe [`papa_bear_archive`] crate,
//! which already implements byte-compatible OFP/Poseidon PBO parsing and LZSS
//! decompression. No parsing logic lives here — this crate only marshals across
//! the boundary, following the conventions proven by the `PoseidonRust` spike:
//!
//!   * No panic crosses `extern "C"` — fallible entry points use [`catch_unwind`]
//!     and report failure with a benign sentinel (null / -1).
//!   * Allocations are owned by their creator: the handle from `pa_pbo_open*` is
//!     freed only by `pa_pbo_close`; extracted bytes are copied into a
//!     caller-owned buffer.
//!   * `unsafe` is confined to the boundary functions.
//!
//! Errors carry a message retrievable on the calling thread via [`pa_last_error`]
//! (errno-string style), valid until the next failing call on that thread.

use std::cell::RefCell;
use std::ffi::{c_char, c_int, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;
use std::slice;

use papa_bear_archive::Pbo;

thread_local! {
    static LAST_ERROR: RefCell<CString> = RefCell::new(CString::default());
}

fn set_last_error(msg: &str) {
    LAST_ERROR.with(|e| *e.borrow_mut() = CString::new(msg).unwrap_or_default());
}

/// Opaque handle to a parsed PBO. Owns the archive plus a cache of NUL-terminated
/// entry names, so [`pa_pbo_entry_name`] can return pointers that stay valid
/// until [`pa_pbo_close`].
pub struct PaPbo {
    pbo: Pbo,
    names: Vec<CString>,
}

impl PaPbo {
    fn new(pbo: Pbo) -> Self {
        let names = pbo
            .entries
            .iter()
            .map(|e| CString::new(e.name.as_str()).unwrap_or_default())
            .collect();
        Self { pbo, names }
    }
}

/// SAFETY: callers pass a handle previously returned by `pa_pbo_open*`.
unsafe fn handle<'a>(pbo: *const PaPbo) -> Option<&'a PaPbo> {
    // SAFETY: non-null pointers are valid handles per the C contract.
    (!pbo.is_null()).then(|| unsafe { &*pbo })
}

/// Opens and parses a PBO from a filesystem path. Returns null on error; call
/// [`pa_last_error`] for the reason.
///
/// # Safety
/// `path` must be null or a valid NUL-terminated string for the duration of the
/// call.
#[no_mangle]
pub unsafe extern "C" fn pa_pbo_open(path: *const c_char) -> *mut PaPbo {
    catch_unwind(|| {
        if path.is_null() {
            set_last_error("pa_pbo_open: null path");
            return ptr::null_mut();
        }
        // SAFETY: non-null checked; caller guarantees a valid C string.
        let Ok(path) = (unsafe { CStr::from_ptr(path) }).to_str() else {
            set_last_error("pa_pbo_open: path is not valid UTF-8");
            return ptr::null_mut();
        };
        match Pbo::read_path(path) {
            Ok(pbo) => Box::into_raw(Box::new(PaPbo::new(pbo))),
            Err(e) => {
                set_last_error(&format!("{e:#}"));
                ptr::null_mut()
            }
        }
    })
    .unwrap_or_else(|_| {
        set_last_error("pa_pbo_open: panicked");
        ptr::null_mut()
    })
}

/// Opens and parses a PBO from an in-memory buffer. Returns null on error.
///
/// # Safety
/// `data` must point to `len` readable bytes, or be null when `len` is 0.
#[no_mangle]
pub unsafe extern "C" fn pa_pbo_open_bytes(data: *const u8, len: c_int) -> *mut PaPbo {
    catch_unwind(AssertUnwindSafe(|| {
        let Ok(len) = usize::try_from(len) else {
            set_last_error("pa_pbo_open_bytes: negative len");
            return ptr::null_mut();
        };
        if data.is_null() && len != 0 {
            set_last_error("pa_pbo_open_bytes: null data with non-zero len");
            return ptr::null_mut();
        }
        // SAFETY: validated above; empty buffer uses a dangling-but-valid slice.
        let buf = if len == 0 {
            &[][..]
        } else {
            unsafe { slice::from_raw_parts(data, len) }
        };
        match Pbo::read_bytes(buf) {
            Ok(pbo) => Box::into_raw(Box::new(PaPbo::new(pbo))),
            Err(e) => {
                set_last_error(&format!("{e:#}"));
                ptr::null_mut()
            }
        }
    }))
    .unwrap_or_else(|_| {
        set_last_error("pa_pbo_open_bytes: panicked");
        ptr::null_mut()
    })
}

/// Frees a handle returned by `pa_pbo_open*`. Null is a no-op.
///
/// # Safety
/// `pbo` must be null, or a handle from `pa_pbo_open*` that has not been freed.
#[no_mangle]
pub unsafe extern "C" fn pa_pbo_close(pbo: *mut PaPbo) {
    if !pbo.is_null() {
        // SAFETY: reclaims the Box created in `pa_pbo_open*`, per the contract.
        drop(unsafe { Box::from_raw(pbo) });
    }
}

/// Number of file entries in the archive, or -1 if the handle is null.
///
/// # Safety
/// `pbo` must be null or a valid handle.
#[no_mangle]
pub unsafe extern "C" fn pa_pbo_entry_count(pbo: *const PaPbo) -> c_int {
    // SAFETY: handle() validates non-null.
    unsafe { handle(pbo) }.map_or(-1, |h| {
        c_int::try_from(h.pbo.entries.len()).unwrap_or(c_int::MAX)
    })
}

/// Logical name of entry `idx` (forward-slash separated), owned by the handle and
/// valid until [`pa_pbo_close`]. Returns null if the handle is null or `idx` is
/// out of range.
///
/// # Safety
/// `pbo` must be null or a valid handle.
#[no_mangle]
pub unsafe extern "C" fn pa_pbo_entry_name(pbo: *const PaPbo, idx: c_int) -> *const c_char {
    // SAFETY: handle() validates non-null.
    match unsafe { handle(pbo) } {
        Some(h) => usize::try_from(idx)
            .ok()
            .and_then(|i| h.names.get(i))
            .map_or(ptr::null(), |n| n.as_ptr()),
        None => ptr::null(),
    }
}

/// Logical (decompressed) size in bytes of entry `idx`, or -1 on a null handle or
/// out-of-range index.
///
/// # Safety
/// `pbo` must be null or a valid handle.
#[no_mangle]
pub unsafe extern "C" fn pa_pbo_entry_size(pbo: *const PaPbo, idx: c_int) -> c_int {
    // SAFETY: handle() validates non-null.
    match unsafe { handle(pbo) } {
        Some(h) => usize::try_from(idx)
            .ok()
            .and_then(|i| h.pbo.entries.get(i))
            .map_or(-1, |e| c_int::try_from(e.unpacked_size()).unwrap_or(c_int::MAX)),
        None => -1,
    }
}

/// Extracts entry `idx`, decompressing if needed.
///
/// Returns the entry's decompressed size in bytes. If `buffer` is null, the size
/// is returned without copying (size query). Otherwise, when `buffer_size` is at
/// least the entry size, the bytes are copied into `buffer` and the size is
/// returned. Returns -1 on error (null handle, bad index, decode failure, or a
/// non-null buffer that is too small); see [`pa_last_error`].
///
/// # Safety
/// `pbo` must be null or a valid handle. If non-null, `buffer` must point to at
/// least `buffer_size` writable bytes.
#[no_mangle]
pub unsafe extern "C" fn pa_pbo_extract(
    pbo: *const PaPbo,
    idx: c_int,
    buffer: *mut u8,
    buffer_size: c_int,
) -> c_int {
    catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: handle() validates non-null.
        let Some(h) = (unsafe { handle(pbo) }) else {
            set_last_error("pa_pbo_extract: null handle");
            return -1;
        };
        let Ok(idx) = usize::try_from(idx) else {
            set_last_error("pa_pbo_extract: negative index");
            return -1;
        };
        let Some(entry) = h.pbo.entries.get(idx) else {
            set_last_error("pa_pbo_extract: index out of range");
            return -1;
        };
        let data = match h.pbo.entry_data(entry) {
            Ok(d) => d,
            Err(e) => {
                set_last_error(&format!("{e:#}"));
                return -1;
            }
        };
        let Ok(size) = c_int::try_from(data.len()) else {
            set_last_error("pa_pbo_extract: entry too large for int");
            return -1;
        };
        if buffer.is_null() {
            return size; // size query
        }
        if buffer_size < size {
            set_last_error("pa_pbo_extract: buffer too small");
            return -1;
        }
        // SAFETY: buffer holds >= size writable bytes per the contract.
        unsafe { ptr::copy_nonoverlapping(data.as_ptr(), buffer, data.len()) };
        size
    }))
    .unwrap_or_else(|_| {
        set_last_error("pa_pbo_extract: panicked");
        -1
    })
}

/// Last error message on the calling thread (empty string if none). Owned by the
/// library; valid until the next failing call on this thread. Never null.
#[no_mangle]
pub extern "C" fn pa_last_error() -> *const c_char {
    LAST_ERROR.with(|e| e.borrow().as_ptr())
}

#[cfg(test)]
mod tests {
    // Test-only int casts between usize and c_int on known-small fixtures.
    #![allow(
        clippy::cast_possible_truncation,
        clippy::cast_possible_wrap,
        clippy::cast_sign_loss
    )]

    use super::*;

    // Build a tiny store-only PBO in memory and round-trip it through the C ABI.
    fn fixture() -> Vec<u8> {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("hello.txt"), b"hello pbo").unwrap();
        let pbo = Pbo::pack_dir(dir.path(), Some("test\\addon")).unwrap();
        let mut bytes = Vec::new();
        pbo.write(&mut bytes).unwrap();
        bytes
    }

    #[test]
    fn open_count_and_extract() {
        let bytes = fixture();
        // SAFETY: valid buffer/len.
        let h = unsafe { pa_pbo_open_bytes(bytes.as_ptr(), bytes.len() as c_int) };
        assert!(!h.is_null());
        // SAFETY: valid handle for the rest of the block.
        unsafe {
            assert_eq!(pa_pbo_entry_count(h), 1);
            let name = CStr::from_ptr(pa_pbo_entry_name(h, 0)).to_str().unwrap();
            assert_eq!(name, "hello.txt");
            let size = pa_pbo_entry_size(h, 0);
            assert_eq!(size, "hello pbo".len() as c_int);
            assert_eq!(pa_pbo_extract(h, 0, ptr::null_mut(), 0), size); // query
            let mut buf = vec![0u8; size as usize];
            assert_eq!(pa_pbo_extract(h, 0, buf.as_mut_ptr(), size), size);
            assert_eq!(&buf, b"hello pbo");
            pa_pbo_close(h);
        }
    }

    #[test]
    fn bad_inputs_are_sentinels() {
        // SAFETY: explicit null / bad-arg handling.
        unsafe {
            assert!(pa_pbo_open(ptr::null()).is_null());
            assert_eq!(pa_pbo_entry_count(ptr::null()), -1);
            assert_eq!(pa_pbo_entry_size(ptr::null(), 0), -1);
            assert!(pa_pbo_entry_name(ptr::null(), 0).is_null());
            assert_eq!(pa_pbo_extract(ptr::null(), 0, ptr::null_mut(), 0), -1);
            assert!(!pa_last_error().is_null());
            pa_pbo_close(ptr::null_mut()); // no-op
        }
    }
}
