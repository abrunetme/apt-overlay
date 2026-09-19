# apt-overlay

A lightweight APT repository generator for Debian/Ubuntu that wraps standalone binaries or `.tar.gz` releases from GitHub into native `.deb` packages using a simple configuration file per application.

Everything is packaged in the cloud or on a machine of your choice and served seamlessly as a standard APT repository—eliminating the need for Homebrew, Snaps, Flatpaks, or messy manual `curl | bash` install scripts.

## Features

- **Declarative Configuration:** One clean `.conf` file per package dictates the metadata and source.
- **Pure APT Integration:** Applications are managed natively via `apt install` and `apt upgrade`.
- **Smart Archive Handling:** Automatically detects and extracts `.tar.gz` releases or handles raw standalone binaries.
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
- `ASSET_NAME`: The exact filename of the release asset on GitHub (supports both `.tar.gz` archives and raw binaries).
- `DESCRIPTION`: A brief description embedded directly into the Debian package metadata.
- `PKG_NAME` *(Optional)*: Overrides the package name (defaults to the filename without `.conf`).
- `BINARY_NAME` *(Optional)*: Name of the executable to extract from a `.tar.gz` archive. Defaults to `PKG_NAME`; if not found, the largest executable file in the archive is used.
- `GPG_KEY_ID` *(Optional, environment variable)*: Overrides the GPG key used to sign the repository instead of the first key found in the keyring.

### Example: `packages/talosctl.conf`
```bash
REPO_PATH="siderolabs/talos"
ASSET_NAME="talosctl-linux-amd64"
DESCRIPTION="Talos Linux cluster management command-line utility."
```

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
