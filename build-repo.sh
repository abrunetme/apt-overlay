#!/bin/bash
set -euo pipefail

# --- Path anchors: the script works regardless of the invocation directory ---
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${ROOT}/public/dist"
PUBLIC_DIR="${ROOT}/public"
BUILD_DIR="${ROOT}/build"

# Terminal colors
BLUE="\e[1;34m"
GREEN="\e[1;32m"
YELLOW="\e[1;33m"
RED="\e[1;31m"
NC="\e[0m"

mkdir -p "${REPO_DIR}"

# --- Assemble static assets into public/ ---
if [ -f "${ROOT}/Release.key" ]; then
    cp "${ROOT}/Release.key" "${PUBLIC_DIR}/Release.key"
else
    echo -e "${YELLOW}⚠ Release.key not found at the project root; skipping copy.${NC}"
fi

# --- Build summary counters ---
BUILT=0
SKIPPED=0
FAILED=0

# --- Cleanup temporary files on exit ---
cleanup() {
    rm -f /tmp/packages-fragment.html /tmp/index-head.html /tmp/index-tail.html /tmp/index.html.tmp
}
trap cleanup EXIT

# --- Fetch the latest release tag for a GitHub repository ---
# Prefer `gh api` (authenticated via GITHUB_TOKEN, preinstalled on GitHub runners),
# fall back to an anonymous curl call.
get_latest_tag() {
    local repo_path="$1"

    if command -v gh >/dev/null 2>&1; then
        gh api "repos/${repo_path}/releases/latest" --jq '.tag_name' 2>/dev/null && return 0 || true
    fi

    curl -fsSL --retry 3 -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${repo_path}/releases/latest" 2>/dev/null \
        | grep -o '"tag_name":[[:space:]]*"[^"]*"' \
        | head -n1 \
        | sed -E 's/.*"([^"]+)".*/\1/' || true
}

for pkg_file in "${ROOT}"/packages/*.conf; do
    # Continue if packages directory is empty
    [ -e "$pkg_file" ] || continue

    echo -e "${BLUE}Processing package: $(basename "$pkg_file")${NC}"

    # Reset previous package definition (all supported keys)
    unset REPO_PATH PKG_NAME DESCRIPTION ASSET_NAME BINARY_NAME

    # Load package definition
    source "$pkg_file"
    if [[ -z "${REPO_PATH:-}" ]]; then
        echo -e "${RED}✖ Error: Missing REPO_PATH${NC}"
        FAILED=$((FAILED + 1))
        continue
    fi
    if [[ -z "${ASSET_NAME:-}" ]]; then
        echo -e "${RED}✖ Error: Missing ASSET_NAME in $(basename "$pkg_file")${NC}"
        FAILED=$((FAILED + 1))
        continue
    fi

    # Validate package name (Debian package naming rules)
    PKG_NAME="${PKG_NAME:-$(basename "$pkg_file" .conf)}"
    if [[ ! "$PKG_NAME" =~ ^[a-z0-9][a-z0-9+.-]*$ ]]; then
        echo -e "${RED}✖ Error: Invalid package name '$PKG_NAME' (expected [a-z0-9][a-z0-9+.-]*)${NC}"
        FAILED=$((FAILED + 1))
        continue
    fi

    # Fetch and validate the latest release version
    LATEST_TAG="$(get_latest_tag "${REPO_PATH}")"
    if [[ -z "$LATEST_TAG" || "$LATEST_TAG" == "null" ]]; then
        echo -e "${RED}✖ Error: Failed to fetch latest release from ${REPO_PATH}${NC}"
        FAILED=$((FAILED + 1))
        continue
    fi
    VERSION="${LATEST_TAG#v}"
    if [[ ! "$VERSION" =~ ^[0-9][0-9a-zA-Z.+:~-]*$ ]]; then
        echo -e "${RED}✖ Error: Invalid Debian version '$VERSION' (must start with a digit)${NC}"
        FAILED=$((FAILED + 1))
        continue
    fi

    # Skip build if the package version already exists in the repository
    matches=( "${REPO_DIR}/${PKG_NAME}_${VERSION}"_*.deb )
    if (( ${#matches[@]} )) && [[ -e "${matches[0]}" ]]; then
        echo -e "${GREEN}✔ $PKG_NAME ($VERSION) is already up to date.${NC}"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Prepare Debian build directory structure
    PKG_BUILD_DIR="${BUILD_DIR}/${PKG_NAME}_${VERSION}_amd64"
    mkdir -p "${PKG_BUILD_DIR}/DEBIAN" "${PKG_BUILD_DIR}/usr/local/bin"

    cat << EOF > "${PKG_BUILD_DIR}/DEBIAN/control"
Package: ${PKG_NAME}
Version: ${VERSION}
Architecture: amd64
Maintainer: APT Overlay System
Description: ${DESCRIPTION:-}
EOF

    # Build download URL using LATEST_TAG to avoid GitHub 404 errors
    DOWNLOAD_URL="https://github.com/${REPO_PATH}/releases/download/${LATEST_TAG}/${ASSET_NAME}"

    # Handle asset types dynamically (.tar.gz extraction vs standalone binary)
    if [[ "$ASSET_NAME" == *.tar.gz ]]; then
        echo -e "${YELLOW}➔ Downloading and extracting .tar.gz archive...${NC}"
        EXTRACT_DIR="${BUILD_DIR}/extract_${PKG_NAME}"
        mkdir -p "${EXTRACT_DIR}"
        curl -fsSL --retry 3 "$DOWNLOAD_URL" -o "${EXTRACT_DIR}/archive.tar.gz"
        tar -xzf "${EXTRACT_DIR}/archive.tar.gz" -C "${EXTRACT_DIR}/"

        # Locate the target binary inside the archive:
        # 1. Explicit BINARY_NAME (or package name) at the archive root
        # 2. Same name anywhere in the tree
        # 3. The largest executable file found
        TARGET_NAME="${BINARY_NAME:-$PKG_NAME}"
        BINARY_SRC=""
        if [ -f "${EXTRACT_DIR}/${TARGET_NAME}" ]; then
            BINARY_SRC="${EXTRACT_DIR}/${TARGET_NAME}"
        elif [ -f "${EXTRACT_DIR}/${PKG_NAME}" ]; then
            BINARY_SRC="${EXTRACT_DIR}/${PKG_NAME}"
        else
            BINARY_SRC="$(find "${EXTRACT_DIR}" -type f -executable -printf '%s\t%p\n' 2>/dev/null | sort -nr | head -n1 | cut -f2- || true)"
        fi

        if [[ -z "$BINARY_SRC" || ! -f "$BINARY_SRC" ]]; then
            echo -e "${RED}✖ Error: No executable binary ('${TARGET_NAME}') found inside the archive${NC}"
            rm -rf "${EXTRACT_DIR}" "${PKG_BUILD_DIR}"
            FAILED=$((FAILED + 1))
            continue
        fi

        mv "$BINARY_SRC" "${PKG_BUILD_DIR}/usr/local/bin/${PKG_NAME}"
        rm -rf "${EXTRACT_DIR}"
    else
        # Fallback for standalone raw binaries (like talosctl)
        echo -e "${YELLOW}➔ Downloading standalone binary...${NC}"
        curl -fsSL --retry 3 "$DOWNLOAD_URL" -o "${PKG_BUILD_DIR}/usr/local/bin/${PKG_NAME}"
    fi

    # Guard: never package an empty or missing binary
    if [ ! -s "${PKG_BUILD_DIR}/usr/local/bin/${PKG_NAME}" ]; then
        echo -e "${RED}✖ Error: Binary '${PKG_NAME}' is empty or missing after download/extraction.${NC}"
        rm -rf "${PKG_BUILD_DIR}"
        FAILED=$((FAILED + 1))
        continue
    fi

    # Build the final .deb package using dpkg-deb
    chmod +x "${PKG_BUILD_DIR}/usr/local/bin/${PKG_NAME}"
    dpkg-deb --build "${PKG_BUILD_DIR}" "${REPO_DIR}/" > /dev/null
    echo -e "${GREEN}✔ Successfully created .deb package for $PKG_NAME ($VERSION).${NC}"

    # Keep only the latest version of this package in the repository
    for old_deb in "${REPO_DIR}/${PKG_NAME}"_*.deb; do
        [ -e "$old_deb" ] || continue
        old_ver="$(dpkg-deb --field "$old_deb" Version 2>/dev/null || true)"
        if [[ "$old_ver" != "$VERSION" ]]; then
            rm -f "$old_deb"
        fi
    done

    BUILT=$((BUILT + 1))

    # Cleanup build workspace for this package
    rm -rf "${PKG_BUILD_DIR}"
done

# --- GENERATE APT REPOSITORY INDICES ---
echo -e "\n${BLUE}➤ Indexing APT repository...${NC}"
(
    cd "${PUBLIC_DIR}"
    apt-ftparchive packages dist > dist/Packages
    gzip -9c dist/Packages > dist/Packages.gz
)
echo -e "${GREEN}✔ Done!${NC}"

# --- GENERATE HOMEPAGE PACKAGE LIST ---
echo -e "\n${BLUE}➤ Generating homepage package list...${NC}"
PACKAGES_FRAGMENT="/tmp/packages-fragment.html"

awk '
    /^Package: /     { pkg = $2; next }
    /^Version: /     { ver = $2; next }
    /^Filename: /    { file = $2; next }
    /^Description: / { desc = substr($0, index($0, $2)); next }
    /^$/             { emit(); next }
    { next }
    END { emit() }

    function emit() {
        if (pkg == "") return
        gsub(/&/, "\\&amp;", desc)
        gsub(/</, "\\&lt;", desc)
        gsub(/>/, "\\&gt;", desc)
        printf "      <li class=\"pkg\">\n"
        printf "        <span class=\"pkg-name\">%s</span>\n", pkg
        printf "        <a class=\"pkg-version\" href=\"./%s\">%s</a>\n", file, ver
        printf "        <span class=\"pkg-desc\">%s</span>\n", desc
        printf "      </li>\n"
        pkg = ""; ver = ""; file = ""; desc = ""
    }
' "${PUBLIC_DIR}/dist/Packages" > "${PACKAGES_FRAGMENT}"

# The template lives at the project root and is never modified.
# Materialize it into public/index.html, then inject the package list into that target only.
if [ ! -f "${ROOT}/index.html" ]; then
    echo -e "${YELLOW}⚠ No index.html template found at the project root; skipping homepage package list.${NC}"
else
    cp "${ROOT}/index.html" "${PUBLIC_DIR}/index.html"
    if grep -q '<!-- PACKAGES -->' "${PUBLIC_DIR}/index.html"; then
        awk '/<!-- PACKAGES -->/{exit} {print}' "${PUBLIC_DIR}/index.html" > /tmp/index-head.html
        awk 'f{print} /<!-- PACKAGES -->/{f=1}' "${PUBLIC_DIR}/index.html" > /tmp/index-tail.html
        cat /tmp/index-head.html "${PACKAGES_FRAGMENT}" /tmp/index-tail.html > "${PUBLIC_DIR}/index.html.tmp"
        mv "${PUBLIC_DIR}/index.html.tmp" "${PUBLIC_DIR}/index.html"
        echo -e "${GREEN}✔ Homepage package list updated.${NC}"
    else
        echo -e "${YELLOW}⚠ Marker <!-- PACKAGES --> not found in index.html; skipping.${NC}"
    fi
fi

# --- SIGN APT REPOSITORY ---
if [ -n "${GPG_PRIVATE_KEY:-}" ] || gpg --list-secret-keys &>/dev/null; then
    echo -e "\n${BLUE}➤ Signing APT repository...${NC}"

    # 1. Create a Release metadata file
    (
        cd "${PUBLIC_DIR}/dist"
        apt-ftparchive -o APT::FTPArchive::Release::Codename=dist release . > Release
    )

    # 2. Import the private key with robust handling of newlines
    if [ -n "${GPG_PRIVATE_KEY:-}" ]; then
        if ! echo "$GPG_PRIVATE_KEY" | gpg --batch --import &>/dev/null; then
            echo -e "${YELLOW}⚠ GPG private key import failed; continuing with the existing keyring.${NC}"
        fi
    fi

    # 3. Use the explicit GPG_KEY_ID if provided, otherwise the first available secret key
    KEY_ID=""
    if [ -n "${GPG_KEY_ID:-}" ]; then
        KEY_ID="${GPG_KEY_ID}"
    else
        KEY_ID="$(gpg --list-secret-keys --keyid-format LONG 2>/dev/null | grep -E '^sec' | awk '{print $2}' | cut -d'/' -f2 | head -n1 || true)"
    fi

    if [ -n "$KEY_ID" ]; then
        (
            cd "${PUBLIC_DIR}/dist"
            gpg --batch --yes --default-key "$KEY_ID" --clearsign -o InRelease Release
            gpg --batch --yes --default-key "$KEY_ID" -abs -o Release.gpg Release
        )
        echo -e "${GREEN}✔ Repository signed successfully with key $KEY_ID${NC}"
    else
        echo -e "${RED}✖ Error: No GPG signing key found in GnuPG keyring.${NC}"
    fi
else
    echo -e "\n${YELLOW}⚠ Skipping signature: No GPG_PRIVATE_KEY found in environment.${NC}"
fi

echo -e "\n${BLUE}✔ Build finished: ${BUILT} built, ${SKIPPED} skipped, ${FAILED} failed.${NC}"
