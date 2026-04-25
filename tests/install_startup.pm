# The Qubes OS Project, https://www.qubes-os.org/
#
# Copyright (C) 2018 Marek Marczykowski-Górecki <marmarek@invisiblethingslab.com>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

use base 'basetest';
use strict;
use testapi;
use bootloader_setup;
use serial_terminal qw(select_root_console);
use utils qw(assert_fuzzy_serial assert_serial);

sub run {
    pre_bootmenu_setup();

    if (check_var('BACKEND', 'qemu')) {
        if (check_var('UEFI', '1')) {
            if (check_var('UEFI_DIRECT', '1')) {
                # grub2-efi can't load xen.efi on OVMF...
                # default direct xen.efi boot is also broken on OVMF - see below
                tianocore_select_bootloader();
                send_key_until_needlematch('tianocore-menu-efi-shell', 'up', 5, 5);
                send_key 'ret';
                send_key 'esc';
                type_string "fs0:\n";
                # in direct UEFI boot we enable /mapbs workaround, which crashes dom0
                # under OVMF - choose different boot option than default (qubes-verbose)
                type_string "EFI\\BOOT\\BOOTX64.efi qubes\n";
            } else {
                assert_screen 'bootloader', 30;
                if (check_var('KERNEL_VERSION', 'latest')) {
                    # verbose
                    send_key 'down';
                    # rescue
                    send_key 'down';
                    # kernel latest
                    send_key 'down';
                } else {
                    send_key 'up';
                }
                # press enter to boot right away
                send_key 'ret';
            }
        } else {
            # wait for bootloader to appear
            assert_screen 'bootloader', 30;

            # skip media verification
            if (check_var('KERNEL_VERSION', 'latest')) {
                if (check_var('VERSION', '4.1')) {
                    # isolinux menu
                    # troubleshooting
                    send_key 'down';
                    send_key 'ret';
                    assert_screen 'bootloader-troubleshooting';
                    # kernel latest
                    send_key 'down';
                } else {
                    # grub menu
                    # verbose
                    send_key 'down';
                    # rescue
                    send_key 'down';
                    # kernel latest
                    send_key 'down';
                }
            } else {
                send_key 'up';
            }

            # press enter to boot right away
            send_key 'ret';
        }
    } elsif (check_var('HEADS', '1')) {
        heads_boot_usb;
    } elsif ((check_var('MACHINE', 'optiplex') and check_var('OS_INSTALL_LEGACY', '1')) or
             (check_var('MACHINE', 'vp4670') and check_var('OS_INSTALL_LEGACY', '1'))) {
        seabios_boot();
    } elsif (check_var('MACHINE', 'vp4670') or check_var('MACHINE', 'optiplex')) {
        my $ks_url = prepare_kickstart_config();
        my $params = "inst.sshd inst.ks=$ks_url";

        # VP4670 has multiple network controllers, only use the first one
        if (check_var('MACHINE', 'vp4670')) {
            my $device_ip = get_var('QUBES_OS_HOST_IP');
            $params .= " ip=${device_ip}::192.168.10.1:255.255.255.0::enp1s0 bootdev=enp1s0";
        }

        # Enter boot manager menu
        assert_serial "to boot directly";
        # No harm in pressing all the buttons, as long as it isn't setup menu,
        # esc or return.
        send_key "f11";  # vp4670
        send_key "f12";  # optiplex

        # Select drive connected by PiKVM
        assert_serial 'select boot device';
        # Entries depend on type of drive (flash or CD), they are either
        # 'PiKVM Composite KVM Device' or 'PiKVM CD-ROM Drive XXXX', so needle
        # is set to match just `PiKVM C`.
        send_key_until_needlematch('dasharo_pikvm_bootdev', 'down');
        send_key 'ret';

        assert_screen 'bootloader-installer';
        grub_boot_with_kernel_parameters($params);
    } elsif (check_var('MACHINE', 'nuc-box')) {
        my $ks_url = prepare_kickstart_config();

        # Workarounds for the platform-specific issues described in
        # [its README](../generalhw/nuc-box/README.md)
        my $params = "inst.ks=$ks_url i915.force_probe=7dd5 nvme_core.default_ps_max_latency_us=0 pcie_aspm=off pcie_port_pm=off";

        my $ipxe_url = prepare_ipxe_script($params);

        # Entering the boot manager menu directly doesn't work. For this reason
        # it's needed to enter the Dasharo UI and select One Time Boot instead.
        # Furthermore, merely pressing F2 once won't work - continuous presses
        # are needed, otherwise the input might not get recognized.
        assert_serial "to boot directly";
        for (my $i = 0; $i < 30; $i++) {
            send_key 'f2';
        }
        assert_screen 'nuc_box_booted_to_dasharo_ui', 30;
        send_key_until_needlematch('nuc_box_dasharo_ui_selected_one_time_boot', 'down');
        send_key 'ret';
        send_key_until_needlematch('nuc_box_dasharo_ui_chosen_ipxe_one_time_boot', 'down');
        send_key 'ret';

        ipxe_boot('dasharo', $ipxe_url);
    } elsif (check_var('MACHINE', 'supermicro')) {
        # FIXME: use per-worker URLs, don't pollute global ones
        # http://<openqa-ip>:8080/iso/     -- mounted ISO image
        # http://<openqa-ip>:8080/ipxe     -- iPXE script
        # http://<openqa-ip>:8080/ks.cfg   -- KickStart configuration file
        #
        # grub-mixed.img image connected to PiKVM.  TODO: automate via API.

        my $menu_title = 'Please select boot device:';
        # spaces are intentional to no pick up UEFI entry (could also use regexp for wait_serial)
        my $entry_text = 'PiKVM CD-ROM Drive \d{4}    ';

        my $menu = undef;
        for my $i (0 .. 45) {
            send_key 'f11';
            $menu = wait_serial($entry_text, 1);
            if (defined $menu) {
                last;
            }
        }

        if (!defined $menu) {
            die "Failed to find menu containing CSM PiKVM entry";
        }

        # splitting by bars instead of newlines because there are no newlines
        # in the menu drawn via escape sequences
        my @menu_parts = split '\|', $menu;

        my $menu_top = 0;
        while ($menu_parts[$menu_top] !~ $menu_title) {
            ++$menu_top;
        }

        my $pikvm_entry = $menu_top + 1;
        while ($menu_parts[$pikvm_entry] !~ $entry_text) {
            ++$pikvm_entry;
        }

        # it's `+ 4` and `+= 2` because each menu line contains 2 bars
        for (my $i = $menu_top + 4; $i < $pikvm_entry; $i += 2) {
            send_key 'down';
        }
        send_key 'ret';

        # GRUB2 should be booting from iPXE automatically.
    } elsif (check_var('MACHINE', 'supermicro')) { # EFI version, saved for later, never gets executed
        # FIXME: use per-worker URLs, don't pollute global ones
        # http://<openqa-ip>:8080/iso/     -- mounted ISO image
        # http://<openqa-ip>:8080/ipxe     -- iPXE script
        # http://<openqa-ip>:8080/ks.cfg   -- KickStart configuration file

        my $openqa_url = get_var('QUBES_OS_OPENQA_URL');

        for my $i (0 .. 45) {
            send_key 'f11';
            if (wait_serial('select boot device', 1)) {
                last;
            }
        }
        send_key 'down';
        send_key 'ret';

        assert_serial "Shell>", 30;
        type_string "fs0:\n";
        wait_serial "FS0:", 30;
        type_string "efi\\boot\\ipxe.efi dhcp && chain $openqa_url/ipxe\n";
    } elsif (check_var('MACHINE', 'hpt630v1') or check_var('MACHINE', 'hpt630v2')) {
        my $ks_url = prepare_kickstart_config();
        assert_screen 'hp_post_delay';
        # For legacy, it isn't enough to choose proper boot medium for the
        # installer, because on next boot platform would attempt booting UEFI
        # first, which would land in UEFI installer. To make it work, we could
        # either remove the installer medium (on PiKVM) or disable UEFI booting.
        # Of course, it must be re-enabled for UEFI installation.
        send_key 'f10';
        # the landing menu
        assert_screen 'hp_setup_file';
        # Storage -> Boot Order
        send_key 'right';
        send_key 'up';
        send_key 'ret';
        # checks 'Legacy Boot Sources' too, they may be disabled in Secure Boot
        assert_screen 'hp_bootorder';

        if (check_var('OS_INSTALL_LEGACY', '0')) {
            send_key_until_needlematch('hp_uefi_enabled', 'f5');
        } elsif (check_var('OS_INSTALL_LEGACY', '1')) {
            send_key_until_needlematch('hp_uefi_disabled', 'f5');
        } else {
            die "OS_INSTALL_LEGACY not set";
        }
        send_key 'f10';  # accept boot order settings

        # now make USB storage be booted after SATA
        send_key 'up';
        send_key 'up';
        send_key 'ret';
        assert_screen 'hp_setup_storage';
        send_key 'down';
        send_key_until_needlematch('hp_usb_after_sata', 'right');
        send_key 'f10';  # accept storage options

        # save and reboot
        send_key 'f10';  # selects 'Save Changes and Exit'
        send_key 'ret';
        assert_screen 'hp_setup_save_and_exit_confirmation';
        # confirm save and exit
        send_key 'left';
        send_key 'ret';

        # now select the installer
        assert_screen 'hp_post_delay';
        send_key 'f9';
        assert_screen 'hp_bootdev_sel';

        if (check_var('OS_INSTALL_LEGACY', '0')) {
            send_key_until_needlematch('hp_uefi_pikvm_drive', 'down');
            send_key 'ret';
        } elsif (check_var('OS_INSTALL_LEGACY', '1')) {
            send_key_until_needlematch('hp_pikvm_drive', 'down');
            send_key 'ret';
        }

        assert_screen 'bootloader-installer', 30;

        grub_boot_with_kernel_parameters("inst.sshd inst.ks=$ks_url");
    } elsif (!check_var('QUBES_OS_KS_URL', '')) {
        # wait for bootloader to appear
        my $ks_url = get_var('QUBES_OS_KS_URL');
        assert_screen 'bootloader-installer', 30;

        grub_boot_with_kernel_parameters("inst.sshd inst.ks=$ks_url");
    }

    # wait for the installer welcome screen to appear
    assert_screen 'installer', 360;

    if (match_has_tag('installer-inactive')) {
        mouse_set(10, 10);
        mouse_click();
        mouse_hide();
        sleep(2);
    } else {
        # sync mouse position, and do the first mouse move for Xorg to really
        # detect (sub)device presence
        mouse_hide();
        sleep(2);
    }

    if (check_var("BACKEND", "qemu")) {
        # get console on hvc1 too
        select_console('install-shell');
        type_string("systemctl start anaconda-shell\@hvc1\n");
        select_console('installation', await_console=>0);
    }

    if (check_var("MACHINE", "hw7") or check_var("MACHINE", "hw12") or
        check_var("MACHINE", "optiplex") or check_var("MACHINE", "vp4670") or check_var('MACHINE', 'nuc-box')) {
        select_root_console();
        # RTC battery not connected
        script_run("date -s @" . time());
        script_run("hwclock -w");
        select_console('installation', await_console=>0);
    }
}

