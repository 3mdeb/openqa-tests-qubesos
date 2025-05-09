# The Qubes OS Project, https://www.qubes-os.org/
#
# Copyright (C) 2024 3mdeb Sp. z o.o.
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

use base "installedtest";
use strict;
use testapi;
use serial_terminal;
use networking;
use utils qw(assert_serial);
use Data::Dumper;

# AEM is installed without SRK password for simplicity.
#
# How it runs
# -----------
#
# If TEST_AEM_HW equals "setup":
#     Install the system and shut it down. Separate test suite for clarity.
# If TEST_AEM_HW equals "first-run":
#     Check that AEM sealed secret successfully.
# If TEST_AEM_HW equals "second-run":
#     Check that AEM unsealed secret successfully and dump TPM event log.
#
# This is done to work around Xen having issues with rebooting the
# machine (passing it "reboot=" didn't help).
#
# Variables for TEST_AEM_HW=setup stage
# -------------------------------------
#
# PACKAGES_BASE_URL - where to look for AEM-related packages.
# AEM_VER           - version of "anti-evil-maid" package
# GRUB_VER          - version of "grub2-*" packages
# SKL_VER           - version of "secure-kernel-loader" package
# XEN_VER           - version of "python3-xen-*" and "xen-*" packages

# values of these are likely to match on different hardware, but
# they are generally machine-specific, so don't assume anything
my $drtm_kind;
if (check_var('MACHINE', 'optiplex') or check_var('MACHINE', 'vp4670')) {
    $drtm_kind = 'txt';
} elsif (check_var('MACHINE', 'supermicro') or check_var('MACHINE', 'hpt630v1')
         or check_var('MACHINE', 'hpt630v2')) {
    $drtm_kind = 'skinit';
} else {
    die "Don't know DRTM type of '@{[ get_var('MACHINE') ]}' machine!";
}

my $bios_kind;
if ((check_var('MACHINE', 'optiplex') and check_var('OS_INSTALL_LEGACY', '1')) or
    (check_var('MACHINE', 'vp4670') and check_var('OS_INSTALL_LEGACY', '1'))) {
    $bios_kind = 'seabios';
} elsif (check_var('MACHINE', 'supermicro')) {
    $bios_kind = 'aptio';
} elsif (check_var('MACHINE', 'hpt630v1') or check_var('MACHINE', 'hpt630v2')) {
    $bios_kind = 'hp_ami';
} elsif (check_var('MACHINE', 'vp4670') or check_var('MACHINE', 'optiplex')) {
    $bios_kind = 'dasharo_uefi';
} else {
    die "Don't know BIOS type of '@{[ get_var('MACHINE') ]}' machine!";
}

my $boot_disk;
my $boot_part;
if (check_var('OS_INSTALL_LEGACY', '1')) {
    $boot_disk = '/dev/sda';
    $boot_part = '/dev/sda1';
} elsif (check_var('OS_INSTALL_LEGACY', '0')) {
    $boot_disk = '/dev/sda';
    $boot_part = '/dev/sda2';
} else {
    die "Don't know disk and partition names for '@{[ get_var('MACHINE') ]}' machine!";
}

sub run {
    my ($self) = @_;

    if (check_var('TEST_AEM_HW', 'setup')) {
        get_var('PACKAGES_BASE_URL') or die "PACKAGES_BASE_URL not set!";
        get_var('AEM_VER') or die "AEM_VER not set!";
        get_var('GRUB_VER') or die "GRUB_VER not set!";
        get_var('XEN_VER') or die "XEN_VER not set!";
        if ($drtm_kind eq 'skinit') {
            get_var('SKL_VER') or die "SKL_VER not set!";
        }

        clear_tpm();

        # using this to support re-installing AEM
        assert_screen 'bootloader';
        # assert_serial 'Welcome to GRUB!|Press enter to boot the selected OS';
        send_key 'end';
        # skip firmware settings on UEFI
        if (check_var('OS_INSTALL_LEGACY', '0')) {
            send_key 'up';
        }
        send_key 'up';
        send_key 'ret';

        handle_luks_pass();
        wait_for_startup();

        # too much logging is causing `xl dmesg` to start dropping lines from the
        # top, which results in anti-evil-maid-dump-evt-log failing to find event
        # log
        assert_script_run "sed -i -e 's/ guest_loglvl=all//' /etc/default/grub";

        if ($drtm_kind eq 'txt') {
            setup_acm();
        }
        add_aem_repository();
        install_packages();
        # XXX: workaround until trousers-changer gets the fix
        assert_script_run "sed -i 's/-o pipefail//' /sbin/tpm_id /sbin/tpm2_id";

        setup_aem();
    } elsif (check_var('TEST_AEM_HW', 'first-run')) {
        # first reboot:
        #  - tries to unseal the secret, but fails (this isn't asserted)
        #  - seals the secret successfully
        assert_screen ["bootloader", "luks-prompt"], timeout => 180;
        handle_luks_pass();
        assert_screen "aem-secret.txt-sealed", timeout => 60;
        wait_for_startup();
    } elsif (check_var('TEST_AEM_HW', 'second-run')) {
        # second reboot:
        #  - unseals the secret successfully
        #  - seals the secret successfully
        handle_aem_startup();
        handle_luks_pass();
        assert_screen "aem-secret.txt-sealed", timeout => 60;

        # use full init_gui_session - netvm must be running to upload logs
        $self->init_gui_session;
        select_root_console();

        # collect event log dump
        assert_script_run('anti-evil-maid-dump-evt-log > /tmp/aem_event.log');
        # store event log in case manual inspection will be needed
        curl_via_netvm;
        upload_logs('/tmp/aem_event.log', failok => 1);

        # check if log has all expected entries and PCRs match expected values
        check_event_log_completeness('/tmp/aem_event.log');
    }
}

sub check_event_log_completeness {
    my ($path) = @_;

    my $soft_fails = 0;

    my sub soft_assert_script_run {
        my ($script) = @_;
        my $res = script_run($script);
        if ($res) {
            $soft_fails++;
            record_info("Event log error", "Command '" . $script . "' failed",
                        result => 'softfail');
        }
        return $res;
    }

    # check if log has all expected entries
    if ($drtm_kind eq 'skinit') {
        soft_assert_script_run('grep "SKINIT" ' . $path);
        soft_assert_script_run('grep "DLME entry offset" ' . $path);
        soft_assert_script_run('grep "DLME$" ' . $path);
    } elsif ($drtm_kind eq 'txt') {
        # TXT uses event types instead of names, there are many more than these,
        # but their number and order varies between families, check just the
        # most important, common ones
        soft_assert_script_run('grep "Event Type: 0x402" ' . $path); # HASH_START
        soft_assert_script_run('grep "Event Type: 0x404" ' . $path); # MLE_HASH
        soft_assert_script_run('grep "Event Type: 0x410" ' . $path); # SINIT_PUBKEY_HASH
    } else {
        die "Unhandled DRTM kind run(): '$drtm_kind'!";
    }

    # SLRT, type 0x502 with no `Event` information
    soft_assert_script_run('grep "Event Type: 0x502" -A5 ' . $path . ' | grep "Event: $"');

    if ($drtm_kind eq 'txt') {
        soft_assert_script_run('grep "Measured TXT OS-MLE data" ' . $path);
    }

    if (check_var('OS_INSTALL_LEGACY', '0')) {
        soft_assert_script_run('grep "Xen\'s command line" ' . $path);
        soft_assert_script_run('grep "MB module string" ' . $path);
    } else {
        # on legacy, the above entries are part of MBI that has type 0x502 and
        # no `Event`, which makes it the second such entry after SLRT
        soft_assert_script_run('[ $(grep "Event Type: 0x502" -A5 ' . $path .
                          ' | grep "Event: $" -c) -eq 2 ]');
    }
    soft_assert_script_run('grep "MB module$" ' . $path);

    # check if PCRs match
    my $pcrs_str = script_output('ls /sys/class/tpm/tpm0/pcr-sha*/1[78] -1');
    my @pcrs = split ' ', $pcrs_str;
    for my $pcr (@pcrs) {
        my $res = soft_assert_script_run("grep -wi \$(cat $pcr) " . $path);
        if ($res and check_var('MACHINE', 'optiplex') and $pcr =~ qr/17$/) {
            record_info("ACM bug", "Previous error may be caused by bug in Intel ACM");
            $soft_fails--;
        }
    }

    die "Event log incomplete or malformed" if $soft_fails;
}

sub clear_tpm {
    if ($bios_kind eq 'seabios') {
        clear_tpm_seabios();
    } elsif ($bios_kind eq 'aptio') {
        clear_tpm_aptio();
    } elsif ($bios_kind eq 'hp_ami') {
        clear_tpm_hp();
    } elsif ($bios_kind eq 'dasharo_uefi') {
        clear_tpm_dasharo();
    } else {
        die "Unhandled BIOS type in clear_tpm(): '$bios_kind'!";
    }
}

sub clear_tpm_seabios {
    # enter boot menu
    assert_serial 'Press ESC for boot menu.';
    send_key 'esc';

    # enter TPM menu
    assert_serial 't. TPM Configuration';
    send_key 't';

    my $menu = wait_serial qr/reboot the machine./, 5;

    # SeaBIOS spews ANSI Cursor Position code every second, after repeating the
    # previously printed character. It so happens that it is often inserted in
    # 'Clear ownership' line, which breaks parsing. Remove that one repeated
    # character and control sequence to reliably match the line.
    $menu =~ s/.\e\[\d+;\d+H//g;

    if (!($menu =~ qr/Ownership has( not)? been taken/)) {
        # TPM 2.0
        send_key '1';
        # poor UX, selecting the option loops back to menu with no feedback
        send_key 'esc';
    } elsif ($menu =~ 'Ownership has not been taken') {
        # TPM 1.2 with ownership not taken, exit TPM menu
        send_key 'esc';
    } else {
        # TPM 1.2 with ownership taken, reset the TPM to allow taking ownership
        if (!($menu =~ qr/c. Clear ownership/)) {
            # Simulate assert_serial output
            die "Failed to match serial output against regexp /c. Clear ownership/";
        }
        send_key 'c';
        assert_serial 'e. Enable the TPM';
        send_key 'e';
        assert_serial 'a. Activate the TPM';
        send_key 'a';
    }

    # at this point the machine reboots
}

sub clear_tpm_aptio {
    # enter boot menu
    my $menu = undef;
    for my $i (0 .. 45) {
        send_key 'delete';
        $menu = wait_serial('American Megatrends', 1);
        if (defined $menu) {
            last;
        }
    }

    if (!defined $menu) {
        die 'Failed to enter BIOS';
    }

    # switch to "Advanced" tab
    send_key 'right';
    assert_serial 'Trusted Computing';

    # select and enter "Trusted Computing" submenu
    send_key 'down';
    send_key 'ret';
    assert_serial 'TPM20 Device Found';

    # select and run "Pending Operation" item
    send_key 'down';
    send_key 'down';
    send_key 'down';
    send_key 'ret';
    assert_serial 'TPM Clear';

    # pick "TPM Clear"
    send_key 'down';
    send_key 'ret';

    # "save and exit" and its confirmation
    send_key 'f4';
    assert_serial 'Save configuration and exit';
    send_key 'ret';

    # at this point the machine reboots
}

sub clear_tpm_hp {
    # enter setup menu
    assert_screen 'hp_post_delay';
    send_key 'f10';
    # the landing menu
    assert_screen 'hp_setup_file';

    # move to "security" menu (third one)
    send_key 'right';
    send_key 'right';
    assert_screen 'hp_setup_security';

    # select "system security" option (second from bottom)
    send_key 'up';
    send_key 'up';
    send_key 'ret';
    assert_screen 'hp_setup_security_system_security';

    # select "Clear TPM" option and verify its set to "reset"
    send_key 'up';
    send_key 'right';
    assert_screen 'hp_setup_security_system_security_clear_tpm';

    # save changes
    send_key 'f10';

    # return to "File" menu, pressing "esc" always lands on "Ignore Changes and Exit"
    send_key 'esc';

    # select "Save changes and Exit", which is directly below "Ignore Changes"
    send_key 'down';
    send_key 'ret';
    assert_screen 'hp_setup_save_and_exit_confirmation';

    # confirm save and exit
    send_key 'left';
    send_key 'ret';

    # machine reboots

    # enter setup menu
    assert_screen 'hp_post_delay';
    send_key 'f10';
    # the landing menu
    assert_screen 'hp_setup_file';

    # move to "security" menu (third one)
    send_key 'right';
    send_key 'right';
    assert_screen 'hp_setup_security';

    # select "system security" option (second from bottom)
    send_key 'up';
    send_key 'up';
    send_key 'ret';
    assert_screen 'hp_setup_security_system_security';

    # select "TPM State" option and verify its set to "Enabled"
    send_key 'up';
    send_key 'up';
    if (check_screen('hp_setup_security_system_security_tpm_disabled', timeout => 2)) {
        send_key 'right';
    }
    assert_screen 'hp_setup_security_system_security_tpm_enabled';

    # save changes
    send_key 'f10';

    # return to "File" menu, pressing "esc" always lands on "Ignore Changes and Exit"
    send_key 'esc';

    # select "Save changes and Exit", which is directly below "Ignore Changes"
    send_key 'down';
    send_key 'ret';
    assert_screen 'hp_setup_save_and_exit_confirmation';

    # confirm save and exit
    send_key 'left';
    send_key 'ret';

    # reboots
}

sub clear_tpm_dasharo {
    # enter setup menu
    assert_screen 'dasharo_post_delay';
    send_key 'delete';  # vp4670
    send_key 'f2';      # optiplex
    # the landing menu
    assert_screen 'dasharo_setup';

    # navigate to device manager
    send_key_until_needlematch('dasharo_setup_devmgr', 'down', 10);
    send_key 'ret';
    assert_screen 'dasharo_device_manager';

    # navigate to TCG(2) configuration
    send_key_until_needlematch('dasharo_device_manager_tcg2', 'down', 10);
    send_key 'ret';
    assert_screen 'dasharo_tcg2';

    # select TPM(2) Operation, position may depend on number of available PCR banks
    send_key_until_needlematch('dasharo_tpm2_operation', 'up', 10);

    # The popup we're in now is very slow, it is fully reprinted after each
    # move, and because of serial redirection it is clearly visible that each
    # line is printed separately. Key presses are sometimes dropped if they
    # happen too quickly during printing, and wait_screen_change may catch the
    # change between the lines, before window gets printed in full. Adding a 1s
    # delay between key presses seems to make navigation reliable.

    # 'TPM2_ClearControl + Clear' is 3 steps down
    send_key 'ret';
    sleep 1;
    send_key 'down';
    sleep 1;
    send_key 'down';
    sleep 1;
    send_key 'down';
    sleep 1;
    if (match_has_tag('dasharo_tpm12_operation')) {
        # 'Force TPM Clear, Enable, and Activate' - 6 steps total, 3 left
        send_key 'down';
        sleep 1;
        send_key 'down';
        sleep 1;
        send_key 'down';
        sleep 1;
        save_screenshot;
        send_key 'ret';
        assert_screen 'dasharo_tpm12_clear_enable_activate';
    } else {
        save_screenshot;
        send_key 'ret';
        assert_screen 'dasharo_tpm2_clearcontrol';
    }
    send_key('esc', wait_screen_change => 1);  # go back to device manager

    # save, return to main menu and reboot
    send_key('f10', wait_screen_change => 1);
    send_key('y', wait_screen_change => 1);
    send_key('esc', wait_screen_change => 1);
    send_key('pgdn', wait_screen_change => 1);
    send_key('ret', wait_screen_change => 1);

    # confirm request to clear TPM
    assert_screen 'dasharo_tpm2_confirm_clear';
    send_key('f12');
}

sub setup_acm {
    my $url = 'https://dl.3mdeb.com/mirror/intel/acm';
    my %machine2file = (
        'optiplex' => 'SNB_IVB_SINIT_20190708_PW.bin',
        'vp4670'   => 'CFL_SINIT_20221220_PRODUCTION_REL_NT_O1_1.10.1_signed.bin'
    );
    my $fname = $machine2file{get_var('MACHINE')};

    if ($fname eq '') {
        die "Don't know which ACM to use for " . get_var('MACHINE');
    }

    assert_script_run("qvm-run --pass-io sys-net \'curl -L $url/$fname\' > /boot/$fname");
}

sub add_aem_repository {
    my $base_url = get_var('PACKAGES_BASE_URL');
    my $key_file = "RPM-GPG-KEY-aem";
    my $key_url = "${base_url}/${key_file}";
    my $repo_definition = "[aem]\\nname = Anti Evil Maid based on TrenchBoot\\nbaseurl = $base_url\\ngpgcheck = 1\\ngpgkey = $key_url\\nenabled=1";

    assert_script_run("sudo printf >/etc/yum.repos.d/aem.repo \'${repo_definition}\'");

    assert_script_run("qvm-run --pass-io sys-net \'curl -L $key_url\' > $key_file");
    assert_script_run("sudo rpm --import $key_file");
}

sub get_aem_deps_names {
    my $aem_ver = get_var('AEM_VER');
    my $grub_ver = get_var('GRUB_VER');
    my $xen_ver = get_var('XEN_VER');
    my @packages = (
        "anti-evil-maid-$aem_ver.fc37.x86_64",
        "grub2-common-$grub_ver.fc37.noarch",
        "grub2-tools-$grub_ver.fc37.x86_64",
        "grub2-tools-extra-$grub_ver.fc37.x86_64",
        "grub2-tools-minimal-$grub_ver.fc37.x86_64",
        "python3-xen-$xen_ver.fc37.x86_64",
        "xen-$xen_ver.fc37.x86_64",
        "xen-hypervisor-$xen_ver.fc37.x86_64",
        "xen-libs-$xen_ver.fc37.x86_64",
        "xen-licenses-$xen_ver.fc37.x86_64",
        "xen-runtime-$xen_ver.fc37.x86_64",
    );

    if (check_var('OS_INSTALL_LEGACY', '1')) {
        push @packages, "grub2-pc-$grub_ver.fc37.x86_64";
        push @packages, "grub2-pc-modules-$grub_ver.fc37.noarch",
    } elsif (check_var('OS_INSTALL_LEGACY', '0')) {
        push @packages, "grub2-efi-x64-$grub_ver.fc37.x86_64";
        push @packages, "grub2-efi-x64-modules-$grub_ver.fc37.noarch";
    }

    if ($drtm_kind eq 'skinit') {
        my $skl_ver = get_var('SKL_VER');
        push @packages, "secure-kernel-loader-$skl_ver.fc37.x86_64";
    }

    return \@packages;
}

sub install_packages {
    my @extra_deps = (
        'oathtool',
        'openssl',
        'qrencode',
        'tpm-extra',
        'trousers-changer',
        'tpm-tools',
    );

    my @packages = @{get_aem_deps_names()};

    assert_script_run("qubes-dom0-update --enablerepo=qubes-dom0-current-testing -qy @extra_deps");

    # Whether a particular package needs to be installed or reinstalled depends
    # on what's currently installed in the system.  Installed versions also
    # determine whether installing a single additional grub2 package will
    # succeed because it might depend on others which dnf doesn't know how to
    # find.  This is why try to do both operations as dnf doesn't seem to allow
    # doing it in one command.  Reinstallation happens first, because it just
    # skips packages which were never installed, potentially saving some time
    # when this gets run initially.  However, it fails when there are no
    # packages to reinstall (e.g. when they are in different versions), so it's
    # return isn't asserted.
    script_run("qubes-dom0-update --disablerepo=\"*\" --enablerepo=aem --action=reinstall -y @packages", timeout => 300);
    assert_script_run("qubes-dom0-update --disablerepo=\"*\" --enablerepo=aem --action=install -y @packages", timeout => 300);

    # Must manually install grub on legacy installations
    if (check_var('OS_INSTALL_LEGACY', '1')) {
        assert_script_run("grub2-install $boot_disk");
    }
}

sub setup_aem {
    # cleanup in case AEM was previously initialized (useful for debugging this test)
    assert_script_run('rm -rf /var/lib/anti-evil-maid/aem');

    assert_script_run('anti-evil-maid-tpm-setup -z');
    assert_script_run("anti-evil-maid-install $boot_part");

    assert_script_run('echo "really big secret" > /var/lib/anti-evil-maid/aem/secret.txt');
}

sub handle_luks_pass {
    lukspass_no_video_workaround("luks-prompt");
    # AEM boot on Intel platforms can take significant amount of time.
    assert_screen "luks-prompt", timeout => 120;
    type_string "lukspass\n";
}


sub wait_for_startup {
    assert_screen "login-prompt-user-selected", timeout => 120;
    select_root_console();
}

sub handle_aem_startup {
    lukspass_no_video_workaround("aem-good-secret");
    assert_screen "aem-good-secret", timeout => 180;
    send_key "ret";
}

# Workaround for the bug where video signal is missing
sub lukspass_no_video_workaround {
    my ($needle) = @_;

    if (!check_var("LUKSPASS_NO_VIDEO_WORKAROUND", "1")) {
        return;
    }

    sleep 15;
    for my $i (1..10) {
        if (check_screen($needle, timeout => 10)) {
            last;
        }
        send_key 'esc';
        if (!check_screen($needle, timeout => 1)) {
            send_key 'esc';
        }
        sleep 5;
    }
}

sub test_flags {
    # without anything - rollback to 'lastgood' snapshot if failed
    # 'fatal' - whole test suite is in danger if this fails
    # 'milestone' - after this test succeeds, update 'lastgood'
    # 'important' - if this fails, set the overall state to 'fail'
    return { important => 1 };
}

sub post_run_hook {
    my $self = shift;
}

sub post_fail_hook {
    my $self = shift;
    # don't bother collecting various logs
}

1;

# vim: set sw=4 et:
