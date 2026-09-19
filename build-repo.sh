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

# --- GENERATE A BASIC INDEX FOR GITHUB PAGES ---
cat << EOF > index.html
<!DOCTYPE html>
<html>
<head><title>APT Overlay</title></head>
<body><h1>abrunetme APT Overlay Repository is Online</h1></body>
</html>
EOF
