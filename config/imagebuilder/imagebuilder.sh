#!/bin/bash
#================================================================================================
#
# This file is licensed under the terms of the GNU General Public
# License version 2. This program is licensed "as is" without any
# warranty of any kind, whether express or implied.
#
# This file is a part of the OpenWrt Image Builder workflow
# https://github.com/ophub/amlogic-s9xxx-openwrt
#
# Description: Build OpenWrt firmware using the official Image Builder
# Copyright (C) 2021~ https://github.com/unifreq/openwrt_packit
# Copyright (C) 2021~ https://github.com/ophub/amlogic-s9xxx-openwrt
# Copyright (C) 2021~ https://downloads.openwrt.org/releases
# Copyright (C) 2023~ https://downloads.immortalwrt.org/releases
#
# Download from: https://downloads.openwrt.org/releases
#                https://downloads.openwrt.org/snapshots
#                https://downloads.immortalwrt.org/releases
#
# Documentation: https://openwrt.org/docs/guide-user/additional-software/imagebuilder
# Instructions:  Download the official OpenWrt Image Builder,
#                then use it to add packages, libraries, themes, apps, and i18n support.
#
# Command: ./config/imagebuilder/imagebuilder.sh <source:branch>
#          ./config/imagebuilder/imagebuilder.sh openwrt:24.10.4
#
#======================================== Functions list ========================================
#
# error_msg               : Output error message and abort
# github_api              : Query the GitHub API (uses GITHUB_TOKEN when available)
# download_imagebuilder   : Download and extract the OpenWrt Image Builder
# adjust_settings         : Adjust Image Builder .config settings
# custom_packages         : Download and add custom packages
# custom_config           : Load custom package configuration
# custom_files            : Add custom overlay files
# check_custom_package    : Verify that a required custom package file exists
# rebuild_firmware        : Build firmware using Image Builder
# custom_settings         : Apply post-build customizations
#
#================================ Set make environment variables ================================
#
# Set default parameters
make_path="${PWD}"
openwrt_dir="imagebuilder"
imagebuilder_path="${make_path}/${openwrt_dir}"
custom_files_path="${make_path}/config/imagebuilder/files"
custom_config_file="${make_path}/config/imagebuilder/config"
output_path="${make_path}/output"
tmp_path="${imagebuilder_path}/tmp"
unpack_path="${tmp_path}/unpacked_rootfs"

# Fallback download URLs, used only when the GitHub API cannot be reached (e.g. rate limit).
# Update these when a newer release is needed.
amlogic_fallback_url="https://github.com/ophub/luci-app-amlogic/releases/download/26.10.1501-js/luci-app-amlogic-26.10.1501-r2.apk"
nikki_fallback_url="https://github.com/nikkinikki-org/OpenWrt-nikki/releases/download/v1.26.2/nikki_aarch64_generic-SNAPSHOT.tar.gz"

# Set default parameters
STEPS="[\033[95m STEPS \033[0m]"
INFO="[\033[94m INFO \033[0m]"
SUCCESS="[\033[92m SUCCESS \033[0m]"
WARNING="[\033[93m WARNING \033[0m]"
ERROR="[\033[91m ERROR \033[0m]"
#
#================================================================================================

# Output error message and abort script execution
error_msg() {
    echo -e "${ERROR} ${1}"
    exit 1
}

# Query the GitHub API. Use GITHUB_TOKEN when it is set to avoid anonymous rate limits.
github_api() {
    local api_url="${1}"
    if [[ -n "${GITHUB_TOKEN}" ]]; then
        curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN}" "${api_url}" 2>/dev/null
    else
        curl -fsSL "${api_url}" 2>/dev/null
    fi
}

