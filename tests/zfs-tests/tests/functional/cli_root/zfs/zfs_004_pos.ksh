#!/bin/ksh -p
# SPDX-License-Identifier: CDDL-1.0
#
# CDDL HEADER START
#
# The contents of this file are subject to the terms of the
# Common Development and Distribution License (the "License").
# You may not use this file except in compliance with the License.
#
# You can obtain a copy of the license at usr/src/OPENSOLARIS.LICENSE
# or https://opensource.org/licenses/CDDL-1.0.
# See the License for the specific language governing permissions
# and limitations under the License.
#
# When distributing Covered Code, include this CDDL HEADER in each
# file and include the License file at usr/src/OPENSOLARIS.LICENSE.
# If applicable, add the following below this CDDL HEADER, with the
# fields enclosed by brackets "[]" replaced with your own identifying
# information: Portions Copyright [yyyy] [name of copyright owner]
#
# CDDL HEADER END
#

#
# Copyright (c) 2024 by OpenZFS contributors. All rights reserved.
#

. $STF_SUITE/include/libtest.shlib

#
# DESCRIPTION:
# Verify that 'zfs list' correctly lists many datasets (bulk iteration test).
# This tests the bulk dataset listing optimization that reduces syscall
# overhead when listing large numbers of datasets.
#
# STRATEGY:
# 1. Create a parent dataset
# 2. Create many child datasets (100+)
# 3. Create snapshots on some datasets
# 4. Run 'zfs list -r' and verify all datasets are returned
# 5. Verify the count matches expected
# 6. Verify sorting is correct
#

verify_runnable "both"

NUM_DATASETS=100
NUM_SNAPSHOTS=50

function cleanup
{
	datasetexists $TESTPOOL/$TESTFS/bulk && \
		destroy_dataset $TESTPOOL/$TESTFS/bulk -rRf
}

log_assert "Verify 'zfs list' correctly lists many datasets (bulk iteration)"
log_onexit cleanup

# Create parent dataset
log_must zfs create $TESTPOOL/$TESTFS/bulk

# Create many child datasets
log_note "Creating $NUM_DATASETS datasets..."
typeset -i i=0
while (( i < NUM_DATASETS )); do
	log_must zfs create $TESTPOOL/$TESTFS/bulk/ds_$(printf "%03d" $i)
	(( i = i + 1 ))
done

# Create snapshots on first NUM_SNAPSHOTS datasets
log_note "Creating $NUM_SNAPSHOTS snapshots..."
i=0
while (( i < NUM_SNAPSHOTS )); do
	log_must zfs snapshot $TESTPOOL/$TESTFS/bulk/ds_$(printf "%03d" $i)@snap1
	(( i = i + 1 ))
done

# Verify dataset count (parent + children)
((expected_datasets = NUM_DATASETS + 1))
actual_datasets=$(zfs list -H -r -t filesystem -o name $TESTPOOL/$TESTFS/bulk | wc -l)
log_note "Expected $expected_datasets filesystems, got $actual_datasets"
if (( actual_datasets != expected_datasets )); then
	log_fail "Dataset count mismatch: expected $expected_datasets, got $actual_datasets"
fi

# Verify snapshot count
actual_snapshots=$(zfs list -H -r -t snapshot -o name $TESTPOOL/$TESTFS/bulk | wc -l)
log_note "Expected $NUM_SNAPSHOTS snapshots, got $actual_snapshots"
if (( actual_snapshots != NUM_SNAPSHOTS )); then
	log_fail "Snapshot count mismatch: expected $NUM_SNAPSHOTS, got $actual_snapshots"
fi

# Verify all datasets with -t all
((expected_all = NUM_DATASETS + 1 + NUM_SNAPSHOTS))
actual_all=$(zfs list -H -r -t all -o name $TESTPOOL/$TESTFS/bulk | wc -l)
log_note "Expected $expected_all total (filesystems+snapshots), got $actual_all"
if (( actual_all != expected_all )); then
	log_fail "Total count mismatch: expected $expected_all, got $actual_all"
fi

# Verify first dataset in sorted order
first_ds=$(zfs list -H -r -t filesystem -o name $TESTPOOL/$TESTFS/bulk | head -1)
if [[ "$first_ds" != "$TESTPOOL/$TESTFS/bulk" ]]; then
	log_fail "First dataset should be parent: expected $TESTPOOL/$TESTFS/bulk, got $first_ds"
fi

# Verify a specific dataset exists in listing
log_must eval "zfs list -H -r -o name $TESTPOOL/$TESTFS/bulk | grep -q 'ds_050'"

# Verify a specific snapshot exists in listing
log_must eval "zfs list -H -r -t snapshot -o name $TESTPOOL/$TESTFS/bulk | grep -q 'ds_025@snap1'"

log_pass "Bulk dataset listing works correctly with $NUM_DATASETS datasets and $NUM_SNAPSHOTS snapshots"