sub grub_boot_with_kernel_parameters {
    my $parameters = shift;
    # skip media verification and edit boot parameters
    # select boot entry without media verification
    send_key 'up';
    # start editing it
    send_key 'e';
    # menu redraws with serial output take too long, some key presses get lost
    # consider building Dasharo without serial redirection after SeaBIOS
    sleep 1;
    # go to the line with kernel parameters
    send_key 'down';
    sleep 1;
    send_key 'down';
    sleep 1;
    send_key 'down';
    sleep 1;
    send_key 'end';
    sleep 1;
    # append them, somewhat slowly
    type_string(" $parameters", max_interval => 10);
    # boot
    send_key 'f10';
}

sub seabios_boot {
    assert_serial qr/Press ESC for boot menu./, 30;
    send_key 'esc';

    my $menu = wait_serial qr/TPM Configuration/, 5;
    # SeaBIOS prints ANSI escape code every second (RTC interrupt), log the
    # output for easier debugging if it happens while the menu is being printed
    diag("SeaBIOS boot menu:\n" . $menu);
    $menu =~ /(.)\. USB MSC Drive/;
    if (!defined($1)) {
        die "No USB MSC Drive detected";
    }

    diag("Booting entry " . $1);
    send_key $1;

    my $ks_url = prepare_kickstart_config();
    my $params = "inst.sshd inst.ks=$ks_url";

    # VP4670 has multiple network controllers, only use the first one
    if (check_var('MACHINE', 'vp4670')) {
        my $device_ip = get_var('QUBES_OS_HOST_IP');
        $params .= " ip=${device_ip}::192.168.10.1:255.255.255.0::enp1s0 bootdev=enp1s0";
    }

    assert_screen 'bootloader-installer';
    grub_boot_with_kernel_parameters($params);
}

