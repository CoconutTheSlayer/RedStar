//! Generates `include/poseidon_archive.h` from the crate source via cbindgen so
//! the C header can never drift from the Rust signatures. Mirrors `PoseidonRust`'s
//! build script; see that crate's build.rs for the rationale (committed header,
//! rewrite-only-on-change).

use std::env;
use std::path::PathBuf;

fn main() {
    let crate_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());

    println!("cargo:rerun-if-changed=src/lib.rs");
    println!("cargo:rerun-if-changed=cbindgen.toml");
    println!("cargo:rerun-if-changed=build.rs");

    let config = cbindgen::Config::from_file(crate_dir.join("cbindgen.toml"))
        .expect("read cbindgen.toml");

    let header = crate_dir.join("include").join("poseidon_archive.h");
    cbindgen::Builder::new()
        .with_crate(&crate_dir)
        .with_config(config)
        .generate()
        .expect("generate poseidon_archive.h")
        .write_to_file(&header);
}
