# Bluefin DX with Slimbook Executive hardware support.

ARG BASE_IMAGE=ghcr.io/ublue-os/bluefin-dx
FROM ${BASE_IMAGE}:stable


# ---------------------------------------------------------------------------
# Slimbook hardware support
# ---------------------------------------------------------------------------
#
# Bluefin contains a stub kernel-devel RPM entry without the actual headers.
# Slimbook akmods therefore have to be built while creating the image.
#
# Only the high-level packages we actually want are installed explicitly:
#
#   - slimbook-meta-executive
#   - slimbook-meta-gnome
#   - slimbook-yt6801-kmod
#
# The build verifies that the lower-level Slimbook packages are correctly
# pulled in as dependencies.
#
RUN <<-EOF
	set -eux

	# -----------------------------------------------------------------------
	# Kernel
	# -----------------------------------------------------------------------

	set -- $(rpm -q kernel --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n')

	if [ "$#" -ne 1 ]; then
		echo "Expected exactly one kernel in the Bluefin base image, found $#:"
		printf '%s\n' "$@"
		exit 1
	fi

	KVER="$1"

	echo "Bluefin kernel: ${KVER}"

	# Remove Bluefin's stub kernel-devel RPM entry.
	rpm -e --nodeps "kernel-devel-${KVER}" 2>/dev/null || true

	# Install the exact matching kernel-devel package.
	#
	# Fedora repositories normally provide it. If the kernel has already
	# disappeared from the active repositories, fetch the exact build from
	# Koji instead.
	if ! dnf install -y "kernel-devel-${KVER}"; then
		KVER_VERSION="${KVER%%-*}"
		KVER_REST="${KVER#*-}"
		KVER_ARCH="${KVER_REST##*.}"
		KVER_RELEASE="${KVER_REST%.*}"

		dnf install -y \
			"https://kojipkgs.fedoraproject.org/packages/kernel/${KVER_VERSION}/${KVER_RELEASE}/${KVER_ARCH}/kernel-devel-${KVER}.rpm"
	fi

	test -d "/usr/src/kernels/${KVER}"


	# -----------------------------------------------------------------------
	# Slimbook repository
	# -----------------------------------------------------------------------

	FEDORA_VER=$(rpm -E %fedora)

	echo "Fedora version: ${FEDORA_VER}"

	# Keep the Fedora N-1 fallback for this test repository.
	# It will be removed in the clean replacement repository.
	dnf config-manager addrepo \
		--from-repofile="https://download.opensuse.org/repositories/home:/Slimbook/Fedora_${FEDORA_VER}/home:Slimbook.repo" \
	|| dnf config-manager addrepo \
		--from-repofile="https://download.opensuse.org/repositories/home:/Slimbook/Fedora_$((FEDORA_VER - 1))/home:Slimbook.repo"


	# -----------------------------------------------------------------------
	# Slimbook packages
	# -----------------------------------------------------------------------

	# Minimal explicit package set under test.
	#
	# meta-executive should pull:
	#   - meta-common
	#   - slimbook-service
	#   - qc71-kmod
	#
	# yt6801 is kept explicit for this first reduction test.
	dnf install -y \
		--setopt=tsflags=noscripts \
		slimbook-meta-executive \
		slimbook-meta-gnome \
		slimbook-yt6801-kmod


	# -----------------------------------------------------------------------
	# Dependency validation
	# -----------------------------------------------------------------------

	# All packages below were explicit in the old image.
	# They must still be present after reducing the explicit install list.
	for PACKAGE in \
		slimbook-meta-common \
		slimbook-meta-executive \
		slimbook-meta-gnome \
		slimbook-service \
		slimbook-qc71-kmod \
		slimbook-qc71-kmod-common \
		slimbook-yt6801-kmod \
		slimbook-yt6801-kmod-common
	do
		rpm -q "${PACKAGE}"
	done


	# -----------------------------------------------------------------------
	# Build akmods
	# -----------------------------------------------------------------------

	chmod 1777 /tmp

	mkdir -p /var/lib/akmods
	chown akmods:akmods /var/lib/akmods

	ARCH=$(uname -m)

	for MODULE in \
		slimbook-qc71-kmod \
		slimbook-yt6801-kmod
	do
		SRPM=$(find /usr/src/akmods \
			-maxdepth 1 \
			-type f \
			-name "${MODULE}-*.src.rpm" \
			-print \
			-quit)

		if [ -z "${SRPM}" ]; then
			echo "Missing akmod source RPM for ${MODULE}"
			exit 1
		fi

		echo "Building ${MODULE} for ${KVER}"

		su -s /bin/bash akmods -c \
			"cd /var/lib/akmods && HOME=/var/lib/akmods akmodsbuild --target ${ARCH} --kernels ${KVER} ${SRPM}"
	done


	# -----------------------------------------------------------------------
	# Install compiled modules
	# -----------------------------------------------------------------------

	dnf install -y \
		/var/lib/akmods/kmod-slimbook-qc71-${KVER}-*.rpm \
		/var/lib/akmods/kmod-slimbook-yt6801-${KVER}-*.rpm


	# -----------------------------------------------------------------------
	# Validate modules
	# -----------------------------------------------------------------------

	MODULE_DIR="/usr/lib/modules/${KVER}"

	test -d "${MODULE_DIR}"

	QC71_MODULE=$(find "${MODULE_DIR}" \
		-type f \
		-name '*qc71*.ko*' \
		-print \
		-quit)

	YT6801_MODULE=$(find "${MODULE_DIR}" \
		-type f \
		-name '*yt6801*.ko*' \
		-print \
		-quit)

	if [ -z "${QC71_MODULE}" ]; then
		echo "qc71 kernel module not found"
		exit 1
	fi

	if [ -z "${YT6801_MODULE}" ]; then
		echo "yt6801 kernel module not found"
		exit 1
	fi

	echo "qc71 module:  ${QC71_MODULE}"
	echo "yt6801 module: ${YT6801_MODULE}"


	# -----------------------------------------------------------------------
	# Cleanup
	# -----------------------------------------------------------------------

	dnf remove -y kernel-devel
	dnf clean all

	rm -rf /var/lib/akmods/*

	# kernel-devel must not remain in the final image.
	if rpm -q "kernel-devel-${KVER}" >/dev/null 2>&1; then
		echo "kernel-devel unexpectedly remains installed"
		exit 1
	fi

	echo "Slimbook hardware layer successfully built."
EOF


# ---------------------------------------------------------------------------
# Branding
# ---------------------------------------------------------------------------

ARG SLIMBOOK_DIGEST=unknown

RUN <<-EOF
	set -eux

	CURRENT_VERSION=$(grep '^VERSION=' /usr/lib/os-release | cut -d'"' -f2)
	SLIMBOOK_SHORT=$(printf '%s' "${SLIMBOOK_DIGEST}" | cut -c1-12)

	NEW_VERSION="${CURRENT_VERSION} + Slimbook ${SLIMBOOK_SHORT}"

	sed -i 's/^NAME=.*/NAME="Bluefin DX Slimbook"/' /usr/lib/os-release
	sed -i "s/^VERSION=.*/VERSION=\"${NEW_VERSION}\"/" /usr/lib/os-release
	sed -i "s/^PRETTY_NAME=.*/PRETTY_NAME=\"Bluefin DX Slimbook (${NEW_VERSION})\"/" /usr/lib/os-release
	sed -i 's/^VARIANT_ID=.*/VARIANT_ID=bluefin-dx-slimbook/' /usr/lib/os-release
	sed -i 's|^HOME_URL=.*|HOME_URL="https://github.com/klprv/bluefin-dx-slimbook"|' /usr/lib/os-release
EOF


RUN ostree container commit
