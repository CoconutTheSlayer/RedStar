//! Generates `include/poseidon_rust.h` from the crate source via cbindgen, so
//! the C header can never drift from the Rust signatures in `src/lib.rs`.
//!
//! The header is written back into the (committed) `include/` directory rather
//! than `OUT_DIR` so it is present for IDEs and standalone consumers without a
//! build, and so CI can flag drift with `git diff --exit-code`. cbindgen only
//! rewrites the file when its contents actually change, so unchanged builds
//! don't churn timestamps or trigger needless recompiles.

use std::env;
use std::path::PathBuf;

fn main() {
    let crate_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());

    // Only regenerate when the inputs that shape the header change.
    println!("cargo:rerun-if-changed=src/lib.rs");
    println!("cargo:rerun-if-changed=cbindgen.toml");
    println!("cargo:rerun-if-changed=build.rs");

    let config = cbindgen::Config::from_file(crate_dir.join("cbindgen.toml"))
        .expect("read cbindgen.toml");

    let header = crate_dir.join("include").join("poseidon_rust.h");
    cbindgen::Builder::new()
        .with_crate(&crate_dir)
        .with_config(config)
        .generate()
        .expect("generate poseidon_rust.h")
        .write_to_file(&header);
}
