# Guest package repository tooling

`repository.py` assembles an APT repository from existing `.deb` files. It requires
Python 3.9+ and `dpkg-deb` on PATH. It does not build guest packages, upload files,
configure a computer's APT sources, or generate signing keys. Caboose images and
host component upgrades continue to use the component installer.

From this directory:

```sh
python3 repository.py /path/to/packages/*.deb --output /path/to/new-repository \
  --timestamp 1700000000
```

The output directory must not exist. Assembly happens in a temporary sibling and
is renamed into place after success. Package metadata is read from private copies;
duplicate package/version/architecture records and unselected architectures fail.
Architecture-independent packages appear in both indexes. The default suite is
`trixie`, component `main`, architectures `amd64 arm64`.

The repository contains content-addressed packages, `Packages` and `Packages.gz`,
SHA-256/SHA-512 by-hash indexes, and `Release` with MD5, SHA-256 and SHA-512 checksums.
Supply the release's Unix timestamp through `--timestamp` or `SOURCE_DATE_EPOCH`.
The timestamp controls the Release date and gzip headers are fixed for reproducible
indexes. Retain old by-hash files when updating a hosted mirror; replacing a mirror
with only one new output tree can break clients still using its previous Release.

Unsigned output is for inspection. To create `InRelease` and `Release.gpg`, pass
`--signing-key` with an existing GPG key fingerprint; GPG must already have access
to that key through the operator's configured agent. The tool never chooses a
default key. Signing failure leaves no output repository. Signature timestamps
come from GPG. A repository consumer needs the corresponding public key in an
explicit `Signed-By` keyring; no trust configuration is installed by this tool.

Run the small local checks without Docker, network access or root:

```sh
python3 -m unittest discover -s guest/packages -v
```

Run that command from the repository root. The real `.deb` round trip runs only
where `dpkg-deb` is installed; other checks cover index hashes, by-hash contents,
architecture selection, deterministic output and failure cleanup. Repository
download with a real APT client and signature verification are checked on Linux:

```sh
bash guest/packages/check-repository.sh
```

It needs `dpkg-deb`, APT and GnuPG. It builds a tiny acceptance fixture, makes a
throwaway signing key in a temporary directory, verifies both signatures,
downloads the fixture through isolated APT state and checks that APT rejects a
tampered signature. It never installs the fixture or modifies system APT state.
The hosted `Check guest package repository` workflow runs both checks.
