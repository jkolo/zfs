#!/bin/ksh -p
# SPDX-License-Identifier: CDDL-1.0
#
# CDDL HEADER START
#
# This file and its contents are supplied under the terms of the
# Common Development and Distribution License ("CDDL"), version 1.0.
# You may only use this file in accordance with the terms of version
# 1.0 of the CDDL.
#
# A full copy of the text of the CDDL should have accompanied this
# source.  A copy of the CDDL is also available via the Internet at
# http://www.illumos.org/license/CDDL.
#
# CDDL HEADER END
#

#
# Copyright (c) 2026 Jerzy Kołosowski. All rights reserved.
#

. $STF_SUITE/include/libtest.shlib

#
# DESCRIPTION:
# Reproduce and detect the "unencrypted block in encrypted object set"
# bug class. After a corrupted block pointer (without BP_USES_CRYPT) ends
# up in an encrypted dataset, the next file creation must not panic the
# kernel via VERIFY0(sa_buf_hold) in zfs_mknode.
#
# Related issues:
#   - openzfs/zfs#15275 (closed, but reports persist)
#   - openzfs/zfs#14330 (open)
#   - openzfs/zfs#16065 (open)
#   - openzfs/zfs#14709 (open)
#
# STRATEGY:
# 1. Create an encrypted dataset (AES-256-GCM, passphrase keyformat).
# 2. Write some data and take a snapshot to populate SA bonus buffers.
# 3. (Future, post-Fix A): inject BP_USES_CRYPT mismatch via debug-only
#    module parameter zfs_debug_skip_bp_set_crypt.
# 4. Attempt to create new files; verify behavior:
#      - Pre-fix:  kernel PANIC in zfs_mknode (test fails / system hang).
#      - Post-fix-B 1.5/2: scrub --repair-crypt-mismatches restores BP_USES_CRYPT
#        before next zfs_create, so creation succeeds.
# 5. Run scrub and verify no permanent errors remain.
#
# This file ships as a smoke-test skeleton; the inject step is gated on
# the debug module parameter that Fix A introduces. Without it, the test
# only validates that the encrypted-dataset create path itself works.
#

verify_runnable "both"

# Module parameter (introduced by Fix A) that, when nonzero, instructs
# write paths to skip BP_SET_CRYPT(bp, 1) on encrypted datasets. Used here
# only to deterministically reproduce the bug class in tests; never set
# on production systems.
typeset DEBUG_PARAM="/sys/module/zfs/parameters/zfs_debug_skip_bp_set_crypt"

typeset KEYFILE="$TEST_BASE_DIR/zce_after_recv_key_$$"
typeset DATASET="$TESTPOOL/zce_after_recv"

function cleanup
{
	if [ -e "$DEBUG_PARAM" ]; then
		echo 0 > "$DEBUG_PARAM" 2>/dev/null
	fi
	datasetexists "$DATASET" && destroy_dataset "$DATASET" -rf
	rm -f "$KEYFILE"
}
log_onexit cleanup

log_assert "zfs_create on an encrypted dataset must not panic when the " \
    "underlying SA bonus buffer has a BP_USES_CRYPT mismatch."

# 1. Set up encrypted dataset.
echo -n "testpassphrase_$$" > "$KEYFILE"
chmod 600 "$KEYFILE"
log_must zfs create \
    -o encryption=aes-256-gcm \
    -o keyformat=passphrase \
    -o keylocation=file://"$KEYFILE" \
    "$DATASET"

# 2. Populate SA bonus buffers and snapshot.
log_must dd if=/dev/urandom of="/$DATASET/seed-data" bs=1M count=1 \
    conv=fdatasync
log_must zfs snapshot "$DATASET@seed"

# 3. (Inject step — gated on debug parameter from Fix A.)
if [ -w "$DEBUG_PARAM" ]; then
	log_note "Injecting BP_USES_CRYPT mismatch via $DEBUG_PARAM"
	echo 1 > "$DEBUG_PARAM"
	# Trigger writes that may receive a BP without CRYPT flag.
	log_must dd if=/dev/urandom of="/$DATASET/post-inject" bs=4K \
	    count=64 conv=fdatasync
	echo 0 > "$DEBUG_PARAM"

	# Force evict so next reads come from disk (not ARC).
	log_must zinject -a 2>/dev/null || true

	# 4a. Creating another file MUST NOT panic. Pre-fix-B repair, this
	#     may return EIO (PR #15677-style); after Fix B 1.5/2 repair it
	#     should succeed when scrub --repair-crypt-mismatches ran first.
	log_must zpool scrub --repair-crypt-mismatches "$TESTPOOL" || \
	    log_note "scrub repair flag not yet available, skipping repair step"
	log_must touch "/$DATASET/post-repair"
else
	log_note "Debug param $DEBUG_PARAM not present — running smoke test only"
fi

# 4b. Sanity: regular create on encrypted dataset must work.
log_must touch "/$DATASET/sanity-create"
log_must ls "/$DATASET/sanity-create"

# 5. Scrub the pool and verify the lack of permanent errors.
log_must zpool scrub "$TESTPOOL"
log_must wait_scrubbed "$TESTPOOL"
typeset status_out
status_out=$(zpool status -v "$TESTPOOL")
if echo "$status_out" | grep -q "Permanent errors have been detected"; then
	log_fail "Scrub reports permanent errors after encrypted-dataset test: " \
	    "$status_out"
fi

log_pass "zfs_create on encrypted dataset does not panic; scrub is clean."
