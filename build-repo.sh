#!/bin/bash
set -euo pipefail

# --- Path anchors: the script works regardless of the invocation directory ---
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${ROOT}/public/dist"
PUBLIC_DIR="${ROOT}/public"
BUILD_DIR="${ROOT}/build"
CACHE_DIR="${REPO_DIR}/cache"
SCRIPT_FILE="${ROOT}/build-repo.sh"

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

hash_file() {
    sha256sum "$1" 2>/dev/null | cut -d' ' -f1 || true
}

download() {
    curl -fsSL --retry 3 "$1" -o "$2"
}

# Remove older .deb versions of this package from the repository
prune_old_versions() {
    for old_deb in "${REPO_DIR}/${PKG_NAME}"_*.deb; do
        [ -e "$old_deb" ] || continue
        old_ver="$(dpkg-deb --field "$old_deb" Version 2>/dev/null || true)"
        if [[ "$old_ver" != "$VERSION" ]]; then
            rm -f "$old_deb"
        fi
    done
}

# Finalize a successfully built package: bump counter, write the cache, cleanup
finalize_build() {
    BUILT=$((BUILT + 1))
    printf '%s\t%s\n' "${FINGERPRINT}" "$(hash_file "${DEB_ARCHIVE}")" > "${CACHE_FILE}"
    rm -rf "${PKG_BUILD_DIR}"
}

# --- Clean up packages whose .conf no longer exists ---
# Iterating once over the cache and the repository prevents orphaned
# .deb files and sidecars from being served after a package is removed.
shopt -s nullglob
for file in "${CACHE_DIR}/"*.sha "${REPO_DIR}/"*.deb; do
    [ -e "$file" ] || continue
    case "$file" in
        *.sha) pkg_name="$(basename "$file" .sha)" ;;
        *)     pkg_name="$(basename "$file" | cut -d_ -f1)" ;;
    esac
    if [ ! -f "${ROOT}/packages/${pkg_name}.conf" ]; then
        echo -e "${YELLOW}➔ Removing orphaned artifact for removed package '${pkg_name}': $(basename "$file")${NC}"
        rm -f "$file"
    fi
done
shopt -u nullglob

for pkg_file in "${ROOT}"/packages/*.conf; do
    # Continue if packages directory is empty
    [ -e "$pkg_file" ] || continue

    echo -e "${BLUE}Processing package: $(basename "$pkg_file")${NC}"

    # Reset previous package definition (all supported keys)
    unset REPO_PATH PKG_NAME DESCRIPTION ASSET_NAME BINARY_NAME HOME_PAGE DOWNLOAD_URL LATEST_URL LATEST_JSON_FIELD

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

    # Fetch and validate the latest release version.
    # LATEST_URL overrides the GitHub releases API with any version source
    # that returns the latest tag/version (e.g. https://dl.k8s.io/release/stable.txt).
    # LATEST_JSON_FIELD extracts a dotted path (e.g. .tag_name) from a JSON response.
    if [[ -n "${LATEST_URL:-}" ]]; then
        if [[ -n "${LATEST_JSON_FIELD:-}" ]]; then
            if [[ ! "$LATEST_JSON_FIELD" =~ ^[.a-zA-Z0-9_]+$ ]]; then
                echo -e "${RED}✖ Error: Invalid LATEST_JSON_FIELD '$LATEST_JSON_FIELD' (expected a dotted path, e.g. .tag_name)${NC}"
                FAILED=$((FAILED + 1))
                continue
            fi
            LATEST_TAG=""
            # Route GitHub API URLs through the authenticated gh CLI when available
            # (it uses GITHUB_TOKEN on runners, avoiding anonymous API rate limits).
            if command -v gh >/dev/null 2>&1 && [[ "${LATEST_URL}" == https://api.github.com/* ]]; then
                JQ_FIELD="${LATEST_JSON_FIELD}"
                [[ "$JQ_FIELD" == .* ]] || JQ_FIELD=".${JQ_FIELD}"
                LATEST_TAG="$(gh api "${LATEST_URL#https://api.github.com/}" --jq "${JQ_FIELD}" 2>/dev/null || true)"
            fi
            if [[ -z "$LATEST_TAG" ]]; then
                LATEST_TAG="$(curl -fsSL --retry 3 "${LATEST_URL}" | python3 -c "import json,sys
d=json.load(sys.stdin)
for k in '${LATEST_JSON_FIELD#.}'.split('.'):
    d=d[k]
print(d)")"
            fi
        else
            LATEST_TAG="$(curl -fsSL --retry 3 "${LATEST_URL}" | tr -d '[:space:]')"
        fi
    else
        LATEST_TAG="$(get_latest_tag "${REPO_PATH}")"
    fi
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

    # Resolve VERSION/TAG tokens in ASSET_NAME (e.g. hugo_VERSION_linux-amd64.tar.gz)
    ASSET_NAME="${ASSET_NAME//VERSION/$VERSION}"
    ASSET_NAME="${ASSET_NAME//TAG/$LATEST_TAG}"

    # Fingerprint of this package's build inputs (script + .conf).
    # Any change to either forces a regeneration of this package.
    FINGERPRINT="$(hash_file "${SCRIPT_FILE}")$(hash_file "$pkg_file")"

    # Skip build if the existing .deb matches the current build inputs.
    mkdir -p "${CACHE_DIR}"
    DEB_ARCHIVE="${REPO_DIR}/${PKG_NAME}_${VERSION}_amd64.deb"
    CACHE_FILE="${CACHE_DIR}/${PKG_NAME}.sha"
    CACHED_FINGERPRINT=""; CACHED_DEB_SHA=""
    if [ -f "${CACHE_FILE}" ]; then
        IFS=$'\t' read -r CACHED_FINGERPRINT CACHED_DEB_SHA < "${CACHE_FILE}" || true
    fi
    if [ -f "${DEB_ARCHIVE}" ] \
       && [ "${CACHED_FINGERPRINT}" = "${FINGERPRINT}" ] \
       && [ "$(hash_file "${DEB_ARCHIVE}")" = "${CACHED_DEB_SHA}" ]; then
        echo -e "${GREEN}✔ $PKG_NAME ($VERSION) is already up to date.${NC}"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Prepare Debian build directory structure
    PKG_BUILD_DIR="${BUILD_DIR}/${PKG_NAME}_${VERSION}_amd64"
    mkdir -p "${PKG_BUILD_DIR}/DEBIAN" "${PKG_BUILD_DIR}/usr/local/bin"
    HOME_PAGE="${HOME_PAGE:-https://github.com/${REPO_PATH}}"

    cat << EOF > "${PKG_BUILD_DIR}/DEBIAN/control"
Package: ${PKG_NAME}
Version: ${VERSION}
Architecture: amd64
Maintainer: APT Overlay System
Homepage: ${HOME_PAGE}
Description: ${DESCRIPTION:-}
EOF

    # Build download URL using LATEST_TAG to avoid GitHub 404 errors.
    # DOWNLOAD_URL overrides the GitHub releases URL with a custom template
    # and supports the same VERSION/TAG tokens (e.g. dl.k8s.io URLs).
    DOWNLOAD_URL="${DOWNLOAD_URL:-https://github.com/${REPO_PATH}/releases/download/${LATEST_TAG}/${ASSET_NAME}}"
    DOWNLOAD_URL="${DOWNLOAD_URL//VERSION/$VERSION}"
    DOWNLOAD_URL="${DOWNLOAD_URL//TAG/$LATEST_TAG}"

    # Re-host official .deb releases as-is (menus, icons and deps stay intact).
    # The only transformation is renaming to the repo convention so version
    # cleanup and orphan detection keep working.
    if [[ "$ASSET_NAME" == *.deb ]]; then
        echo -e "${YELLOW}➔ Downloading official .deb package...${NC}"
        download "$DOWNLOAD_URL" "${BUILD_DIR}/${PKG_NAME}.deb"
        if ! dpkg-deb --info "${BUILD_DIR}/${PKG_NAME}.deb" > /dev/null 2>&1; then
            echo -e "${RED}✖ Error: Downloaded file is not a valid .deb package${NC}"
            rm -f "${BUILD_DIR}/${PKG_NAME}.deb"
            rm -rf "${PKG_BUILD_DIR}"
            FAILED=$((FAILED + 1))
            continue
        fi
        mv "${BUILD_DIR}/${PKG_NAME}.deb" "${DEB_ARCHIVE}"
        echo -e "${GREEN}✔ Re-hosted official .deb for $PKG_NAME ($VERSION).${NC}"

        prune_old_versions
        finalize_build
        continue
    fi

    # Handle asset types dynamically (archive extraction vs standalone binary)
    if [[ "$ASSET_NAME" == *.tar.gz || "$ASSET_NAME" == *.zip ]]; then
        echo -e "${YELLOW}➔ Downloading and extracting archive...${NC}"
        EXTRACT_DIR="${BUILD_DIR}/extract_${PKG_NAME}"
        mkdir -p "${EXTRACT_DIR}"
        download "$DOWNLOAD_URL" "${EXTRACT_DIR}/archive"
        if [[ "$ASSET_NAME" == *.tar.gz ]]; then
            tar -xzf "${EXTRACT_DIR}/archive" -C "${EXTRACT_DIR}/"
        else
            unzip -q "${EXTRACT_DIR}/archive" -d "${EXTRACT_DIR}/"
        fi

        # Locate the target binary inside the archive:
        # 1. Explicit BINARY_NAME (or package name) at the archive root
        # 2. Same name anywhere in the tree
        # 3. The largest executable file found. zip archives may not
        #    preserve the exec bit, so fall back to the largest file.
        TARGET_NAME="${BINARY_NAME:-$PKG_NAME}"
        BINARY_SRC=""
        if [ -f "${EXTRACT_DIR}/${TARGET_NAME}" ]; then
            BINARY_SRC="${EXTRACT_DIR}/${TARGET_NAME}"
        elif [ -f "${EXTRACT_DIR}/${PKG_NAME}" ]; then
            BINARY_SRC="${EXTRACT_DIR}/${PKG_NAME}"
        else
            BINARY_SRC="$(find "${EXTRACT_DIR}" -type f -executable -printf '%s\t%p\n' 2>/dev/null | sort -nr | head -n1 | cut -f2- || true)"
        fi
        if [[ -z "$BINARY_SRC" ]]; then
            BINARY_SRC="$(find "${EXTRACT_DIR}" -type f -printf '%s\t%p\n' 2>/dev/null | sort -nr | head -n1 | cut -f2- || true)"
        fi

        if [[ -z "$BINARY_SRC" || ! -f "$BINARY_SRC" ]]; then
            echo -e "${RED}✖ Error: No binary ('${TARGET_NAME}') found inside the archive${NC}"
            rm -rf "${EXTRACT_DIR}" "${PKG_BUILD_DIR}"
            FAILED=$((FAILED + 1))
            continue
        fi

        mv "$BINARY_SRC" "${PKG_BUILD_DIR}/usr/local/bin/${PKG_NAME}"
        rm -rf "${EXTRACT_DIR}"
    else
        # Fallback for standalone raw binaries (like talosctl)
        echo -e "${YELLOW}➔ Downloading standalone binary...${NC}"
        download "$DOWNLOAD_URL" "${PKG_BUILD_DIR}/usr/local/bin/${PKG_NAME}"
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
    prune_old_versions

    finalize_build
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
    /^Homepage: /    { home = $2; next }
    /^$/             { emit(); next }
    { next }
    END { emit() }

    function emit() {
        if (pkg == "") return
        gsub(/&/, "\\&amp;", desc)
        gsub(/</, "\\&lt;", desc)
        gsub(/>/, "\\&gt;", desc)
        printf "      <li class=\"pkg\">\n"
        if (home != "") {
            printf "        <a class=\"pkg-name\" href=\"%s\">%s</a>\n", home, pkg
        } else {
            printf "        <span class=\"pkg-name\">%s</span>\n", pkg
        }
        printf "        <a class=\"pkg-version\" href=\"./%s\">%s</a>\n", file, ver
        printf "        <span class=\"pkg-desc\">%s</span>\n", desc
        printf "      </li>\n"
        pkg = ""; ver = ""; file = ""; home = ""; desc = ""
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