# Downloading OpenWrt ImageBuilder
download_imagebuilder() {
    cd ${make_path}
    echo -e "${STEPS} Downloading OpenWrt ImageBuilder..."

    # Downloading imagebuilder files
    if [[ "${op_sourse}" == "immortalwrt" ]]; then
        download_url="downloads.immortalwrt.org"
    else
        download_url="downloads.openwrt.org"
    fi
    # Use snapshots URL for snapshot builds, releases URL for stable releases
    if [[ "${op_branch}" == "snapshots" ]]; then
        download_file="https://${download_url}/snapshots/targets/armsr/armv8/${op_sourse}-imagebuilder-armsr-armv8.Linux-x86_64.tar.zst"
    else
        download_file="https://${download_url}/releases/${op_branch}/targets/armsr/armv8/${op_sourse}-imagebuilder-${op_branch}-armsr-armv8.Linux-x86_64.tar.zst"
    fi
    curl -fsSOL ${download_file}
    [[ "${?}" -eq "0" ]] || error_msg "Failed to download: [ ${download_file} ]"

    # Unzip and change the directory name
    tar -I zstd -xvf *-imagebuilder-*.tar.zst -C . && sync && rm -f *-imagebuilder-*.tar.zst
    mv -f *-imagebuilder-* ${openwrt_dir}

    # Create the tmp directory early so that make does not warn about a missing TMPDIR
    mkdir -p "${tmp_path}"

    sync && sleep 3
    echo -e "${INFO} [ ${make_path} ] directory contents: \n$(ls -lh . 2>/dev/null)"
}

# Adjust related files in the ImageBuilder directory
adjust_settings() {
    cd ${imagebuilder_path}
    echo -e "${STEPS} Adjusting ImageBuilder .config settings..."

    # For .config file
    if [[ -s ".config" ]]; then
        # Root filesystem archives
        sed -i "s|CONFIG_TARGET_ROOTFS_CPIOGZ=.*|# CONFIG_TARGET_ROOTFS_CPIOGZ is not set|g" .config
        # Root filesystem images
        sed -i "s|CONFIG_TARGET_ROOTFS_EXT4FS=.*|# CONFIG_TARGET_ROOTFS_EXT4FS is not set|g" .config
        sed -i "s|CONFIG_TARGET_ROOTFS_SQUASHFS=.*|# CONFIG_TARGET_ROOTFS_SQUASHFS is not set|g" .config
        sed -i "s|CONFIG_TARGET_IMAGES_GZIP=.*|# CONFIG_TARGET_IMAGES_GZIP is not set|g" .config
    else
        echo -e "${INFO} [ ${imagebuilder_path} ] directory contents: \n$(ls -lh . 2>/dev/null)"
        error_msg "No .config file found in [ ${download_file} ]."
    fi

    # For other files
    # ......

    sync && sleep 3
    echo -e "${INFO} [ ${imagebuilder_path} ] directory contents: \n$(ls -lh . 2>/dev/null)"
}

# Add custom packages
# If there is a custom package or ipk you would prefer to use create a [ packages ] directory,
# If one does not exist and place your custom ipk within this directory.
custom_packages() {
    cd ${imagebuilder_path}
    echo -e "${STEPS} Adding custom packages..."

    # Create a [ packages ] directory
    [[ -d "packages" ]] || mkdir packages
    cd packages

    # Detect the package format of the Image Builder: APK (new) or OPKG (ipk)
    if grep -q "CONFIG_USE_APK=y" ../.config; then
        pkg_format="apk"
    else
        pkg_format="ipk"
    fi

    # Download luci-app-amlogic: latest "-js" release, matching the package format
    amlogic_api="https://api.github.com/repos/ophub/luci-app-amlogic/releases"
    amlogic_json="$(github_api "${amlogic_api}")"
    amlogic_latest_tag="$(echo "${amlogic_json}" | grep -oP '(?<="tag_name": ")[^"]+' | grep -- "-js$" | sort -Vr | head -n1)"
    amlogic_url=""
    if [[ -n "${amlogic_latest_tag}" ]]; then
        amlogic_url="$(echo "${amlogic_json}" | grep -oE "https://[^\"]*/${amlogic_latest_tag}/[^\"]*\.${pkg_format}" | head -n1)"
    fi
    # Use the fallback URL if the API did not return a usable link (APK builds only)
    if [[ -z "${amlogic_url}" && "${pkg_format}" == "apk" ]]; then
        echo -e "${WARNING} GitHub API did not return a luci-app-amlogic link, using the fallback URL."
        amlogic_url="${amlogic_fallback_url}"
    fi
    if [[ -n "${amlogic_url}" ]]; then
        curl -fsSOJL "${amlogic_url}" \
            && echo -e "${INFO} The [ $(basename "${amlogic_url}") ] is downloaded successfully." \
            || echo -e "${WARNING} Failed to download [ ${amlogic_url} ]."
    else
        echo -e "${WARNING} No luci-app-amlogic [ .${pkg_format} ] link found for this build."
    fi

    # Download Nikki (Mihomo Proxy) for OpenWrt
    echo -e "${INFO} Downloading Nikki..."
    nikki_api="https://api.github.com/repos/nikkinikki-org/OpenWrt-nikki/releases/latest"

    # Map op_branch to the branch identifier used in the Nikki asset name
    case "${op_branch}" in
        24.10*)    nikki_branch="openwrt-24.10" ;;
        25.12*)    nikki_branch="openwrt-25.12" ;;
        snapshots) nikki_branch="SNAPSHOT" ;;
        *)         nikki_branch="" ;;
    esac

    if [[ -n "${nikki_branch}" ]]; then
        # Find the download link for this branch in the latest release
        nikki_url="$(github_api "${nikki_api}" | grep -oE "https://[^\"]*/nikki_aarch64_generic-${nikki_branch}\.tar\.gz" | head -n1)"
        # The latest release may not contain the SNAPSHOT asset, so use the fallback URL
        if [[ -z "${nikki_url}" && "${nikki_branch}" == "SNAPSHOT" ]]; then
            echo -e "${WARNING} GitHub API did not return a Nikki link, using the fallback URL."
            nikki_url="${nikki_fallback_url}"
        fi

        if [[ -n "${nikki_url}" ]]; then
            curl -fsSOJL "${nikki_url}"
            nikki_archive="nikki_aarch64_generic-${nikki_branch}.tar.gz"
            if [[ -f "${nikki_archive}" ]]; then
                echo -e "${INFO} Extracting the Nikki package archive..."
                tar -xzf "${nikki_archive}"
                rm -f "${nikki_archive}"
            else
                echo -e "${WARNING} Failed to download [ ${nikki_url} ]."
            fi
        else
            echo -e "${WARNING} No Nikki download link found for branch [ ${nikki_branch} ]."
        fi
    else
        echo -e "${WARNING} Branch [ ${op_branch} ] has no Nikki asset mapping, skipped."
    fi

    # Download the L860-GL modem package (AT command driver + luci-proto-atc)
    # Source: https://github.com/iqbalramdhan/ATCommands (fork of mrhaav/openwrt)
    echo -e "${INFO} Downloading L860-GL modem (ATC) packages..."
    atc_repo_raw="https://raw.githubusercontent.com/iqbalramdhan/ATCommands/master/atc"
    atc_files=(
        "fib-l8x0_gl/atc-fib-l8x0_gl-2025.09.06-r3.apk"
        "luci-proto-atc-2025.01.10-r2.apk"
    )
    for atc_file in "${atc_files[@]}"; do
        curl -fsSOJL "${atc_repo_raw}/${atc_file}"
        if [[ "${?}" -eq "0" ]]; then
            echo -e "${INFO} The [ $(basename "${atc_file}") ] is downloaded successfully."
        else
            echo -e "${WARNING} Failed to download [ ${atc_file} ], skipped."
        fi
    done

    # Remove the packages that do not match the Image Builder format
    if [[ "${pkg_format}" == "apk" ]]; then
        echo -e "${INFO} APK-based ImageBuilder detected. Removing .ipk files..."
        rm -f *.ipk

        # Image Builder requires the commit hash in the filename to be preceded by a tilde (~)
        # instead of a dot (.). Replace the dot before the 7-character commit hash.
        for file in *.apk; do
            [[ -f "${file}" ]] || continue
            new_file=$(echo "${file}" | sed -E 's/\.([a-f0-9]{7}\.apk)/~\1/')
            if [[ "${file}" != "${new_file}" ]]; then
                mv -f "${file}" "${new_file}" || true
                echo -e "${INFO} Renamed: ${file} -> ${new_file}"
            fi
        done
    else
        echo -e "${INFO} OPKG-based ImageBuilder detected. Removing .apk files..."
        rm -f *.apk
    fi

    sync && sleep 3
    echo -e "${INFO} [ packages ] directory contents: \n$(ls -lh . 2>/dev/null)"
}

