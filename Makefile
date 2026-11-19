# Builds the NTFS core (libntfs-3g + bridge) and the command line tools used
# for testing outside of FSKit. The Xcode project builds the same sources for
# the app extension.
NTFS3G  := Vendor/ntfs-3g
BUILD   := build
CC      := clang
CFLAGS  := -O2 -g -DHAVE_CONFIG_H -ICore -I$(NTFS3G)/include/ntfs-3g \
           -Wno-deprecated-declarations -Wno-address-of-packed-member -Wno-\#warnings
LIBSRC  := $(filter-out %/win32_io.c,$(wildcard $(NTFS3G)/libntfs-3g/*.c))
LIBOBJ  := $(patsubst $(NTFS3G)/libntfs-3g/%.c,$(BUILD)/lib/%.o,$(LIBSRC))
PROGSRC := $(addprefix $(NTFS3G)/ntfsprogs/,utils.c boot.c attrdef.c sd.c)
PROGINC := -I$(NTFS3G)/ntfsprogs -I$(NTFS3G)/include

all: $(BUILD)/ntfstool $(BUILD)/mkntfs $(BUILD)/ntfsfix

# Offline build + checks for the DiskArbitration fact sampler
# (Tools/da_qual_sample).
# offline-fixture mode only:
# no real DA session, no device stat, no mount query.
da-qual-offline: $(BUILD)/da_qual_sample
	bash Tools/da_qual_sample/offline-check.sh

$(BUILD)/da_qual_sample: Tools/da_qual_sample/main.swift
	@mkdir -p $(BUILD)
	xcrun swiftc -parse-as-library $< -o $@

# Offline check/repair engine self-test (检查卷/修复卷 → ntfstool → ntfsfix).
# Disposable file image under build/ only; never touches /Volumes, /Applications,
# /dev/disk*, or real USB media.
maint-repair-test: $(BUILD)/ntfstool $(BUILD)/device_path_rules_test
	NTFSTOOL="$(abspath $(BUILD)/ntfstool)" RULES_BIN="$(abspath $(BUILD)/device_path_rules_test)" \
	  bash Tools/maint-repair-selftest.sh

# ntfstool rejects unknown commands before opening the image (no
# read-write open/mount for a stale caller). Disposable image under build/.
ntfstool-cmd-test: $(BUILD)/ntfstool
	NTFSTOOL="$(abspath $(BUILD)/ntfstool)" bash Tools/ntfstool-cmd-selftest.sh

# Offline self-test for Tools/install.sh: recording stubs for xcodegen,
# xcodebuild, pkill, open and lsregister and a temporary install directory;
# never runs a product build and never touches /Applications.
install-script-test:
	bash Tools/install-selftest.sh

# Offline unit tests for the maintenance lease store / mount query / remount
# policy (Helper + Shared logic with injected effects: no real device node,
# journal file, timer, or mount-table query is touched).
lease-store-test: $(BUILD)/lease_store_test
	$(BUILD)/lease_store_test

# Scene-preservation self-check (failed tests keep their files): three deliberate modes run in
# SEPARATE processes; the runner verifies actual exit codes and on-disk
# scenes (kept with markers on failure, removed on success). Expected
# failures are judged here, not in the normal suite.
lease-store-scene-selfcheck: $(BUILD)/lease_store_test
	$(BUILD)/lease_store_test --scene-selfcheck

$(BUILD)/lease_store_test: Helper/DeviceLeaseStore.swift Helper/DeviceQualification.swift \
                           Shared/DevicePathRules.swift \
                           Shared/HelperConstants.swift Shared/MountQuery.swift \
                           Shared/MaintenancePolicy.swift Tools/lease_store_test_main.swift
	@mkdir -p $(BUILD)
	xcrun swiftc -parse-as-library $^ -o $@

$(BUILD)/device_path_rules_test: Shared/DevicePathRules.swift Tools/device_path_rules_main.swift
	@mkdir -p $(BUILD)
	xcrun swiftc -parse-as-library Shared/DevicePathRules.swift Tools/device_path_rules_main.swift -o $@

$(BUILD)/lib/%.o: $(NTFS3G)/libntfs-3g/%.c Core/config.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/libntfs-3g.a: $(LIBOBJ)
	libtool -static -o $@ $^

$(BUILD)/ntfs_bridge.o: Core/ntfs_bridge.c Core/ntfs_bridge.h Core/config.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -Wall -Wextra -c $< -o $@

# mkntfs and ntfsfix compiled to run in-process on a bridge device
MAINTDEFS := -DNTFS_MAINT
MAINTOBJ  := $(addprefix $(BUILD)/maint/,mkntfs.o ntfsfix.o utils.o boot.o attrdef.o sd.o ntfs_maint.o)

$(BUILD)/maint/mkntfs.o: $(NTFS3G)/ntfsprogs/mkntfs.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(PROGINC) $(MAINTDEFS) -Dmain=mkntfs_main -c $< -o $@
$(BUILD)/maint/ntfsfix.o: $(NTFS3G)/ntfsprogs/ntfsfix.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(PROGINC) $(MAINTDEFS) -Dmain=ntfsfix_main -c $< -o $@
$(BUILD)/maint/ntfs_maint.o: Core/ntfs_maint.c Core/ntfs_maint.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -Wall -Wextra -c $< -o $@
$(BUILD)/maint/%.o: $(NTFS3G)/ntfsprogs/%.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(PROGINC) $(MAINTDEFS) -c $< -o $@

$(BUILD)/ntfstool: Tools/ntfstool.c $(BUILD)/ntfs_bridge.o $(MAINTOBJ) $(BUILD)/libntfs-3g.a
	$(CC) -O2 -g -Wall -ICore $^ -o $@

$(BUILD)/mkntfs: $(NTFS3G)/ntfsprogs/mkntfs.c $(PROGSRC) $(BUILD)/libntfs-3g.a
	$(CC) $(CFLAGS) $(PROGINC) $^ -o $@

$(BUILD)/ntfsfix: $(NTFS3G)/ntfsprogs/ntfsfix.c $(NTFS3G)/ntfsprogs/utils.c $(BUILD)/libntfs-3g.a
	$(CC) $(CFLAGS) $(PROGINC) $^ -o $@

clean:
	rm -rf $(BUILD)

# Offline orchestration tests for the App maintenance flow (check/repair +
# post-maintenance remount + result composition). Compiles the REAL App
# sources with STRICT recording stubs installed through the production
# seams (Shell.runHook / MaintenanceHelperPort / MountQuery.probe /
# Mounter.waitHook / MountTable.entriesHook / mountRootOverride): no real
# command execution, no mount query, no App/Helper/NSXPC/DA startup, and no
# implicit product build (plain swiftc, no xcodebuild).
app-orchestration-test: $(BUILD)/app_orchestration_test
	$(BUILD)/app_orchestration_test

$(BUILD)/app_orchestration_test: App/Mounter.swift App/DiskMonitor.swift App/HelperClient.swift \
                                 Shared/DevicePathRules.swift Shared/HelperConstants.swift \
                                 Shared/HelperProtocol.swift Shared/MountQuery.swift \
                                 Shared/MaintenancePolicy.swift Shared/Localization.swift \
                                 Tools/app_orchestration_test_main.swift
	@mkdir -p $(BUILD)
	xcrun swiftc -parse-as-library $^ -o $@

# Deliberate-violation self-check for the orchestration harness: three
# failing modes run in SEPARATE processes; the runner verifies the unified
# stub acceptance actually catches them. Expected failures are judged here,
# not in the normal suite.
app-orchestration-stub-selfcheck: $(BUILD)/app_orchestration_test
	$(BUILD)/app_orchestration_test --stub-selfcheck

.PHONY: all clean maint-repair-test ntfstool-cmd-test install-script-test lease-store-test lease-store-scene-selfcheck app-orchestration-test app-orchestration-stub-selfcheck da-qual-offline

# Optional local targets. Tools/private.mk is not part of the source
# distribution; `-include` makes its absence a no-op.
-include Tools/private.mk
