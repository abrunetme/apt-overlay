# apt-overlay

A lightweight APT repository generator for Debian/Ubuntu that wraps standalone binaries or `.tar.gz` releases from GitHub into native `.deb` packages using a simple configuration file per application.

Everything is packaged in the cloud or on a machine of your choice and served seamlessly as a standard APT repository—eliminating the need for Homebrew, Snaps, Flatpaks, or messy manual `curl | bash` install scripts.

## Features

- **Declarative Configuration:** One clean `.conf` file per package dictates the metadata and source.
- **Pure APT Integration:** Applications are managed natively via `apt install` and `apt upgrade`.
- **Smart Archive Handling:** Automatically detects and extracts `.tar.gz` releases or handles raw standalone binaries.
- **Content-Aware Skipping:** Packages are rebuilt only when their inputs change — a modified `build-repo.sh` or `.conf`, a new upstream version, or a corrupted artifact. Unchanged packages are never re-downloaded, keeping daily CI runs bandwidth-free.
- **Automatic Cleanup:** Removing a `.conf` file removes the corresponding `.deb` and cache from the repository on the next build.
- **Zero Local Footprint:** Designed to run seamlessly in GitHub Actions and serve packages statically via GitHub Pages.

---

## Directory Structure

```text
apt-overlay/
├── build-repo.sh       # The core package engine
├── index.html          # Homepage template (package list is injected at build time)
├── Release.key         # Public GPG signing key for APT clients
├── packages/           # Folder containing your package recipe configurations
│   └── sshm.conf       # Example configuration for SSHM
└── public/             # Fully generated at build time (gitignored)
    └── dist/           # Compiled .deb files and Packages index
```

---

## How to Add a New Package

To add an application to your repository, simply create a new configuration file under the `packages/` directory named `<package_name>.conf`. 

### Package Configuration Specification

Your `.conf` files support the following variables:
- `REPO_PATH`: The target GitHub repository (`Owner/Repository`).
- `ASSET_NAME`: The exact filename of the release asset on GitHub (supports both `.tar.gz` archives and raw binaries). The `VERSION` and `TAG` tokens are resolved automatically (e.g. `hugo_VERSION_linux-amd64.tar.gz` becomes `hugo_0.166.0_linux-amd64.tar.gz`).
- `DESCRIPTION`: A brief description embedded directly into the Debian package metadata.
- `PKG_NAME` *(Optional)*: Overrides the package name (defaults to the filename without `.conf`).
- `BINARY_NAME` *(Optional)*: Name of the executable to extract from a `.tar.gz` archive. Defaults to `PKG_NAME`; if not found, the largest executable file in the archive is used.
- `HOME_PAGE` *(Optional)*: Upstream project URL. Defaults to `https://github.com/REPO_PATH`. Embedded in the `.deb` metadata (`apt show <pkg>`) and shown as a link on the index page.
- `LATEST_URL` *(Optional)*: URL returning the latest version/tag, overriding the GitHub releases API. Enables non-GitHub sources such as `https://dl.k8s.io/release/stable.txt`.
- `LATEST_JSON_FIELD` *(Optional)*: Dotted path to read the version from a JSON response returned by `LATEST_URL` (e.g. `.tag_name` for a GitHub API payload).
- `DOWNLOAD_URL` *(Optional)*: Download URL template, overriding the default `https://github.com/REPO_PATH/releases/download/LATEST_TAG/ASSET_NAME`. Supports the same `VERSION` and `TAG` tokens — useful when the version is embedded in the URL path.

### Example: `packages/talosctl.conf`
```bash
REPO_PATH="siderolabs/talos"
ASSET_NAME="talosctl-linux-amd64"
DESCRIPTION="Talos Linux cluster management command-line utility."
```

### Example: `packages/hugo.conf`
```bash
REPO_PATH="gohugoio/hugo"
ASSET_NAME="hugo_VERSION_linux-amd64.tar.gz"
DESCRIPTION="Hugo is a static site generator written in Go."
```
The `VERSION` token is replaced automatically so versioned release assets never require a config update.

### Example: `packages/kubectl.conf`
```bash
REPO_PATH="kubernetes/kubernetes"
LATEST_URL="https://dl.k8s.io/release/stable.txt"
DOWNLOAD_URL="https://dl.k8s.io/release/TAG/bin/linux/amd64/kubectl"
ASSET_NAME="kubectl"
DESCRIPTION="Kubernetes command-line tool for running commands against Kubernetes clusters."
```
`LATEST_URL` feeds the version while `DOWNLOAD_URL` bypasses GitHub entirely — use `TAG` when the URL requires the leading `v` (e.g. `v1.37.0`).

### Example: `packages/helm.conf`
```bash
REPO_PATH="helm/helm"
LATEST_URL="https://api.github.com/repos/helm/helm/releases/latest"
LATEST_JSON_FIELD="tag_name"
DOWNLOAD_URL="https://get.helm.sh/helm-VERSION-linux-amd64.tar.gz"
ASSET_NAME="helm-VERSION-linux-amd64.tar.gz"
BINARY_NAME="helm"
DESCRIPTION="Helm is the package manager for Kubernetes."
```
Helm distributes its binaries on `get.helm.sh` (not as GitHub assets): `LATEST_JSON_FIELD` extracts the tag from the GitHub API response while `DOWNLOAD_URL` points at the actual archive host.

### Repository Signing

The repository is signed exactly once at the end of the build: the `dist/Release` index is signed with a single GPG key, producing `dist/InRelease` and `dist/Release.gpg`. Individual `.deb` packages are not signed — APT authenticates them through the checksums in the signed `Packages` index.

- `GPG_KEY_ID` *(optional, environment)*: Forces the key used to sign the repository. Required locally, where the shared `~/.gnupg` store often contains several secret keys and the first-match fallback may pick the wrong one.
- `GPG_PRIVATE_KEY` *(optional, environment)*: ASCII-armored private key to import into the keyring before signing (used in CI).

---

## Usage

### 1. Generating the Repository
Run the engine script locally or trigger it via your CI/CD pipeline to parse your configurations, download the latest GitHub releases, compile the `.deb` files, and index the repository:

```bash
chmod +x build-repo.sh
./build-repo.sh
```

### 2. Client-Side Setup (Using your Repository)
Once your `public/` directory is hosted online (e.g., via GitHub Pages at `https://apt.abrunet.me/`) or locally, add it to your system's APT sources:

```bash
curl -fsSL https://apt.abrunet.me/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/abrunet-overlay.gpg
echo "deb [signed-by=/etc/apt/keyrings/abrunet-overlay.gpg] https://apt.abrunet.me dist/" | sudo tee /etc/apt/sources.list.d/apt-overlay.list
```

### 3. Install and Maintain Packages
Update your system cache and install your packages exactly like any other native software:

```bash
# Update APT index
sudo apt update

# Install your custom packages
sudo apt install sshm talosctl

# Update them seamlessly along with your system updates
sudo apt upgrade
```

---

## License

This project is open-source and free to use. Keep your systems minimal, fast, and pure!
