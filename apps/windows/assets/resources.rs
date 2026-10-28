// Shared by the build scripts of the three programs (`include!`d): embeds Caboose's icon and
// the application manifest (assets/app.manifest) into a Windows executable.

/// Compiles the icon and manifest into the executable when building for Windows. With MSVC
/// (release builds) the resource compiler must be present; elsewhere, such as `cargo check`
/// for windows-gnu on another OS without windres, the resources are left out.
fn embed_resources() {
    let assets = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../assets");
    println!("cargo:rerun-if-changed={}", assets.join("caboose.ico").display());
    println!("cargo:rerun-if-changed={}", assets.join("app.manifest").display());
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") {
        return;
    }
    let assets = assets.canonicalize().expect("apps/windows/assets");
    // rc.exe does not take `\\?\` paths, which canonicalize gives on Windows.
    let quote = |path: std::path::PathBuf| path.display().to_string().trim_start_matches(r"\\?\").replace('\\', "\\\\");
    let out = std::path::PathBuf::from(std::env::var("OUT_DIR").expect("OUT_DIR"));
    let script = out.join("caboose.rc");
    std::fs::write(
        &script,
        format!("1 ICON \"{}\"\n1 24 \"{}\"\n", quote(assets.join("caboose.ico")), quote(assets.join("app.manifest"))),
    )
    .expect("write caboose.rc");
    let result = embed_resource::compile(&script, embed_resource::NONE);
    if std::env::var("CARGO_CFG_TARGET_ENV").as_deref() == Ok("msvc") {
        result.manifest_required().expect("embed the icon and manifest");
    } else if let Err(error) = result.manifest_optional() {
        panic!("embedding the icon and manifest failed: {error}");
    }
}
