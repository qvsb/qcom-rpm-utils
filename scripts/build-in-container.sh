#!/usr/bin/env bash
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# =============================================================================
# build-in-container.sh — the per-package RPM build, run INSIDE the rpm-builder
# container. Not meant to be run directly; build-rpm.sh `docker run`s it.
# =============================================================================
# The rpm-builder image already provides the toolchain (rpm-build, compilers,
# CRB+EPEL). This script does the package-specific work:
#   1. rpmdev-setuptree
#   2. stage the tarball + spec into ~/rpmbuild/{SOURCES,SPECS}
#   3. optionally register an extra dnf repo (EXTRA_REPO_DIR)
#   4. optionally install local dependency RPMs (EXTRA_RPMS)
#   5. dnf builddep to resolve the spec's BuildRequires
#   6. rpmbuild -ba (binary + source RPMs)
#   7. copy the results to /workspace/output
#
# Inputs are passed as environment variables (set by build-rpm.sh):
#   TARBALL      basename of the source tarball under /workspace
#   SPEC_FILE    basename of the spec file under /workspace
#   RPM_MACROS   extra `rpmbuild --define` string (optional)
#   EXTRA_RPMS   space-separated local RPM paths under /workspace (optional)
#   EXTRA_REPO_DIR  http(s) dnf repo URL to register (optional)
#   HOST_UID/HOST_GID  uid:gid to chown ./output to on exit, so the caller can
#                   clean up its bind-mounted workspace (optional)
#
# /workspace is the bind-mounted host directory: it holds the tarball + spec on
# entry and receives ./output on exit.
# =============================================================================
set -euo pipefail

: "${TARBALL:?TARBALL is required}"
: "${SPEC_FILE:?SPEC_FILE is required}"
RPM_MACROS="${RPM_MACROS:-}"
EXTRA_RPMS="${EXTRA_RPMS:-}"
EXTRA_REPO_DIR="${EXTRA_REPO_DIR:-}"

WORKSPACE="/workspace"
cd "${WORKSPACE}"

if [[ ! -f "${TARBALL}" ]]; then
    echo "ERROR: tarball not found in workspace: ${TARBALL}" >&2; exit 1
fi
if [[ ! -f "${SPEC_FILE}" ]]; then
    echo "ERROR: spec not found in workspace: ${SPEC_FILE}" >&2; exit 1
fi

rpmdev-setuptree

spec_base="$(basename "${SPEC_FILE}")"

cp "${WORKSPACE}/${SPEC_FILE}" /root/rpmbuild/SPECS/

echo "=== Staging Sources and Patches ==="
rpmspec -P "/root/rpmbuild/SPECS/${spec_base}" \
    | grep -E '^(Source|Patch)[0-9]*[[:space:]]*:' \
    | sed 's/^[^:]*:[[:space:]]*//' \
    | while read -r entry; do
        [[ -z "${entry}" ]] && continue
        filename="$(basename "${entry}")"
        if [[ -f "${WORKSPACE}/${filename}" ]]; then
            cp -v "${WORKSPACE}/${filename}" /root/rpmbuild/SOURCES/
        else
            echo "WARN: missing source/patch: ${filename}" >&2
        fi
    done


if [[ -n "${EXTRA_REPO_DIR}" ]]; then
    echo "Registering extra dnf repo: ${EXTRA_REPO_DIR}"
    printf '[extra-repo]\nname=Extra RPM Repository\nbaseurl=%s\nenabled=1\ngpgcheck=0\nskip_if_unavailable=1\npriority=1\n' \
        "${EXTRA_REPO_DIR}" > /etc/yum.repos.d/extra-repo.repo
    dnf clean metadata
fi


if [[ -n "${EXTRA_RPMS}" ]]; then
    echo "Installing extra local RPMs: ${EXTRA_RPMS}"
    rpm_paths=()
    for rpm in ${EXTRA_RPMS}; do
        rpm_paths+=("${WORKSPACE}/${rpm}")
    done
    dnf install -y "${rpm_paths[@]}"
fi

dnf builddep -y "/root/rpmbuild/SPECS/${spec_base}"

eval rpmbuild -ba ${RPM_MACROS} "/root/rpmbuild/SPECS/${spec_base}"


OUT="${WORKSPACE}/output"
mkdir -p "${OUT}"
find /root/rpmbuild/RPMS  -name "*.rpm"     -exec cp -v {} "${OUT}/" \;
find /root/rpmbuild/SRPMS -name "*.src.rpm" -exec cp -v {} "${OUT}/" \;

# We run as root, so anything written to the bind mount lands on the host owned
# by root -- which the (unprivileged) caller then cannot delete when it cleans
# up its temp workspace. Hand ownership back when the caller tells us its IDs.
if [[ -n "${HOST_UID:-}" && -n "${HOST_GID:-}" ]]; then
    chown -R "${HOST_UID}:${HOST_GID}" "${OUT}"
fi

echo ""
echo "=== Built packages ==="
ls -lh "${OUT}/"
