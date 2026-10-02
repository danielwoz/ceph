#!/usr/bin/env bash
#
# Copyright (C) 2014 Cloudwatt <libre.licensing@cloudwatt.com>
# Copyright (C) 2014, 2015 Red Hat <contact@redhat.com>
#
# Author: Loic Dachary <loic@dachary.org>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU Library Public License as published by
# the Free Software Foundation; either version 2, or (at your option)
# any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Library Public License for more details.
#
source $CEPH_ROOT/qa/standalone/ceph-helpers.sh

function run() {
    local dir=$1
    shift

    export CEPH_MON="127.0.0.1:7220" # git grep '\<7220\>' : there must be only one
    export CEPH_ARGS
    CEPH_ARGS+="--fsid=$(uuidgen) --auth_cluster_required=none --auth_service_required=none --auth_client_required=none "
    CEPH_ARGS+="--mon-host=$CEPH_MON "

    local funcs=${@:-$(set | sed -n -e 's/^\(TEST_[0-9a-z_]*\) .*/\1/p')}
    for func in $funcs ; do
        setup $dir || return 1
        $func $dir || return 1
        teardown $dir || return 1
    done
}

function TEST_set() {
    local dir=$1
    local id=$2

    run_mon $dir a || return 1

    local profile=myprofile
    #
    # no key=value pairs : use the default configuration
    #
    ceph osd erasure-code-profile set $profile 2>&1 || return 1
    ceph osd erasure-code-profile get $profile | \
        grep plugin=isa || return 1
    ceph osd erasure-code-profile rm $profile
    #
    # key=value pairs override the default
    #
    ceph osd erasure-code-profile set $profile \
        key=value plugin=jerasure || return 1
    ceph osd erasure-code-profile get $profile | \
        grep -e key=value -e plugin=jerasure || return 1
    #
    # --force & --yes-i-really-mean-it are required to override
    # an existing profile
    #
    ! ceph osd erasure-code-profile set $profile > $dir/out 2>&1 || return 1
    grep 'will not override' $dir/out || return 1
    ceph osd erasure-code-profile set $profile key=other --force --yes-i-really-mean-it || return 1
    ceph osd erasure-code-profile get $profile | \
        grep key=other || return 1

    ceph osd erasure-code-profile rm $profile # cleanup
}

function TEST_ls() {
    local dir=$1
    local id=$2

    run_mon $dir a || return 1

    local profile=myprofile
    ! ceph osd erasure-code-profile ls | grep $profile || return 1
    ceph osd erasure-code-profile set $profile 2>&1 || return 1
    ceph osd erasure-code-profile ls | grep $profile || return 1
    ceph --format xml osd erasure-code-profile ls | \
        grep "<profile>$profile</profile>" || return 1

    ceph osd erasure-code-profile rm $profile # cleanup
}

function TEST_rm() {
    local dir=$1
    local id=$2

    run_mon $dir a || return 1

    local profile=myprofile
    ceph osd erasure-code-profile set $profile 2>&1 || return 1
    ceph osd erasure-code-profile ls | grep $profile || return 1
    ceph osd erasure-code-profile rm $profile || return 1
    ! ceph osd erasure-code-profile ls | grep $profile || return 1
    ceph osd erasure-code-profile rm WRONG 2>&1 | \
        grep "WRONG does not exist" || return 1

    ceph osd erasure-code-profile set $profile || return 1
    create_pool poolname 12 12 erasure $profile || return 1
    ! ceph osd erasure-code-profile rm $profile > $dir/out 2>&1 || return 1
    grep "poolname.*using.*$profile" $dir/out || return 1
    ceph osd pool delete poolname poolname --yes-i-really-really-mean-it || return 1
    ceph osd erasure-code-profile rm $profile || return 1

    ceph osd erasure-code-profile rm $profile # cleanup
}

function TEST_get() {
    local dir=$1
    local id=$2

    run_mon $dir a || return 1

    local default_profile=default
    ceph osd erasure-code-profile get $default_profile | \
        grep plugin=isa || return 1
    ceph --format xml osd erasure-code-profile get $default_profile | \
        grep '<plugin>isa</plugin>' || return 1
    ! ceph osd erasure-code-profile get WRONG > $dir/out 2>&1 || return 1
    grep -q "unknown erasure code profile 'WRONG'" $dir/out || return 1
}

