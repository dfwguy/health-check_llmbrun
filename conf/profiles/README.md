# Platform profiles

A profile supplies the two things that change between platforms: rack geometry
and NCCL bandwidth floors. `conf/cluster.conf` sources the selected profile, so
`conf/workloads.conf` can reference `$NCCL_FLOOR_*` without knowing the platform.

Anything set in `cluster.conf` *after* the profile line overrides the profile.

To add a platform, copy the closest file and edit. Floors should be roughly 90%
of what a known-good rack of that platform actually achieves — measure first,
then set them. `generic.conf` deliberately ships with no floors so a new cluster
scores on completion plus the fleet-relative outlier gate until you calibrate.
