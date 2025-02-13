use base "basetest";
use strict;
use testapi;
use serial_terminal;

sub run {
    if (get_var("STORE_HDD_1") || get_var("PUBLISH_HDD_1") || check_var("BACKEND", "generalhw")) {
        select_root_console();
        # make upload as small as possible
        assert_script_run("fstrim -v /", timeout => 180);
    }
    if (get_var("STORE_HDD_1") || get_var("PUBLISH_HDD_1")) {
        # shutdown before uploading disk image
        assert_script_run("poweroff", 0);
        assert_shutdown 300;
    } elsif (check_var("BACKEND", "generalhw")) {
        # otherwise just sync and remount /boot (clears the orphan present
        # flag) if running non-virtualized
        assert_script_run("! mountpoint -q /boot/efi || mount -o ro,remount /boot/efi");
        assert_script_run("! mountpoint -q /boot || mount -o ro,remount /boot");
        assert_script_run("sync");

        if (get_var('TEST_AEM_HW')) {
            assert_script_run("reboot");
        } else {
            assert_script_run("poweroff");
        }
        sleep 10;
    }

}

# this is not 'fatal' or 'important' as all wiki test cases are passed
# even if shutdown fails. we should have a separate test for shutdown/
# logout/reboot stuff, might need some refactoring.
sub test_flags {
    return { 'norollback' => 1, 'ignore_failure' => 1 };
}

1;

# vim: set sw=4 et:
