# CAAS UEFI installer image builder

Run `vendor/intel/utils_vertical/tools/make_caas.sh [flashfiles.zip]` from a
Celadon checkout. The script locates the checkout relative to its installed
path. With no argument it reads the existing caas userdebug flashfiles archive.
An explicit archive can be provided for other build variants.

The builder creates `out/target/product/caas/caas-installer.img`, recreates its
installer-media-work directory, creates a GPT/ESP image, and uses loop devices
and mounts while assembling it. Review the target paths and provide the host
privileges required for those operations. It does not flash a physical disk.

This is the existing local installer script archived into Git. Syntax checks
do not establish that an image made by it boots successfully.
