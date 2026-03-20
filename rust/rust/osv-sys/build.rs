use std::env;
use std::path::PathBuf;

fn main() {
    let osv_root = PathBuf::from(env::var("OSV_ROOT").unwrap_or_else(|_| {
        let manifest = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
        // rust/osv-sys -> project root
        manifest
            .parent()
            .and_then(|p| p.parent())
            .expect("cannot determine OSv root")
            .to_string_lossy()
            .into_owned()
    }));

    println!("cargo:rerun-if-changed=wrapper.h");
    println!("cargo:rerun-if-env-changed=OSV_ROOT");
    println!("cargo:rerun-if-env-changed=OSV_INCLUDE_PATHS");

    // Use generated headers from OSv build output directory
    let gen_include = osv_root.join("build/release.x64/gen/include");

    // Musl headers for bits/stdint.h and other arch-specific headers
    let musl_include = osv_root.join("musl_1.1.24/include");
    let musl_arch_include = osv_root.join("musl_1.1.24/arch/x86_64");

    let mut builder = bindgen::Builder::default()
        .header("wrapper.h")
        .use_core()
        .clang_arg(format!("-I{}", gen_include.display()))
        .clang_arg(format!("-I{}", osv_root.join("include").display()))
        .clang_arg(format!("-I{}", osv_root.join("include/api").display()))
        .clang_arg(format!("-I{}", musl_include.display()))
        .clang_arg(format!("-I{}", musl_arch_include.display()))
        .clang_arg(format!("-I{}", osv_root.join("bsd/sys").display()))
        .clang_arg(format!("-I{}", osv_root.join("bsd").display()))
        .clang_arg(format!("-I{}", osv_root.display()))
        .clang_arg("-DUSE_C_INTERFACE")
        .clang_arg("-D__BSD_VISIBLE=1");

    // Allow extra include paths from the build system
    if let Ok(paths) = env::var("OSV_INCLUDE_PATHS") {
        for path in paths.split(':') {
            if !path.is_empty() {
                builder = builder.clang_arg(format!("-I{path}"));
            }
        }
    }

    // Allowlist the types and functions we need
    let builder = builder
        // Types
        .allowlist_type("device")
        .allowlist_type("device_t")
        .allowlist_type("device_state_t")
        .allowlist_type("devops")
        .allowlist_type("driver")
        .allowlist_type("devinfo")
        .allowlist_type("uio")
        .allowlist_type("uio_rw")
        .allowlist_type("daddr_t")
        // Functions
        .allowlist_function("device_create")
        .allowlist_function("device_destroy")
        .allowlist_function("device_open")
        .allowlist_function("device_close")
        .allowlist_function("device_read")
        .allowlist_function("device_write")
        .allowlist_function("device_ioctl")
        .allowlist_function("read_partition_table")
        .allowlist_function("enodev")
        .allowlist_function("nullop")
        .allowlist_function("alloc_bio")
        .allowlist_function("destroy_bio")
        .allowlist_function("bio_wait")
        .allowlist_function("biodone")
        .allowlist_function("osv_bio_.*")
        // Constants
        .allowlist_var("MAXDEVNAME")
        .allowlist_var("D_CHR")
        .allowlist_var("D_BLK")
        .allowlist_var("D_REM")
        .allowlist_var("D_TTY")
        .allowlist_var("BIO_READ")
        .allowlist_var("BIO_WRITE")
        .allowlist_var("BIO_DELETE")
        .allowlist_var("BIO_FLUSH")
        .allowlist_var("BIO_ERROR")
        .allowlist_var("BIO_DONE")
        .allowlist_var("BIO_ONQUEUE")
        .allowlist_var("BIO_ORDERED")
        // Layout tests require std
        .layout_tests(false)
        // Generate for no_std
        .ctypes_prefix("core::ffi");

    let bindings = builder.generate().expect("failed to generate OSv bindings");

    let out_dir = PathBuf::from(env::var("OUT_DIR").unwrap());
    bindings
        .write_to_file(out_dir.join("bindings.rs"))
        .expect("failed to write bindings");
}
