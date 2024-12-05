# Maintainer: Frédéric Pierret <frederic.pierret@qubes-os.org>

EAPI=7

PYTHON_COMPAT=( python3_{10..13} )

inherit git-r3 multilib distutils-r1 qubes

if [[ ${PV} == *9999 ]]; then
	EGIT_COMMIT=HEAD
else
	EGIT_COMMIT="v${PV}"
fi

EGIT_REPO_URI="https://github.com/QubesOS/qubes-core-agent-linux.git"

KEYWORDS="amd64"
DESCRIPTION="The Qubes core files for installation inside a Qubes VM"
HOMEPAGE="http://www.qubes-os.org"
LICENSE="GPL-2"

SLOT="0"
IUSE="nautilus networking network-manager passwordless-root pandoc-bin"

DEPEND="app-emulation/qubes-libvchan-xen
        app-emulation/qubes-db
        app-emulation/qubes-utils
        net-misc/socat
        x11-misc/notification-daemon
        x11-misc/xdg-utils
        sys-apps/gentoo-systemd-integration
        gnome-extra/zenity
        pandoc-bin? (
            app-text/pandoc-bin
        )
        !pandoc-bin? (
            app-text/pandoc
        )
        networking? (
            sys-apps/ethtool
            sys-apps/net-tools
            net-firewall/iptables
            net-proxy/tinyproxy

            network-manager? (
                net-misc/networkmanager
                net-firewall/nftables
            )
        )
        nautilus? (
            dev-python/nautilus-python
        )
        ${PYTHON_DEPS}
        "
RDEPEND="${DEPEND}"
PDEPEND=""

src_prepare() {
    qubes_verify_sources_git "${EGIT_COMMIT}"

    default
}