# Add custom packages, lib, theme, app and i18n, etc.
custom_config() {
    cd ${imagebuilder_path}
    echo -e "${STEPS} Loading custom package configuration..."

    config_list=""
    if [[ -s "${custom_config_file}" ]]; then
        config_list="$(sed -n 's/^CONFIG_PACKAGE_\(.*\)=y$/\1/p' "${custom_config_file}" | tr '\n' ' ')"
        echo -e "${INFO} Custom package list: \n$(echo "${config_list}" | tr ' ' '\n')"
    else
        echo -e "${INFO} No custom configuration file found, skipped."
    fi
}

# Add custom files
# The FILES variable allows custom configuration files to be included in images built with Image Builder.
# The [ files ] directory should be placed in the Image Builder root directory where you issue the make command.
custom_files() {
    cd ${imagebuilder_path}
    echo -e "${STEPS} Adding custom files..."

    if [[ -d "${custom_files_path}" ]]; then
        # Copy custom files
        [[ -d "files" ]] || mkdir -p files
        cp -rf ${custom_files_path}/* files

        sync && sleep 3
        echo -e "${INFO} [ files ] directory contents: \n$(ls -lh files/ 2>/dev/null)"
    else
        echo -e "${INFO} No custom files added, skipped."
    fi
}

# Check that a custom package file exists in the [ packages ] directory.
# Versions start with a digit, so "nikki-<digit>" does not match "luci-app-nikki-<digit>".
check_custom_package() {
    local pkg_name="${1}"
    ls packages/${pkg_name}-[0-9]*.apk packages/${pkg_name}-[0-9]*.ipk >/dev/null 2>&1 \
        || error_msg "Custom package [ ${pkg_name} ] was not found in the [ packages ] directory."
}

# Rebuild OpenWrt firmware
rebuild_firmware() {
    cd ${imagebuilder_path}
    echo -e "${STEPS} Building OpenWrt firmware with Image Builder..."

    # Make sure the required custom packages were downloaded before building
    check_custom_package "luci-app-amlogic"
    if [[ " ${config_list} " == *" nikki "* ]]; then
        check_custom_package "nikki"
        check_custom_package "luci-app-nikki"
    fi

    # Selecting default packages, lib, theme, app and i18n, etc.
    # NOTE: "-dnsmasq" excludes the default dnsmasq package so it can be replaced by dnsmasq-full below.
    my_packages="\
        -dnsmasq cgi-io libiwinfo libiwinfo-data libiwinfo-lua liblua liblucihttp liblucihttp-lua \
        libubus-lua lua luci luci-app-firewall luci-app-opkg luci-base luci-lib-base \
        luci-lib-ip luci-lib-jsonc luci-lib-nixio luci-mod-admin-full luci-mod-network \
        luci-mod-status luci-mod-system luci-proto-ppp luci-ssl \
        px5g-mbedtls rpcd rpcd-mod-file rpcd-mod-iwinfo rpcd-mod-luci \
        rpcd-mod-rrdns uhttpd uhttpd-mod-ubus luci-compat \
        usb-modeswitch kmod-usb-net-rtl8152 \
        luci-app-amlogic openssh-sftp-server usbutils kmod-usb2 kmod-brcmfmac \
        kmod-brcmutil perlbase-essential perlbase-utf8 \
        perlbase-file perlbase-time perlbase-xsloader coreutils-stat \
        kmod-usb-acm kmod-usb-net-cdc-ncm comgt \
        r8152-firmware btrfs-progs comgt-ncm nano-full \
        bash dnsmasq-full curl ca-bundle ip-full ruby ruby-yaml kmod-tun \
        kmod-inet-diag unzip kmod-nft-tproxy zoneinfo-asia \
        \
        ${config_list} \
        "

    # Rebuild firmware, and stop immediately if make fails
    make image PROFILE="" PACKAGES="${my_packages}" FILES="files" \
        || error_msg "Image Builder failed. Check the log above for the cause."

    sync && sleep 3
    echo -e "${INFO} [ ${openwrt_dir}/bin/targets/*/*/ ] directory contents: \n$(ls -lh bin/targets/*/*/ 2>/dev/null)"
    echo -e "${INFO} Firmware build completed successfully."
}