sub ipxe_boot {
    # Values:
    #  * dasharo:
    #    - need to pick menu entry to enter shell
    #    - iPXE is capable of booting QubesOS
    #  * <anything else> -- iPXE menu
    #    - Ctrl-B enters the shell immediately
    #    - iPXE is not capable of booting QubesOS, need to chain into a
    #      full-featured version
    my $flavour = shift;
    # iPXE boot script.
    my $ipxe_url = shift;

    if ($flavour ne 'dasharo') {
        # Assumption:
        #     Full-featured iPXE binary in PXE format is available at
        #     `$QUBES_OS_OPENQA_URL/ipxe.pxe`.
        my $openqa_url = get_var('QUBES_OS_OPENQA_URL');

        # download and start a full-featured iPXE binary in PXE format
        run_ipxe_chain($flavour, "$openqa_url/ipxe.pxe");
    }

    # start QubesOS by processing instructions from iPXE script file
    run_ipxe_chain($flavour, $ipxe_url);
}

sub run_ipxe_chain {
    # kind of firmware/iPXE combination
    my $flavour = shift;
    # parameter of the chain command
    my $what = shift;

    if ($flavour eq 'dasharo') {
        # assumming iPXE shell is the last menu item
        send_key('end', wait_screen_change => 1);
        sleep 1;
        send_key('ret', wait_screen_change => 1);
    } else {
        # send Ctrl-B proactively
        send_key 'ctrl-b';
        send_key 'ctrl-b';
        send_key 'ctrl-b';
        send_key 'ctrl-b';
        send_key 'ctrl-b';

        assert_serial qr/Press Ctrl-B|Boot Menu/, 30;

        # enter iPXE command-line (does nothing in a menu)
        send_key 'ctrl-b';
        send_key 'ctrl-b';
        send_key 'ctrl-b';
        send_key 'ctrl-b';
        send_key 'ctrl-b';
    }

    assert_fuzzy_serial "iPXE>", 30;

    # the use of && has a purpose: for some reason os-autoinst might have
    # trouble feeding any input to DUT after running dhcp command
    type_string "dhcp && chain $what\n";
    assert_fuzzy_serial "... ok";
}

sub test_flags {
    # 'fatal'          - abort whole test suite if this fails (and set overall state 'failed')
    # 'ignore_failure' - if this module fails, it will not affect the overall result at all
    # 'milestone'      - after this test succeeds, update 'lastgood'
    # 'norollback'     - don't roll back to 'lastgood' snapshot if this fails
    return { fatal => 1 };
}

sub post_fail_hook {

    # hide plymouth if any
    send_key "esc";
    save_screenshot;

};

sub prepare_kickstart_config {
    my $ks_cfg = <<'ENDKS';
# default settings, to mimic interactive install
keyboard --vckeymap=us
timezone --utc UTC

sshpw --username root --plaintext userpass

# by default the installer marks all disks for installation which is undesirable
# not only due to data removal but also because this can select USB drives which
# affects configuration related to USB controllers
ignoredisk --only-use=sda

%packages
@^qubes-xfce
#@debian
#@whonix
%end

%pre
sed -i '/PasswordAuthentication/s!no!yes!' /etc/ssh/sshd_config.anaconda
systemctl stop sshd.socket
systemctl stop sshd.service
systemctl restart anaconda-sshd

# drop partition table
fdisk /dev/sda << FDISK
o
w
FDISK

%end

%post

# enable password root login over SSH
mkdir -p /etc/ssh/sshd_config.d
echo 'PermitRootLogin yes' > /etc/ssh/sshd_config.d/30-openqa.conf

# enable SSH on first boot
cat >/usr/local/bin/post-setup << EOF_POST_SETUP
#!/bin/sh

set -xe

# allow all USB devices, this setting seems to appear on first boot, hence
# the update is performed here
sed -i -e 's/authorized_default=0/authorized_default=1/' /boot/grub2/grub.cfg /etc/default/grub

###PLATFORM_WORKAROUNDS###

qvm-run -p --nogui -- sys-net nm-online -t 300
qubes-dom0-update -y openssh-server
systemctl enable --now sshd
printf 'qubes.ConnectTCP +22 sys-net dom0 allow\n' >> /etc/qubes/policy.d/30-openqa.policy

qvm-run --nogui -u root -p sys-net 'cat >>/rw/config/rc.local' << EOF_ALLOW_22
nft add rule ip qubes custom-input tcp dport ssh accept
iptables -I INPUT -p tcp --dport 22 -j ACCEPT
qvm-connect-tcp 22:dom0:22
EOF_ALLOW_22
qvm-run --nogui -u root sys-net '/rw/config/rc.local </dev/null &>/dev/null'

systemctl disable post-setup.service
EOF_POST_SETUP
chmod +x /usr/local/bin/post-setup

cat >/etc/systemd/system/post-setup.service << EOF_SERVICE
[Unit]
After=initial-setup.service
[Service]
Type=oneshot
ExecStart=/usr/local/bin/post-setup
[Install]
WantedBy=multi-user.target
EOF_SERVICE
systemctl enable post-setup.service
echo enable post-setup.service >> /usr/lib/systemd/system-preset/30-openqa.preset

%end
ENDKS

    my %workarounds = (
        'hpt630v1' => <<'ENDWORKAROUND',
# Place `spec-ctrl=no-ibpb-entry` at the end of every `multiboot2` command.
sed -i -e 's/^[ \t]*multiboot2.*/& spec-ctrl=no-ibpb-entry/' /boot/grub2/grub.cfg
# Add `spec-ctrl=no-ibpb-entry` to the end of `\$GRUB_CMDLINE_XEN_DEFAULT`
echo 'GRUB_CMDLINE_XEN_DEFAULT="\$GRUB_CMDLINE_XEN_DEFAULT spec-ctrl=no-ibpb-entry"' >> /etc/default/grub
ENDWORKAROUND
        'hpt630v2' => <<'ENDWORKAROUND',
# Place `spec-ctrl=no-ibpb-entry` at the end of every `multiboot2` command.
sed -i -e 's/^[ \t]*multiboot2.*/& spec-ctrl=no-ibpb-entry/' /boot/grub2/grub.cfg
# Add `spec-ctrl=no-ibpb-entry` to the end of `\$GRUB_CMDLINE_XEN_DEFAULT`
echo 'GRUB_CMDLINE_XEN_DEFAULT="\$GRUB_CMDLINE_XEN_DEFAULT spec-ctrl=no-ibpb-entry"' >> /etc/default/grub
ENDWORKAROUND
        'vp4670'   => <<'ENDWORKAROUND',
# workaround for https://github.com/Dasharo/dasharo-issues/issues/1256
sed -i -e 's/ucode=scan/ucode=no-scan/' /boot/grub2/grub.cfg /etc/default/grub
ENDWORKAROUND
    );

    # Add workarounds. Platforms not listed in workarounds return empty string
    $ks_cfg =~ s/###PLATFORM_WORKAROUNDS###/$workarounds{get_var('MACHINE')}/;

    # nuc-box has NVMe disk
    if (check_var('MACHINE', 'nuc-box')) {
        $ks_cfg =~ s/--only-use=sda/--only-use=nvme0n1/;
        $ks_cfg =~ s@/dev/sda@/dev/nvme0n1@;
    }

    save_tmp_file('ks.cfg', $ks_cfg);
    return autoinst_url('/files/ks.cfg');
}

sub prepare_ipxe_script {
    # additional Linux kernel parameters
    my $extra_linux_params = shift;

    my $openqa_url = get_var('QUBES_OS_OPENQA_URL');

    # Assumption:
    #     Installation ISO is mounted at `$QUBES_OS_OPENQA_URL/iso`.
    my $ipxe = <<"ENDIPXE";
#!ipxe
set host ${openqa_url}
set base \${host}/iso/images/pxeboot
kernel \${base}/vmlinuz inst.repo=\${host}/iso inst.sshd reboot=pci plymouth.ignore-serial-consoles  ${extra_linux_params}
initrd \${base}/initrd.img
boot
ENDIPXE

    save_tmp_file('ipxe', $ipxe);
    return autoinst_url('/files/ipxe');
}

1;

# vim: set sw=4 et:

