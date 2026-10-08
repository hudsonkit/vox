fn main() -> std::io::Result<()> {
    vox_provider::serve(vox_provider_example::EchoProvider::default())
}
