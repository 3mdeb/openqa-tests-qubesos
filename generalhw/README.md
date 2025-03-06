# Configurations for testing Qubes OS via PiKVM and RTE

![Setup diagram](./openqa-qubesos-setup.png).

The first hardware setup was done for MSI at the time when `os-autoinst` lacked
ability to connect to PiKVM's VNC.  This made it more complicated than a
VNC-based setup for OptiPlex.  New setups should use VNC if possible (see
[adding-vnc-setup.md](adding-vnc-setup.md) for how).

* [msi](msi/README.md)

  - `ffmpeg`-based
  - stops `kvmd` on PiKVM for the duration of the test
  - manages input via `gadget-control` script
  - Kickstart configuration is served by PiKVM
  - installation is done from a drive mounted via OTG USB by `gadget-control`
    script
  - boots from the mounted drive

* [optiplex](optiplex/README.md)

  - VNC-based
  - can stop `kvmd` during poweron/poweroff if it interferes with power state
    check
  - input is handled by VNC (`kvmd-vnc`)
  - Kickstart configuration is served by openQA server
  - installation is done from HTTP served by openQA that mounts ISO
  - boots via iPXE which loads full-functional iPXE image that is capable of
    downloading kernel and initrd from the ISO and start it

* [supermicro](supermicro/README.md)

  - VNC-based
  - power is managed through IPMI connection to motherboard's BMC
  - input is handled by VNC (`kvmd-vnc`)
  - Kickstart configuration is served by openQA server
  - installation is done from HTTP served by openQA that mounts ISO
  - reboots PiKVM in flash script for better stability
  - updates a GRUB image in the flash script to use correct IP address of the
    openQA server, then uploads it to PiKVM
  - the GRUB image comes with `iPXE.lkrn` which downloads kernel and initrd
    over the network and starts it

* [hp](hp/README.md)

  - VNC-based
  - configuration based on optiplex
  - input is handled by VNC (`kvmd-vnc`)
  - Kickstart configuration is served by openQA server
  - iPXE not supported in the stock firmware
  - installation performed from a flash drive
  - flashing not supported
  - serial not supported in BIOS
  - power controlled using Sonoff - hard shutdowns can affect the TPM chip

* [vp4670](vp4670/README.md)

  - VNC-based
  - configuration based on optiplex
  - input is handled by VNC ('kvmd-vnc')
  - Kickstart configuration is served by openQA server
  - iPXE supported, but the `/srv/www/openqa/ipxe.pxe` and
    `/srv/www/openqa/ipxe` don't boot out of the box
  - installation is done from a drive mounted via OTG USB by `gadget-control`
    script
  - required to configure the network interface for the installation using
  anaconda boot parameters

## Usage information

Drive's passphrase: `lukspass`.

`root`'s and `user`'s password: `userpass`.

SSH is kept running after tests are done (including after a reboot).  Password
authorization is enabled.  Server's key is generated on installation, so expect
the need to remove old keys from `~/.ssh/known_hosts`.

See `README.md` files in subdirectories for more details.

## PiKVM preparation

VNC setup only needs `~root/openqa/edid.1024x768` file, FFMPEG setup is more
complicated, see <https://blog.3mdeb.com/2023/2023-12-22-qubesos-hw-testing/>.

## Possible issues

These known issues might indicate an area of possible improvement in terms of
reliability, but some can also be caused by, say, a race condition inherent to
the setup or specific hardware/software and thus it might be impossible to
completely eliminate them.  Hard to tell the cases apart, so at least
documenting observed troubles and workarounds.

### DUT won't power on

Use Sonoff to detach it from power line completely for awhile, then try again.

### Serial doesn't work

Try running `systemctl restart ser2net` on RTE.  If that doesn't help, reboot
the RTE.

### No video from PiKVM

Sometimes PiKVM works, but you can't SSH to it which is done by `power` script.
Check if you can create a new SSH connection to PiKVM and log in successfully
(possible nonsensical error is "permission denied").  Make sure it's a new
connection if you're using sharing of SSH connections via
multiplexing (`ControlMaster` option in `~/.ssh/config`).  Rebooting PiKVM
helps, maybe simply restarting `sshd` will help as well, didn't try it.

### `power` script thinks the DUT is on when it's actually off

Checking in PiKVM's Web-UI that it can be powered on and off sometimes resolves
this.

### Reboot doesn't work

DUT can end up in a weird half-reboot state.  Unclear why, given that it doesn't
happen consistently, but it's not unheard of:

 - Qubes OS: <https://forum.qubes-os.org/t/qubes-os-does-not-reboot/12852>
 - Dell Workstation: <https://forums.centos.org/viewtopic.php?t=1164>

In all cases suggested solution is to change the way system is being reboot
either by Xen or Linux.  Both have `reboot=` parameter.  In case of Linux
(relevant for the installer which doesn't use Xen) you can see default settings
in `/sys/kernel/reboot/`.

For usage read `kernel/reboot.c` in Linux or the second link above,
documentation exists but seems to be messed up.  `reboot=pci` seems to work for
Linux, but not for Xen (no available option affected Xen much).

### PiKVM Web-UI is down

If you see `500 Internal Server Error`, `kvmd` service must be stopped, start it
with:

```bash
systemctl start kvmd
```

It takes several seconds for it to start serving Web-UI.

### Hang on `assert_screen()` for 2 hours

Restarting the hung job without parents should work fine.  This looks like it
could be a bug in `os-autoinst`, because there are no traces of an active VNC
connection when it happens.  Based on `journalctl -u kvmd-vnc`:

1. VNC connection gets established.
2. VNC server errors:
   ```
   Gone: Can't read incoming message type: IncompleteReadError: 0 bytes read on a total of 1 expected bytes
   ```
3. VNC server closes connection.
4. `os-autoinst` hangs somewhere as if not noticing that there is no video
   input.

Attempted and failed workarounds:

1. Adding `wait_serial 'Welcome to GRUB!'` before first `assert_screen()` to
   delay use of VNC.
2. Adding `sleep 5` after `systemctl start kvmd` in `power` script to let VNC
   recognize that `kvmd` is back up, but there seems to be ~30 second gap anyway
   and `kvmd-vnc` might be attempting connecting `kvmd` when a client connects.