# Custom settings after rebuild
custom_settings() {
    cd ${imagebuilder_path}
    echo -e "${STEPS} Applying post-build customizations..."

    # Clean up temporary and output directories
    mkdir -p "${tmp_path}" "${output_path}"
    rm -rf "${tmp_path:?}"/* "${output_path:?}"/*

    # Find the original *rootfs.tar.gz file
    original_archive="$(ls -1 bin/targets/*/*/*rootfs.tar.gz 2>/dev/null | head -n 1)"

    # Check if the original archive exists
    if [[ ! -f "${original_archive}" ]]; then
        error_msg "No rootfs.tar.gz archive found in build output."
    else
        echo -e "${INFO} Found rootfs archive: ${original_archive}"

        # Get the filename and path
        original_filename="$(basename "${original_archive}")"
        original_path="$(dirname "${original_archive}")"

        # Unpack the original archive
        echo -e "${INFO} Unpacking ${original_filename}..."
        mkdir -p "${unpack_path}"
        tar -xzpf "${original_archive}" -C "${unpack_path}"

        # Modify etc/openwrt_release
        release_file="${unpack_path}/etc/openwrt_release"
        if [[ -f "${release_file}" ]]; then
            echo -e "${INFO} Updating etc/openwrt_release..."
            {
                echo "DISTRIB_SOURCEREPO='github.com/${op_sourse}/${op_sourse}'"
                echo "DISTRIB_SOURCECODE='${op_sourse}'"
                echo "DISTRIB_SOURCEBRANCH='${op_branch}'"
            } >>"${release_file}"
        else
            error_msg "${release_file} not found."
        fi

        # Repack the modified root filesystem.
        # This script runs unprivileged, so the unpacked tree is owned by the
        # build user. Force uid/gid 0 on repack, otherwise every file ships
        # with a non-root owner and rpcd's rc_check_script() drops all
        # /etc/init.d entries from `ubus call rc list` (empty Startup page).
        echo -e "${INFO} Repacking into ${original_filename}..."
        (cd "${unpack_path}" && tar --numeric-owner --owner=0 --group=0 -czpf "${tmp_path}/${original_filename}" ./)

        # Move the repacked archive to the output directory
        echo -e "${INFO} Moving modified rootfs to output directory..."
        mv -f "${tmp_path}/${original_filename}" "${output_path}/"
        # Copy the config file to the output directory
        cp -f .config "${output_path}/config" || true
    fi

    sync && sleep 3
    cd ${make_path}
    rm -rf "${imagebuilder_path}"
    echo -e "${INFO} [ ${output_path} ] directory contents: \n$(ls -lh ${output_path}/ 2>/dev/null)"
    echo -e "${INFO} Post-build customizations applied successfully."
}

# Show welcome message
echo -e "${STEPS} Welcome to the OpenWrt Image Builder."
[[ -x "${0}" ]] || error_msg "Please grant execution permission: [ chmod +x ${0} ]"
[[ -z "${1}" ]] && error_msg "Please specify the OpenWrt source and branch, e.g. [ ${0} openwrt:24.10.4 ]"
[[ "${1}" =~ ^[a-z]{3,}:([0-9]+\.[0-9]+\.[0-9]+|[0-9]+\.[0-9]+|[0-9]+|snapshots) ]] || error_msg "Invalid parameter format. Expected <source:branch>, e.g. openwrt:24.10.4 or openwrt:snapshots"
op_sourse="${1%:*}"
op_branch="${1#*:}"
echo -e "${INFO} Working directory: [ ${PWD} ]"
echo -e "${INFO} Source: [ ${op_sourse} ], Branch: [ ${op_branch} ]"
echo -e "${INFO} Server disk usage before build: \n$(df -hT ${make_path}) \n"
#
# Perform related operations
download_imagebuilder
adjust_settings
custom_packages
custom_config
custom_files
rebuild_firmware
custom_settings
#
# Show server end information
echo -e "${SUCCESS} OpenWrt Image Builder completed successfully."
echo -e "${INFO} Server disk usage after build: \n$(df -hT ${make_path}) \n"