function TEST_set_idempotent() {
    local dir=$1
    local id=$2

    run_mon $dir a || return 1
    #
    # The default profile is set using a code path different from
    # ceph osd erasure-code-profile set: verify that it is idempotent,
    # as if it was using the same code path.
    #
    ceph osd erasure-code-profile set default k=2 m=2 2>&1 || return 1
    local profile
    #
    # Because plugin=jerasure is the default, it uses a slightly
    # different code path where defaults (m=1 for instance) are added
    # implicitly.
    #
    profile=profileidempotent1
    ! ceph osd erasure-code-profile ls | grep $profile || return 1
    ceph osd erasure-code-profile set $profile k=2 crush-failure-domain=osd 2>&1 || return 1
    ceph osd erasure-code-profile ls | grep $profile || return 1
    ceph osd erasure-code-profile set $profile k=2 crush-failure-domain=osd 2>&1 || return 1
    ceph osd erasure-code-profile rm $profile # cleanup

    #
    # In the general case the profile is exactly what is on
    #
    profile=profileidempotent2
    ! ceph osd erasure-code-profile ls | grep $profile || return 1
    ceph osd erasure-code-profile set $profile plugin=lrc k=4 m=2 l=3 crush-failure-domain=osd 2>&1 || return 1
    ceph osd erasure-code-profile ls | grep $profile || return 1
    ceph osd erasure-code-profile set $profile plugin=lrc k=4 m=2 l=3 crush-failure-domain=osd 2>&1 || return 1
    ceph osd erasure-code-profile rm $profile # cleanup
}

function TEST_format_invalid() {
    local dir=$1

    local profile=profile
    # osd_pool_default_erasure-code-profile is
    # valid JSON but not of the expected type
    run_mon $dir a \
        --osd_pool_default_erasure-code-profile 1 || return 1
    ! ceph osd erasure-code-profile set $profile > $dir/out 2>&1 || return 1
    cat $dir/out
    grep 'must be a JSON object' $dir/out || return 1
}

function TEST_format_json() {
    local dir=$1

    # osd_pool_default_erasure-code-profile is JSON
    expected='"plugin":"isa"'
    run_mon $dir a \
        --osd_pool_default_erasure-code-profile "{$expected}" || return 1
    ceph --format json osd erasure-code-profile get default | \
        grep "$expected" || return 1
}

function TEST_format_plain() {
    local dir=$1

    # osd_pool_default_erasure-code-profile is plain text
    expected='"plugin":"isa"'
    run_mon $dir a \
        --osd_pool_default_erasure-code-profile "plugin=isa" || return 1
    ceph --format json osd erasure-code-profile get default | \
        grep "$expected" || return 1
}

function TEST_profile_k_sanity() {
    local dir=$1
    local profile=profile-sanity

    run_mon $dir a || return 1

    expect_failure $dir 'k must be a multiple of (k + m) / l' \
        ceph osd erasure-code-profile set $profile \
        plugin=lrc \
        l=1 \
        k=1 \
        m=1 || return 1

    if erasure_code_plugin_exists isa ; then
        expect_failure $dir 'k=1 must be >= 2' \
            ceph osd erasure-code-profile set $profile \
            plugin=isa \
            k=1 \
            m=1 || return 1
    else
        echo "SKIP because plugin isa has not been built"
    fi

    expect_failure $dir 'k=1 must be >= 2' \
        ceph osd erasure-code-profile set $profile \
        plugin=jerasure \
        k=1 \
        m=1 || return 1
}

function TEST_invalid_crush_failure_domain() {
    local dir=$1

    run_mon $dir a || return 1

    local profile=ec_profile
    local crush_failure_domain=invalid_failure_domain

    ! ceph osd erasure-code-profile set $profile k=4 m=2 crush-failure-domain=$crush_failure_domain 2>&1 || return 1
}

function TEST_lrc_default_layer_plugin() {
    local dir=$1

    local lrc="plugin=lrc k=4 m=2 l=3 crush-failure-domain=osd"
    run_mon $dir a \
        --osd_pool_default_erasure-code-profile "$lrc" || return 1
    #
    # require_osd_release is tentacle or later: a new LRC profile
    # records isa for the layers that do not name a plugin
    #
    ceph osd erasure-code-profile get default | \
        grep default-layer-plugin=isa || return 1
    ceph osd erasure-code-profile set p $lrc || return 1
    ceph osd erasure-code-profile get p | \
        grep default-layer-plugin=isa || return 1
    ceph osd erasure-code-profile set p $lrc || return 1
    #
    # an explicit value is kept and re-applying the profile without it
    # keeps the recorded value
    #
    ceph osd erasure-code-profile set q $lrc \
        default-layer-plugin=jerasure || return 1
    ceph osd erasure-code-profile get q | \
        grep default-layer-plugin=jerasure || return 1
    ceph osd erasure-code-profile set q $lrc || return 1
    ceph osd erasure-code-profile get q | \
        grep default-layer-plugin=jerasure || return 1
    #
    # changing it is an override
    #
    expect_failure $dir 'will not override' \
        ceph osd erasure-code-profile set q $lrc \
        default-layer-plugin=isa || return 1
    expect_failure $dir 'DANGEROUS' \
        ceph osd erasure-code-profile set q $lrc \
        default-layer-plugin=isa --force || return 1
    ceph osd erasure-code-profile set q $lrc default-layer-plugin=isa \
        --force --yes-i-really-mean-it > $dir/out 2>&1 || return 1
    grep 'restart the OSDs' $dir/out || return 1
    ceph osd erasure-code-profile get q | \
        grep default-layer-plugin=isa || return 1

    expect_failure $dir 'must be jerasure or isa' \
        ceph osd erasure-code-profile set r $lrc \
        default-layer-plugin=bogus || return 1
    #
    # a profile that was not LRC has no LRC pools: overriding it
    # records the layer plugin as for a new profile
    #
    ceph osd erasure-code-profile set j plugin=jerasure k=2 m=1 || return 1
    ceph osd erasure-code-profile set j $lrc \
        --force --yes-i-really-mean-it || return 1
    ceph osd erasure-code-profile get j | \
        grep default-layer-plugin=isa || return 1
    #
    # a profile without the key, as created by monitors that do not
    # record it, stays without it until isa or jerasure is set
    # explicitly; isa does not need --force because it changes nothing
    #
    ceph config set mon mon_debug_no_lrc_layer_plugin_record true || return 1
    ceph osd erasure-code-profile set s $lrc || return 1
    ceph config set mon mon_debug_no_lrc_layer_plugin_record false || return 1
    ! ceph osd erasure-code-profile get s | \
        grep default-layer-plugin || return 1
    ceph osd erasure-code-profile set s $lrc || return 1
    ! ceph osd erasure-code-profile get s | \
        grep default-layer-plugin || return 1
    expect_failure $dir 'will not override' \
        ceph osd erasure-code-profile set s $lrc \
        default-layer-plugin=jerasure || return 1
    ceph osd erasure-code-profile set s $lrc default-layer-plugin=isa \
        > $dir/out 2>&1 || return 1
    grep 'recorded default-layer-plugin=isa' $dir/out || return 1
    ceph osd erasure-code-profile get s | \
        grep default-layer-plugin=isa || return 1
}

