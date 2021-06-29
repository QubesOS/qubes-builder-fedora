#!/bin/bash -e
# vim: set ts=4 sw=4 sts=4 et :

source ./functions.sh >/dev/null
source ./umount_kill.sh >/dev/null

output "${bold}${under}INFO: ${SCRIPTSDIR}/distribution.sh imported by: ${0}${reset}"

if [ -n "${REPO_PROXY}" ]; then
    YUM_OPTS="$YUM_OPTS --setopt=proxy=${REPO_PROXY}"
fi

YUM=dnf

if [ "${DIST#fc}" != "${DIST}" ]; then
    DISTRIBUTION="fedora"
    DIST_VER="${DIST#fc}"

    if [ -n "${FEDORA_MIRROR}" ]; then
        YUM_OPTS="$YUM_OPTS --setopt=fedora.baseurl=${FEDORA_MIRROR%/}/releases/${DIST_VER}/Everything/x86_64/os/"
        YUM_OPTS="$YUM_OPTS --setopt=updates.baseurl=${FEDORA_MIRROR%/}/updates/${DIST_VER}/Everything/x86_64/"
    fi
fi

if [ "${DIST#centos}" != "${DIST}" ]; then
    DISTRIBUTION="centos"
    DIST_VER="${DIST#centos}"

    if [ "${DIST_VER}" -ge 8 ]; then
        YUM_OPTS="$YUM_OPTS --nobest"
    fi

    if [ -n "${CENTOS_MIRROR}" ]; then
        YUM_OPTS="$YUM_OPTS --setopt=base.baseurl=${CENTOS_MIRROR%/}/${DIST_VER}/os/x86_64"
        YUM_OPTS="$YUM_OPTS --setopt=updates.baseurl=${CENTOS_MIRROR%/}/${DIST_VER}/updates/x86_64"
        YUM_OPTS="$YUM_OPTS --setopt=extras.baseurl=${CENTOS_MIRROR%/}/${DIST_VER}/extras/x86_64"
    fi

    if [ -n "${EPEL_MIRROR}" ]; then
        YUM_OPTS="$YUM_OPTS --setopt=epel.baseurl=${EPEL_MIRROR%/}/${DIST_VER}/x86_64"
    fi
fi

if [ "$DIST" == "tumbleweed" ] || [ "$DIST" == "leap" ]; then
    DISTRIBUTION="opensuse"
    DIST_VER="$DIST"

    YUM_OPTS="$YUM_OPTS --releasever=$DIST_VER --exclude=busybox*"
fi


# ==============================================================================
# Cleanup function
# ==============================================================================
function cleanup() {
    errval=$?
    trap - ERR EXIT
    trap
    error "${1:-"${0}: Error.  Cleaning up and un-mounting any existing mounts"}"
    umount_kill "${INSTALLDIR}" || true

    exit $errval
}

# ==============================================================================
# Create system mount points
# ==============================================================================
function prepareChroot() {
    info "--> Preparing environment..."
    mount -t proc proc "${INSTALLDIR}/proc"

    chroot "${INSTALLDIR}" ln -nsf /proc/self/fd /dev/fd
    chroot "${INSTALLDIR}" ln -nsf /proc/self/fd/0 /dev/stdin
    chroot "${INSTALLDIR}" ln -nsf /proc/self/fd/1 /dev/stdout
    chroot "${INSTALLDIR}" ln -snf /proc/self/fd/2 /dev/stderr
}

# Enable / disable repository
function yumConfigRepository() {
    local op=$1
    local repo=$2

    if [ "$YUM" = "dnf" ]; then
        chroot_cmd dnf config-manager --set-${op}d $repo
    else
        chroot_cmd yum-config-manager --${op} $repo
    fi
}

