use std::env;

fn main() {
    let _out_dir = env::var("OUT_DIR").unwrap();

    // Compile the ObjC bridge
    cc::Build::new()
        .file("objc/ane_bridge.m")
        .flag("-fobjc-arc")
        .flag("-fmodules")
        .flag("-ObjC")
        .flag("-O2")
        .include("objc")
        .compile("ane_bridge");

    // Link required frameworks
    println!("cargo:rustc-link-lib=framework=Foundation");
    println!("cargo:rustc-link-lib=framework=IOSurface");
    println!("cargo:rustc-link-lib=framework=CoreML");
    println!("cargo:rustc-link-lib=framework=Accelerate");
    println!("cargo:rustc-link-lib=dylib=objc");

    // Rerun if bridge changes
    println!("cargo:rerun-if-changed=objc/ane_bridge.m");
}
