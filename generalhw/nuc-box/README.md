![Setup diagram](../openqa-qubesos-setup.png)

For details about how this setup works, see
[../adding-vnc-setup.md](../adding-vnc-setup.md).

### Prepare installation media

Make sure that an OTG drive containing the installation iso is connected to the
platform using the PiKVM. It can be done using the PiKVM web interface or the
console according to the instructions [PiKVM docs](https://docs.pikvm.org/msd/).

Boot into Dasharo UI and make sure that "PiKVM PiKVM Composite Device" is set
up to be the default boot entry. Save the configuration and only then start the
job. There's an issue, where openQA can't utilize the one-time boot menu with
the F7 key, so this step is done manually as of now.

### Start the job

While logged into openQA server (unless you've installed and configured
`openqa-cli` locally):

Perform installation followed by AEM testing:

```
openqa-cli api -X POST isos DISTRI=qubesos VERSION=4.2.3 ARCH=x86_64 BUILD=4.2.3 FLAVOR=install-iso-nuc-box CASEDIR="https://github.com/3mdeb/openqa-tests-qubesos.git" NEEDLES_DIR=%%CASEDIR%%/needles
```

ISO name is generated as `ISO=Qubes-R%BUILD%-%ARCH%.iso`, and a file with this
name needs to exist on the openQA worker, but in practice that file goes
unused. That file could well be empty, and the ISO image PiKVM presents to the
SUT will be actually used.

Output like

```
{"count":4,"failed":[],"ids":[448,449,450,451],"scheduled_product_id":59}
```

means the jobs (`4` in this case) were scheduled successfully.

Use "Dependencies" tab to see jobs which are part of the same run.

#### Parameters

These settings can be added to `openqa-cli` posting command to specify which
packages to use. By default the values defined in the settings of the
`aem-setup` test suite in `3mdeb-templates.json` are used.

* `PACKAGES_BASE_URL` - where to look for AEM-related packages.
* `AEM_VER` - version of `anti-evil-maid` package
* `GRUB_VER` - version of `grub2-*` packages
* `XEN_VER` - version of `xen-*` packages

### Verify the job

Because things sometimes don't work as expected, it's better to check that it
was able to start instead of incorrectly assuming that it did and seeing a quick
failure after coming back in half an hour.

Go to <http://openqa/tests>, open the running job and see that video is there
maybe in a minute or two after starting the job.  Restart the job if it has
failed to start for no good reason or video isn't working.

### Platform-specific notes

Several incomprehensible lockups and installation errors are likely to occur,
for example:
- Anaconda fails to start at all and the message `[FAILED] Failed to start
  anaconda.service - Anaconda.` appears,
- Anaconda crashes with only the "An unknown error has occurred" message
  present,
- Anaconda crashes with only the "Failed to remove old efi boot entry. This is
  most likely a kernel or firmware bug" message present,
- the installation phase gets stuck while trying to perform package
  configuration, always with the "alsa-sof-firmware" package. For more
  information see <https://github.com/QubesOS/qubes-issues/issues/8309>.

This platform comes with an NVMe drive. [The following
workaround](https://wiki.archlinux.org/index.php?title=Solid_state_drive/NVMe&oldid=863578#Controller_failure_due_to_broken_APST_support)
has been attempted to mitigate the issues. Some might nevertheless still arise
randomly.

If a test fails or gets stuck with one of those issues, restart it.

With Qubes OS 4.2.4's `kernel` (not `kernel-latest`), the
`i915.force_probe=7dd5` option was needed after the installation phase was
complete. Otherwise after the initial setup has finished, the graphics device
was not usable.
