#!/bin/bash

# Configuration directories
REPO_DIR="public/dist"
mkdir -p "${REPO_DIR}"
BUILD_DIR="build"

# Terminal colors
BLUE="\e[1;34m"
GREEN="\e[1;32m"
YELLOW="\e[1;33m"
RED="\e[1;31m"
NC="\e[0m"

for pkg_file in packages/*.conf; do
    # Continue if packages directory is empty
    [ -e "$pkg_file" ] || continue
    
    echo -e "${BLUE}Processing package: $pkg_file${NC}"

    # Reset previous package definition
    unset REPO_PATH PKG_NAME DESCRIPTION ASSET_NAME

    # Load package definition
    source "$pkg_file"
    if [[ -z "$REPO_PATH" ]]; then
        echo -e "${RED}✖ Error: Missing REPO_PATH${NC}"
        continue
    fi
    
    # Automatically derive package name from filename if not specified
    PKG_NAME="${PKG_NAME:-$(basename "$pkg_file" .conf)}" 

    # Fetch latest version tag from GitHub API
    LATEST_URL="https://api.github.com/repos/${REPO_PATH}/releases/latest"
    LATEST_TAG=$(curl -s ${LATEST_URL} | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [[ -z "$LATEST_TAG" || "$LATEST_TAG" = "null" ]]; then
        echo -e "${RED}✖ Error: Failed to fetch latest release from ${LATEST_URL}${NC}"
        continue
    fi
    VERSION=${LATEST_TAG#v}
    
    # Skip build if the package version already exists in the repository
    if ls "${REPO_DIR}/${PKG_NAME}_${VERSION}"_*.deb >/dev/null 2>&1; then
        echo -e "${GREEN}✔ $PKG_NAME ($VERSION) is already up to date.${NC}"
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
        mkdir -p "${BUILD_DIR}/extract_${PKG_NAME}"
        curl -sSL "$DOWNLOAD_URL" -o "${BUILD_DIR}/extract_${PKG_NAME}/archive.tar.gz"
        tar -xzf "${BUILD_DIR}/extract_${PKG_NAME}/archive.tar.gz" -C "${BUILD_DIR}/extract_${PKG_NAME}/"
        
        # Move extracted binary to final destination inside the deb structure
        if [ -f "${BUILD_DIR}/extract_${PKG_NAME}/${PKG_NAME}" ]; then
            mv "${BUILD_DIR}/extract_${PKG_NAME}/${PKG_NAME}" "${PKG_BUILD_DIR}/usr/local/bin/${PKG_NAME}"
        fi
        rm -rf "${BUILD_DIR}/extract_${PKG_NAME}"
    else
        # Fallback for standalone raw binaries (like talosctl)
        echo -e "${YELLOW}➔ Downloading standalone binary...${NC}"
        curl -sSL "$DOWNLOAD_URL" -o "${PKG_BUILD_DIR}/usr/local/bin/${PKG_NAME}"
    fi

    # Build the final .deb package using dpkg-deb
    if [ -f "${PKG_BUILD_DIR}/usr/local/bin/${PKG_NAME}" ]; then
        chmod +x "${PKG_BUILD_DIR}/usr/local/bin/${PKG_NAME}"
        dpkg-deb --build "${PKG_BUILD_DIR}" "${REPO_DIR}/" > /dev/null
        echo -e "${GREEN}✔ Successfully created .deb package for $PKG_NAME ($VERSION).${NC}"

        # Keep only the latest version of this package in the repository
        for old_deb in "${REPO_DIR}/${PKG_NAME}"_*.deb; do
            [ -e "$old_deb" ] || continue
            old_ver=$(dpkg-deb --field "$old_deb" Version 2>/dev/null)
            if [[ "$old_ver" != "$VERSION" ]]; then
                rm -f "$old_deb"
            fi
        done
    else
        echo -e "${RED}✖ Error: Target binary '$PKG_NAME' is missing from tree (extraction failure?).${NC}"
    fi
    
    # Cleanup build workspace for this package
    rm -rf "${PKG_BUILD_DIR}"
done

# --- GENERATE APT REPOSITORY INDICES ---
echo -e "\n${BLUE}➤ Indexing APT repository...${NC}"
cd "public" && dpkg-scanpackages dist /dev/null > dist/Packages
gzip -9c dist/Packages > dist/Packages.gz
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
' dist/Packages > "${PACKAGES_FRAGMENT}"

# The template lives at the project root (../index.html from here) and is never modified.
# Materialize it into public/index.html, then inject the package list into that target only.
if [ -f "../index.html" ]; then
    cp "../index.html" index.html
fi

if [ ! -f "index.html" ]; then
    echo -e "${YELLOW}⚠ No index.html found; skipping homepage package list.${NC}"
elif grep -q '<!-- PACKAGES -->' index.html; then
    awk '/<!-- PACKAGES -->/{exit} {print}' index.html > /tmp/index-head.html
    awk 'f{print} /<!-- PACKAGES -->/{f=1}' index.html > /tmp/index-tail.html
    cat /tmp/index-head.html "${PACKAGES_FRAGMENT}" /tmp/index-tail.html > index.html.tmp
    mv index.html.tmp index.html
    echo -e "${GREEN}✔ Homepage package list updated.${NC}"
else
    echo -e "${YELLOW}⚠ Marker <!-- PACKAGES --> not found in index.html; skipping.${NC}"
fi
rm -f /tmp/index-head.html /tmp/index-tail.html "${PACKAGES_FRAGMENT}"

# --- SIGN APT REPOSITORY ---
if [ -n "$GPG_PRIVATE_KEY" ] || gpg --list-secret-keys &>/dev/null; then
    echo -e "\n${BLUE}➤ Signing APT repository...${NC}"
    
    # 1. Create a Release metadata file
    cd dist || exit 1
    apt-ftparchive -o APT::FTPArchive::Release::Codename=dist release . > Release
    cd ..
    
    # 2. Import the private key with robust handling of newlines
    if [ -n "$GPG_PRIVATE_KEY" ]; then
        echo "$GPG_PRIVATE_KEY" | gpg --batch --import &>/dev/null
    fi
    
    # 3. Get the LONG format Key ID
    KEY_ID=$(gpg --list-secret-keys --keyid-format LONG | grep -E '^sec' | awk '{print $2}' | cut -d'/' -f2 | head -n1)
    
    if [ -n "$KEY_ID" ]; then
        cd dist || exit 1
        # Sign files
        gpg --batch --yes --default-key "$KEY_ID" --clearsign -o InRelease Release
        gpg --batch --yes --default-key "$KEY_ID" -abs -o Release.gpg Release
        cd ..
        echo -e "${GREEN}✔ Repository signed successfully with key $KEY_ID${NC}"
    else
        echo -e "${RED}✖ Error: No GPG signing key found in GnuPG keyring.${NC}"
    fi
else
    echo -e "\n${YELLOW}⚠ Skipping signature: No GPG_PRIVATE_KEY found in environment.${NC}"
fi