src_compile() {
    # Fix PAM
    sed -i 's/postlogin/system-auth/g' passwordless-root/pam.d_su.qubes

    # Fix modules-load.d path
    sed -i 's|$(SYSLIBDIR)/modules-load.d|$(LIBDIR)/modules-load.d|g' Makefile

    # Fix for network tools paths
    sed -i 's:/sbin/ifconfig:/bin/ifconfig:g' network/*
    sed -i 's:/sbin/route:/bin/route:g' network/*
    sed -i 's:/sbin/ethtool:/usr/sbin/ethtool:g' network/*
    sed -i 's:/sbin/ip:/bin/ip:g' network/*

    myopt="${myopt} DESTDIR="${D}" SYSTEMD=1 BACKEND_VMM=xen"
    for dir in qubes-rpc misc; do
        emake ${myopt} -C "$dir"
    done
}

src_install() {
    emake ${myopt} install-corevm
    emake ${myopt} -C app-menu install
    emake ${myopt} -C filesystem install
    emake ${myopt} -C misc install
    emake ${myopt} -C qubes-rpc install
    emake ${myopt} -C package-managers install
    if use passwordless-root; then
        emake ${myopt} -C passwordless-root install
    fi
    if use nautilus; then
        emake ${myopt} -C qubes-rpc/nautilus install
    fi

    if use networking; then
        if use network-manager; then
            emake ${myopt} install-netvm
        fi
        emake ${myopt} -C network install
        emake ${myopt} install-networking
    fi

    insopts -m 0644
    insinto /usr/lib/systemd/system/
    doins "${FILESDIR}"/qubes-ensure-lib-modules.service

    # Remove things unwanted in Gentoo
    ${myopt} rm -r "$DESTDIR/etc/yum"*
    ${myopt} rm -r "$DESTDIR/etc/dnf"*
    ${myopt} rm -r "$DESTDIR/etc/init.d"
}

pkg_preinst() {
    update_default_user

    mkdir -p /var/lib/qubes

    if [ -e /etc/fstab ]; then
        mv /etc/fstab /var/lib/qubes/fstab.orig
    fi

    usermod -L root
    usermod -L user
}

pkg_postinst() {
    update_qubesconfig

    mkdir -p /usr/lib/modules
    ln -sf /usr/lib/modules /lib/
    systemctl enable qubes-ensure-lib-modules.service

    if [ -e /etc/init/serial.conf ] && ! [ -f /var/lib/qubes/serial.orig ]; then
        cp /etc/init/serial.conf /var/lib/qubes/serial.orig
    fi

    # Remove most of the udev scripts to speed up the VM boot time
    # Just leave the xen* scripts, that are needed if this VM was
    # ever used as a net backend (e.g. as a VPN domain in the future)
    mkdir -p /var/lib/qubes/removed-udev-scripts
    for f in /etc/udev/rules.d/*
    do
        if [ "$(basename "$f")" == "xen-backend.rules" ]; then
            continue
        fi

        if echo "$f" | grep -q qubes; then
            continue
        fi

        mv "$f" /var/lib/qubes/removed-udev-scripts/
    done

    mkdir -p /var/lib/qubes/removed-modules-load.d/
    if [ -e /usr/lib/modules-load.d/xen.conf ]; then
        mv /usr/lib/modules-load.d/xen.conf /var/lib/qubes/removed-modules-load.d/
    fi

    if [ -e /var/lib/qubes/dom0-updates ]; then
        chgrp user /var/lib/qubes/dom0-updates
    fi

    mkdir -p /rw

    configure_notification_daemon
    configure_selinux
    configure_systemd 1

    if use networking; then
        if use network-manager; then
            systemctl enable qubes-network.service
            systemctl enable qubes-firewall.service
            systemctl enable qubes-iptables.service
            systemctl enable qubes-updates-proxy.service

            # Create NetworkManager configuration if we do not have it
            if ! [ -e /etc/NetworkManager/NetworkManager.conf ]; then
                echo '[main]' > /etc/NetworkManager/NetworkManager.conf
                echo 'plugins = keyfile' >> /etc/NetworkManager/NetworkManager.conf
                echo '[keyfile]' >> /etc/NetworkManager/NetworkManager.conf
            fi

            /usr/lib/qubes/qubes-fix-nm-conf.sh
        fi
    fi
}

pkg_prerm() {
    systemctl disable qubes-ensure-lib-modules.service

    if [ -e /var/lib/qubes/fstab.orig ]; then
        mv /var/lib/qubes/fstab.orig /etc/fstab
    fi

    for f in /var/lib/qubes/removed-udev-scripts/*
    do
        mv /var/lib/qubes/removed-udev-scripts/"$f" /etc/udev/rules.d/
    done

    if [ -e /var/lib/qubes/removed-modules-load.d/xen.conf ]; then
        mv /var/lib/qubes/removed-modules-load.d/xen.conf /usr/lib/modules-load.d/xen.conf
    fi

    if [ -e /var/lib/qubes/serial.orig ]; then
        mv /var/lib/qubes/serial.orig /etc/init/serial.conf
    fi

    # Run this only during uninstall.
    # Save the preset file to later use it to re-preset services there
    # once the Qubes OS preset file is removed.
    mkdir -p /run/qubes-uninstall
    cp -f /lib/systemd/system-preset/75-qubes-vm.preset /run/qubes-uninstall/

    if use networking; then
        if use network-manager; then
            systemctl disable qubes-network.service
            systemctl disable qubes-firewall.service
            systemctl disable qubes-iptables.service
            systemctl disable qubes-updates-proxy.service
        fi
    fi
}

pkg_postrm() {
    changed=

    if [ -d /run/qubes-uninstall ]; then
        # We have a saved preset file (or more).
        # Re-preset the units mentioned there.
        restore_units /run/qubes-uninstall/75-qubes-vm.preset
        rm -rf /run/qubes-uninstall
        changed=true
    fi

    if [ -n "$changed" ]; then
        systemctl daemon-reload
    fi

    if [ -L /lib/firmware/updates ]; then
      rm /lib/firmware/updates
    fi

    rm -rf /var/lib/qubes/xdg

    for srv in qubes-sysinit qubes-misc-post qubes-mount-dirs; do
        systemctl disable $srv.service
    done
}

###

update_default_user() {
    # Make sure there is a qubes group
    groupadd --force --system --gid 98 qubes

    id -u 'user' >/dev/null 2>&1 || {
        useradd --user-group --create-home --shell /bin/bash user
    }

    usermod -a --groups qubes user
}

configure_notification_daemon() {
    # Enable autostart of notification-daemon when installed
    if [ ! -L /etc/xdg/autostart/notification-daemon.desktop ]; then
        ln -sf /usr/share/applications/notification-daemon.desktop /etc/xdg/autostart/
    fi
}

configure_selinux() {
    if [ -e /etc/selinux/config ]; then
        sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
        setenforce 0 2>/dev/null
    fi
}

update_qubesconfig() {
    # Remove old firmware updates link
    if [ -L /lib/firmware/updates ]; then
      rm -f /lib/firmware/updates
    fi

    # convert /usr/local symlink to a mount point
    if [ -L /usr/local ]; then
        rm -f /usr/local
        mkdir /usr/local
        mount /usr/local || :
    fi

    if ! [ -r /etc/dconf/profile/user ]; then
        mkdir -p /etc/dconf/profile
        echo "user-db:user" >> /etc/dconf/profile/user
        echo "system-db:local" >> /etc/dconf/profile/user
    fi

    dconf update &> /dev/null || :

    # Location of files which contains list of protected files
    mkdir -p /etc/qubes/protected-files.d
    # shellcheck source=init/functions
    . /usr/lib/qubes/init/functions

    # qubes-core-vm has been broken for some time - it overrides /etc/hosts; restore original content
    if ! is_protected_file /etc/hosts; then
        if ! grep -q localhost /etc/hosts; then

          cat <<EOF > /etc/hosts
127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4 $(hostname)
::1         localhost localhost.localdomain localhost6 localhost6.localdomain6
EOF

        fi
    fi

    # ensure that hostname resolves to 127.0.0.1 resp. ::1 and that /etc/hosts is
    # in the form expected by qubes-sysinit.sh
    if ! is_protected_file /etc/hostname; then
        for ip in '127\.0\.0\.1' '::1'; do
            if grep -q "^${ip}\(\s\|$\)" /etc/hosts; then
                sed -i "/^${ip}\s/,+0s/\(\s$(hostname)\)\+\(\s\|$\)/\2/g" /etc/hosts
                sed -i "s/^${ip}\(\s\|$\).*$/\0 $(hostname)/" /etc/hosts
            else
                echo "${ip} $(hostname)" >> /etc/hosts
            fi
        done
    fi

}

is_static() {
    [ -f "/usr/lib/systemd/system/$1" ] && ! grep -q '^[[].nstall]' "/usr/lib/systemd/system/$1"
}

is_masked() {
    if [ ! -L /etc/systemd/system/"$1" ]; then
        return 1
    fi
    target=$(readlink /etc/systemd/system/"$1" 2>/dev/null) || :
    if [ "$target" = "/dev/null" ]; then
        return 0
    fi
    return 1
}

mask() {
    ln -sf /dev/null /etc/systemd/system/"$1"
}

unmask() {
    if ! is_masked "$1"; then
        return 0
    fi
    rm -f /etc/systemd/system/"$1"
}

preset_units() {
    local represet=
    while read -r action unit_name
    do
        if [ "$action" = "#" ] && [ "$unit_name" = "Units below this line will be re-preset on package upgrade" ]; then
            represet=1
            continue
        fi
        echo "$action $unit_name" | grep -q '^[[:space:]]*[^#;]' || continue
        [[ -n "$action" && -n "$unit_name" ]] || continue
        if [ "$2" = "initial" ] || [ "$represet" = "1" ]; then
            if [ "$action" = "disable" ] && is_static "$unit_name"; then
                if ! is_masked "$unit_name"; then
                    # We must effectively mask these units, even if they are static.
                    mask "$unit_name"
                fi
            elif [ "$action" = "enable" ] && is_static "$unit_name"; then
                if is_masked "$unit_name"; then
                    # We masked this static unit before, now we unmask it.
                    unmask "$unit_name"
                fi
                systemctl --no-reload preset "$unit_name" >/dev/null 2>&1 || :
            else
                systemctl --no-reload preset "$unit_name" >/dev/null 2>&1 || :
            fi
        fi
    done < "$1"
}

restore_units() {
    grep '^[[:space:]]*[^#;]' "$1" | while read -r action unit_name
    do
        if is_static "$unit_name" && is_masked "$unit_name"; then
            # If the unit had been masked by us, we must unmask it here.
            # Otherwise systemctl preset will fail badly.
            unmask "$unit_name"
        fi
        systemctl --no-reload preset "$unit_name" >/dev/null 2>&1 || :
    done
}

configure_systemd() {
    if [ "$1" -eq 1 ]; then
        preset_units /lib/systemd/system-preset/75-qubes-vm.preset initial
        changed=true
    else
        preset_units /lib/systemd/system-preset/75-qubes-vm.preset upgrade
        changed=true
        # Upgrade path - now qubes-iptables is used instead
        for svc in iptables ip6tables
        do
            if [ -f "$svc".service ]; then
                systemctl --no-reload preset "$svc".service
                changed=true
            fi
        done
    fi

    if [ "$1" -eq 1 ]; then
        # First install.
        # Set default "runlevel".
        # FIXME: this ought to be done via kernel command line.
        # The fewer deviations of the template from the seed
        # image, the better.
        rm -f /etc/systemd/system/default.target
        ln -sf /lib/systemd/system/multi-user.target /etc/systemd/system/default.target
        changed=true
    fi

    # remove old symlinks
    if [ -L /etc/systemd/system/sysinit.target.wants/qubes-random-seed.service ]; then
        rm -f /etc/systemd/system/sysinit.target.wants/qubes-random-seed.service
        changed=true
    fi
    if [ -L /etc/systemd/system/multi-user.target.wants/qubes-mount-home.service ]; then
        rm -f /etc/systemd/system/multi-user.target.wants/qubes-mount-home.service
        changed=true
    fi

    if [ -n "$changed" ]; then
        systemctl daemon-reload
    fi
}