# ==============================================================================
# Yum install package(s)
# ==============================================================================
function yumInstall() {
    declare -a files
    files=("$@")
    mount --bind /etc/resolv.conf "${INSTALLDIR}/etc/resolv.conf"
    if [ "$YUM" = "dnf" ]; then
        mkdir -p "${INSTALLDIR}/var/lib/dnf"
    fi
    if [ "${DISTRIBUTION}" = "opensuse" ]; then
        chmod 4755 "${INSTALLDIR}/usr/bin/mount"
        chmod 4755 "${INSTALLDIR}/usr/bin/umount"
        chmod 2755 "${INSTALLDIR}/usr/bin/wall"
        chmod 2755 "${INSTALLDIR}/usr/bin/write"
        chmod 4755 "${INSTALLDIR}/usr/bin/su"
    fi
    mkdir -p "${INSTALLDIR}/tmp/template-builder-repo"
    mount --bind pkgs-for-template "${INSTALLDIR}/tmp/template-builder-repo"
    if [ -e "${INSTALLDIR}/usr/bin/$YUM" ]; then
        mkdir -p "${INSTALLDIR}/etc/yum.repos.d"
        cp ${SCRIPTSDIR}/template-builder-repo-$DISTRIBUTION.repo "${INSTALLDIR}/etc/yum.repos.d/"
        if [ "${DISTRIBUTION}" == "opensuse" ]; then
            sed -i "s/opensuse/$DIST/" "${INSTALLDIR}/etc/yum.repos.d/template-builder-repo-$DISTRIBUTION.repo"
        fi
        chroot_cmd $YUM --downloadonly \
            install ${YUM_OPTS} -y "${files[@]}" || exit 1
        find "${INSTALLDIR}/var/cache/dnf" -name '*.rpm' -print0 | xargs -r0 sha256sum
        find "${INSTALLDIR}/var/cache/yum" -name '*.rpm' -print0 | xargs -r0 sha256sum
        if [ "$DISTRIBUTION" != "centos7" ]; then
            # set http proxy to invalid one, to prevent any connection in case of
            # --cacheonly being buggy: better fail the build than install something
            # else than the logged one
            chroot_cmd $YUM install ${YUM_OPTS} -y \
                --cacheonly --setopt=proxy=http://127.0.0.1:1/ "${files[@]}" || exit 1
        else
            # Temporarly disable previous strategy (problem with downloading cache qubes template repo)
            chroot_cmd $YUM install ${YUM_OPTS} -y "${files[@]}" || exit 1
        fi
        rm -f "${INSTALLDIR}/etc/yum.repos.d/template-builder-repo-$DISTRIBUTION.repo"
    else
        echo "$YUM not installed in $INSTALLDIR, exiting!"
        exit 1
    fi
    umount "${INSTALLDIR}/etc/resolv.conf"
    umount "${INSTALLDIR}/tmp/template-builder-repo"
}

# ==============================================================================
# Yum install group(s)
# ==============================================================================
function yumGroupInstall() {
    local optional=
    if [ "$1" = "with-optional" ]; then
        optional=with-optional
        shift
    fi
    declare -a files
    files=("$@")
    mount --bind /etc/resolv.conf "${INSTALLDIR}/etc/resolv.conf"
    if [ "$YUM" = "dnf" ]; then
        mkdir -p "${INSTALLDIR}/var/lib/dnf"
    else
        optional=--setopt=group_package_types=mandatory,default,optional
    fi
    mkdir -p "${INSTALLDIR}/tmp/template-builder-repo"
    mount --bind pkgs-for-template "${INSTALLDIR}/tmp/template-builder-repo"
    if [ -e "${INSTALLDIR}/usr/bin/$YUM" ]; then
        chroot_cmd $YUM clean expire-cache
        chroot_cmd $YUM --downloadonly \
            group install $optional ${YUM_OPTS} -y "${files[@]}" || exit 1
        find "${INSTALLDIR}/var/cache/dnf" -name '*.rpm' -print0 | xargs -r0 sha256sum
        find "${INSTALLDIR}/var/cache/yum" -name '*.rpm' -print0 | xargs -r0 sha256sum
        if [ "${DIST}" != "centos7" ]; then
            # set http proxy to invalid one, to prevent any connection in case of
            # --cacheonly being buggy: better fail the build than install something
            # else than the logged one
            chroot_cmd $YUM install ${YUM_OPTS} -y \
                --cacheonly --setopt=proxy=http://127.0.0.1:1/ "${files[@]}" || exit 1
        else
            # Temporarly disable previous strategy (problem with downloading cache qubes template repo)
            chroot_cmd $YUM install ${YUM_OPTS} -y "${files[@]}" || exit 1
        fi
    else
        echo "$YUM not installed in $INSTALLDIR, exiting!"
        exit 1
    fi
    umount "${INSTALLDIR}/etc/resolv.conf"
    umount "${INSTALLDIR}/tmp/template-builder-repo"
}