function TEST_lrc_default_layer_plugin_pre_tentacle() {
    local dir=$1

    local lrc="plugin=lrc k=4 m=2 l=3 crush-failure-domain=osd"
    run_mon $dir a \
        --mon-debug-no-require-umbrella=true \
        --mon-debug-no-require-tentacle=true \
        --osd_pool_default_erasure-code-profile "$lrc" || return 1
    ceph osd dump | grep 'require_osd_release squid' || return 1
    #
    # OSDs older than tentacle use jerasure for the layers that do not
    # name a plugin and ignore the key
    #
    ceph osd erasure-code-profile get default | \
        grep default-layer-plugin=jerasure || return 1
    ceph osd erasure-code-profile set p $lrc || return 1
    ceph osd erasure-code-profile get p | \
        grep default-layer-plugin=jerasure || return 1
    expect_failure $dir 'require_osd_release tentacle' \
        ceph osd erasure-code-profile set q $lrc \
        default-layer-plugin=isa || return 1
    #
    # the default profile records it too when it is created on demand
    #
    ceph osd erasure-code-profile rm default || return 1
    ceph osd crush rule create-erasure lrcrule || return 1
    ceph osd erasure-code-profile get default | \
        grep default-layer-plugin=jerasure || return 1
    ceph osd crush rule rm lrcrule || return 1
    ceph osd erasure-code-profile rm default || return 1
    ceph osd pool create lrcpool 1 1 erasure || return 1
    ceph osd erasure-code-profile get default | \
        grep default-layer-plugin=jerasure || return 1
    #
    # the commands recorded it themselves, not the leader
    #
    sleep 15
    ! ceph log last 100 | \
        grep "recorded default-layer-plugin=jerasure in erasure code profile 'default'" || return 1
    #
    # once an OSD running Tentacle or later has booted, a new profile
    # may be used by OSDs that encode with isa: it must set the key
    #
    run_osd $dir 0 || return 1
    expect_failure $dir 'set default-layer-plugin explicitly' \
        ceph osd erasure-code-profile set r $lrc || return 1
    ceph osd erasure-code-profile set r $lrc \
        default-layer-plugin=isa || return 1
    ceph osd erasure-code-profile set s $lrc \
        default-layer-plugin=jerasure || return 1
    ceph osd erasure-code-profile set p $lrc || return 1
    ceph osd erasure-code-profile get p | \
        grep default-layer-plugin=jerasure || return 1
}

function TEST_lrc_layer_plugin_unset_health() {
    local dir=$1

    run_mon $dir a || return 1

    local lrc="plugin=lrc k=4 m=2 l=3 crush-failure-domain=osd"
    #
    # a pool created by monitors that do not record the layer plugin
    #
    ceph config set mon mon_debug_no_lrc_layer_plugin_record true || return 1
    ceph osd erasure-code-profile set p3 $lrc || return 1
    ! ceph osd erasure-code-profile get p3 | \
        grep default-layer-plugin || return 1
    create_pool lrcpool 4 4 erasure p3 || return 1
    ceph config set mon mon_debug_no_lrc_layer_plugin_record false || return 1
    wait_for_health POOL_LRC_LAYER_PLUGIN_UNSET || return 1
    ceph health detail > $dir/health || return 1
    grep "pool 'lrcpool' (erasure code profile 'p3', created " \
        $dir/health || return 1
    #
    # re-applying the profile does not record anything
    #
    ceph osd erasure-code-profile set p3 $lrc || return 1
    ! ceph osd erasure-code-profile get p3 | \
        grep default-layer-plugin || return 1
    expect_failure $dir 'will not override' \
        ceph osd erasure-code-profile set p3 $lrc \
        default-layer-plugin=jerasure || return 1
    #
    # recording isa changes nothing and clears the warning
    #
    ceph osd erasure-code-profile set p3 $lrc default-layer-plugin=isa \
        > $dir/out 2>&1 || return 1
    grep 'recorded default-layer-plugin=isa' $dir/out || return 1
    wait_for_health_gone POOL_LRC_LAYER_PLUGIN_UNSET || return 1
    #
    # the warning can be disabled
    #
    ceph config set mon mon_debug_no_lrc_layer_plugin_record true || return 1
    ceph osd erasure-code-profile set p4 $lrc || return 1
    create_pool lrcpool2 4 4 erasure p4 || return 1
    ceph config set mon mon_debug_no_lrc_layer_plugin_record false || return 1
    wait_for_health "pool 'lrcpool2'" || return 1
    ceph config set mon mon_warn_on_lrc_layer_plugin_unset false || return 1
    # the check runs when the next osdmap is proposed
    ceph osd pool application enable lrcpool2 rados || return 1
    wait_for_health_gone POOL_LRC_LAYER_PLUGIN_UNSET || return 1
}

main osd-erasure-code-profile "$@"

# Local Variables:
# compile-command: "cd ../.. ; make -j4 && test/mon/osd-erasure-code-profile.sh"
# End:
