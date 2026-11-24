# SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Shortcuts around scripts/ (the scripts stay the real thing; CI runs them).
#
#   make packages       scripts/package.sh here (macOS: dmg + Linux packages + SDKs;
#                       Linux: the Linux packages + SDKs)
#   make mac-pack       the Linux packages, built inside the multipass VM $(VM):
#                       this folder mounted at $(VM_DIR), `make packages` run
#                       there; they land in dist/ here. Version: the latest
#                       stable release's (GitHub), or GTTY_VERSION=1.2.3.
#                       SKIP_BUILD=1 packages the binaries already in bin/.
#   make vm-repo-test   the apt / rpm repositories end to end in the VM
#                       (scripts/test-repo.sh: throwaway key, the packages of
#                       bin/linux* from mac-pack, install + update in Debian /
#                       Ubuntu / Fedora / Rocky / openSUSE containers)
#   make vm-setup       mount + install what the VM needs (zig, nfpm, ImageMagick)
#   make vm-shell       a shell in the VM, in the mounted folder
#   make vm-mount       the mount alone; vm-unmount undoes it
#
# Override with make VM=name VM_DIR=/path ….

VM ?= u
VM_DIR ?= /mnt/gtty
# Files here as the VM's user (1000), else the VM can't read them: this
# user's ids, or 99 ("unknown") on a volume with "ignore ownership" on
# (diskutil info: Owners Disabled), which is what multipassd (root) sees.
VM_OWNERS := $(shell diskutil info "$$(df -P . | awk 'END {print $$6}')" 2>/dev/null | awk '/Owners:/ {print $$2}')
VM_MAPS = $(if $(filter Disabled,$(VM_OWNERS)),-u 99:1000 -g 99:1000,-u $(shell id -u):1000 -g $(shell id -g):1000)
# The latest stable release's version (v1.16.1 → 1.16.1), asked when used.
GTTY_VERSION ?= $(shell curl -fsS https://api.github.com/repos/tesselix/gtty/releases/latest | sed -n 's/^ *"tag_name": *"v\([^"]*\)".*/\1/p')
# Zig's own cache in the VM's disk: the mounted .zig-cache is macOS's.
VM_ENV = env GTTY_VERSION=$(GTTY_VERSION) SKIP_BUILD=$(SKIP_BUILD) ZIG_LOCAL_CACHE_DIR=/home/ubuntu/.cache/gtty-zig-local

.PHONY: packages vm-mount vm-setup mac-pack vm-repo-test vm-shell vm-unmount

packages:
	scripts/package.sh

# A native mount (9p), not multipass's default (sshfs): sshfs lists every
# file with an unknown type, and Zig skips those (SDL's headers never got
# copied: "SDL3/SDL.h file not found"). Native mounts need the VM stopped,
# so the first mount stops and starts it.
vm-mount:
	@multipass info $(VM) >/dev/null
	@multipass exec $(VM) -- sh -c 'mount | grep -q " on $(VM_DIR) type 9p "' 2>/dev/null || { \
		echo "mounting $(CURDIR) on $(VM):$(VM_DIR) (native: $(VM) restarts)"; \
		multipass umount "$(VM):$(VM_DIR)" 2>/dev/null; \
		multipass stop $(VM) && \
		multipass mount --type native $(VM_MAPS) "$(CURDIR)" "$(VM):$(VM_DIR)" && \
		multipass start $(VM); }

vm-setup: vm-mount
	multipass exec $(VM) --working-directory $(VM_DIR) -- sh scripts/vm-setup.sh

mac-pack: vm-mount
	@[ -n "$(GTTY_VERSION)" ] || { echo "no version: GitHub didn't answer; set GTTY_VERSION=…" >&2; exit 1; }
	multipass exec $(VM) --working-directory $(VM_DIR) -- $(VM_ENV) make packages

vm-repo-test: vm-mount
	@[ -n "$(GTTY_VERSION)" ] || { echo "no version: GitHub didn't answer; set GTTY_VERSION=…" >&2; exit 1; }
	multipass exec $(VM) --working-directory $(VM_DIR) -- env GTTY_VERSION=$(GTTY_VERSION) bash scripts/test-repo.sh

vm-shell: vm-mount
	multipass exec $(VM) --working-directory $(VM_DIR) -- bash -l

vm-unmount:
	multipass umount "$(VM):$(VM_DIR)"