# ==============================================================================
# Yum update
# ==============================================================================
function yumUpdate() {
    declare -a files
    files=("$@")
    mount --bind /etc/resolv.conf ${INSTALLDIR}/etc/resolv.conf
    if [ "$YUM" = "dnf" ]; then
        mkdir -p ${INSTALLDIR}/var/lib/dnf
    fi
    mkdir -p ${INSTALLDIR}/tmp/template-builder-repo
    mount --bind pkgs-for-template ${INSTALLDIR}/tmp/template-builder-repo
    if [ -e "${INSTALLDIR}/usr/bin/$YUM" ]; then
        cp ${SCRIPTSDIR}/template-builder-repo-$DISTRIBUTION.repo ${INSTALLDIR}/etc/yum.repos.d/
        if [ "${DISTRIBUTION}" == "opensuse" ]; then
            sed -i "s/opensuse/$DIST/" "${INSTALLDIR}/etc/yum.repos.d/template-builder-repo-$DISTRIBUTION.repo"
        fi
        chroot_cmd $YUM --downloadonly \
            update ${YUM_OPTS} -y "${files[@]}" || exit 1
        find ${INSTALLDIR}/var/cache/dnf -name '*.rpm' -print0 | xargs -r0 sha256sum
        find ${INSTALLDIR}/var/cache/yum -name '*.rpm' -print0 | xargs -r0 sha256sum
        # set http proxy to invalid one, to prevent any connection in case of
        # --cacheonly being buggy: better fail the build than install something
        # else than the logged one
        chroot_cmd $YUM update ${YUM_OPTS} -y \
            --cacheonly --setopt=proxy=http://127.0.0.1:1/ "${files[@]}" || exit 1
        rm -f ${INSTALLDIR}/etc/yum.repos.d/template-builder-repo-$DISTRIBUTION.repo
    else
        echo "$YUM not installed in $INSTALLDIR, exiting!"
        exit 1
    fi
    umount ${INSTALLDIR}/etc/resolv.conf
    umount ${INSTALLDIR}/tmp/template-builder-repo
}
# ==============================================================================
# Verify RPM packages
# ==============================================================================
function verifyPackages() {
    for file in $@; do
        result=$(rpm --root="${INSTALLDIR}" --checksig "${file}") || {
            echo "Filename: ${file} failed verification.  Exiting!"
            exit 1
        }
        result_status="${result##*:}"
        echo "${result_status}" | grep -q 'PGP' && {
            echo "Filename: ${file} contains an invalid PGP signature.  Exiting!"
            exit 1
        }
        echo "${result_status}" | grep -q 'pgp' || {
            echo "Filename: ${file} is not signed.  Exiting!"
            exit 1
        }
    done
    sha256sum "$@"

    return 0
}

# ==============================================================================
# Install extra packages in script_${DIST}/packages.list file
# -and / or- TEMPLATE_FLAVOR directories
# ==============================================================================
function installPackages() {
    if [ -n "${1}" ]; then
        # Locate packages within sub dirs
        if [ ${#@} == "1" ]; then
            getFileLocations packages_list "${1}" ""
        else
            packages_list="$@"
        fi
    else
        # WIP: should be improuved for multiple patterns search
        if [ -n "$TEMPLATE_FLAVOR" ]; then
            getFileLocations packages_list "packages.list" "${DIST}_${TEMPLATE_FLAVOR}"
            if [ -z "${packages_list}" ]; then
                getFileLocations packages_list "packages.list" "${DISTRIBUTION}_${TEMPLATE_FLAVOR}"
            fi
        else
            getFileLocations packages_list "packages.list" "${DIST}"
            if [ -z "${packages_list}" ]; then
                getFileLocations packages_list "packages.list" "${DISTRIBUTION}"
            fi
        fi
        if [ -z "${packages_list}" ]; then
            error "Can not locate a package.list file!"
            umount_all || true
            exit 1
        fi
    fi

    for package_list in ${packages_list[@]}; do
        debug "Installing extra packages from: ${package_list}"
        declare -a packages
        readarray -t packages < "${package_list}"

        info "Packages: "${packages[@]}""
        yumInstall "${packages[@]}" || return $?
    done
}

# ==============================================================================
# Enable or Disable Copr Fedora repositories
# ==============================================================================
function yumCopr() {
    mount --bind /etc/resolv.conf ${INSTALLDIR}/etc/resolv.conf
    local op=$1
    local repo=$2

    chroot_cmd $YUM copr ${op} -y $repo
    umount ${INSTALLDIR}/etc/resolv.conf
}
