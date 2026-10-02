#!/usr/bin/env bash
#
# Tests for the LRC default-layer-plugin profile key, which records the
# plugin used by LRC layers that do not name one.
#

source $CEPH_ROOT/qa/standalone/ceph-helpers.sh

function run() {
    local dir=$1
    shift

    export CEPH_MON="127.0.0.1:7159" # git grep '\<7159\>' : there must be only one
    export CEPH_ARGS
    CEPH_ARGS+="--fsid=$(uuidgen) --auth_cluster_required=none --auth_service_required=none --auth_client_required=none "
    CEPH_ARGS+="--mon-host=$CEPH_MON "

    local funcs=${@:-$(set | sed -n -e 's/^\(TEST_[0-9a-z_]*\) .*/\1/p')}
    for func in $funcs ; do
        $func $dir || return 1
    done
}

# The v0.92 corpus was encoded before Tentacle, when LRC layers that do
# not name a plugin used jerasure. The non-regression tool checks it
# with default-layer-plugin=jerasure. Like the erasure-code workunit,
# clone the corpus when the source tree does not include it.
function TEST_lrc_corpus_v0_92() {
    local dir=$1
    local corpus=$CEPH_ROOT/ceph-erasure-code-corpus

    setup $dir || return 1
    if ! test -d $corpus/v0.92-988 ; then
        corpus=$dir/ceph-erasure-code-corpus
        git clone --depth 1 \
            https://github.com/ceph/ceph-erasure-code-corpus.git \
            $corpus || return 1
    fi
    corpus=$corpus/v0.92-988

    local count=0
    local d
    for d in "$corpus"/plugin=lrc\ * ; do
        local -a words
        read -a words <<< "$(basename "$d")"
        local args=(--stripe-width ${words[1]#stripe-width=})
        local p
        for p in "${words[@]:2}" ; do
            args+=(--parameter $p)
        done
        ceph_erasure_code_non_regression --erasure-code-dir $CEPH_LIB \
            --check --base $corpus --plugin lrc "${args[@]}" || return 1
        count=$((count + 1))
    done
    test $count = 18 || return 1

    teardown $dir || return 1
}

# Wait until each of the given OSDs has the osdmap of the given epoch.
function wait_for_osd_map() {
    local epoch=$1
    shift

    local id
    for id in "$@" ; do
        local newest=0
        local -i i
        for ((i = 0; i < 60; i++)) ; do
            newest=$(CEPH_ARGS='' ceph --admin-daemon \
                $(get_asok_path osd.$id) status | jq -r .newest_map)
            test "$newest" -ge $epoch && break
            sleep 1
        done
        test "$newest" -ge $epoch || return 1
    done
}

# Kill all OSDs at once, so that none of them persists a newer epoch for
# its PGs while the others go down, and start them again.
function restart_osds() {
    local dir=$1
    local count=$2
    shift 2

    kill_daemons $dir KILL osd || return 1
    ceph osd down $(seq 0 $((count - 1))) || return 1
    local id
    for id in $(seq 0 $((count - 1))) ; do
        activate_osd $dir $id "$@" || return 1
    done
    wait_for_clean || return 1
    for id in $(seq 0 $((count - 1))) ; do
        CEPH_ARGS='' ceph --admin-daemon $(get_asok_path osd.$id) \
            log flush || return 1
    done
}

# Stop the OSDs of shards 0 and 1 of obj. Both are in the first local
# group, so reading obj then decodes with the global layer and uses its
# second coding chunk, which jerasure and isa compute differently.
function kill_shards_0_1() {
    local dir=$1
    local poolname=$2

    local -a osds=($(get_osds $poolname obj))
    kill_daemons $dir KILL osd.${osds[0]} || return 1
    kill_daemons $dir KILL osd.${osds[1]} || return 1
    ceph osd down ${osds[0]} ${osds[1]} || return 1
    wait_for_peered || return 1
}

function read_obj() {
    local dir=$1
    local poolname=$2

    rm -f $dir/COPY
    timeout 120 rados --pool $poolname get obj $dir/COPY || return 1
    cmp $dir/ORIGINAL $dir/COPY || return 1
}

# Reading obj must fail with EIO or return other bytes. A read that
# times out or fails for another reason fails the test.
function read_obj_wrong() {
    local dir=$1
    local poolname=$2

    rm -f $dir/COPY
    if timeout 120 rados --pool $poolname get obj $dir/COPY \
            2> $dir/get.err ; then
        ! cmp -s $dir/ORIGINAL $dir/COPY || return 1
    else
        cat $dir/get.err
        grep -q 'Input/output error' $dir/get.err || return 1
    fi
}

# Wait until the daemon whose log has the given message has exited.
function wait_for_exit() {
    local dir=$1
    local name=$2
    local message="$3"

    local -i i
    for ((i = 0; i < 120; i++)) ; do
        grep -q "$message" $dir/$name.log && break
        sleep 1
    done
    grep -q "$message" $dir/$name.log || return 1
    kill_daemon $dir/$name.pid 0 || return 1
}

function TEST_lrc_layer_plugin_change_applies_on_restart() {
    local dir=$1
    local poolname=lrcpool
    local -a osd_args=(--osd-pg-epoch-persisted-max-stale=1000)
    local lrc="plugin=lrc k=4 m=2 l=3 crush-failure-domain=osd"

    setup $dir || return 1
    run_mon $dir a || return 1
    run_mgr $dir x || return 1
    local id
    for id in $(seq 0 7) ; do
        run_osd $dir $id "${osd_args[@]}" || return 1
    done

    ceph osd erasure-code-profile set p $lrc \
        default-layer-plugin=jerasure || return 1
    create_pool $poolname 1 1 erasure p || return 1
    wait_for_clean || return 1
    ceph osd set noout || return 1

    dd if=/dev/urandom of=$dir/ORIGINAL bs=1M count=1 || return 1
    rados --pool $poolname put obj $dir/ORIGINAL || return 1
    #
    # The PGs persist their epoch when osd.7 goes down and not again
    # before the restart. Without taking the layer plugin from the
    # newest map they would come back with jerasure.
    #
    # osd.7 is down when the value changes. It loads its PGs from a map
    # that predates the change, so it must shut down once it learns
    # about it, before it can use the old value.
    #
    kill_daemons $dir KILL osd.7 || return 1
    ceph osd down 7 || return 1
    ceph osd erasure-code-profile set p $lrc default-layer-plugin=isa \
        --force --yes-i-really-mean-it || return 1
    wait_for_osd_map $(ceph osd dump -f json | jq .epoch) $(seq 0 6) || return 1
    ceph osd set noup || return 1
    activate_osd $dir 7 "${osd_args[@]}" || return 1
    wait_for_exit $dir osd.7 \
        "default-layer-plugin=isa in osdmap e[0-9]* but its PGs were loaded with jerasure" || return 1
    ceph osd unset noup || return 1
    restart_osds $dir 8 "${osd_args[@]}" || return 1
    grep -q "using default-layer-plugin=isa from osdmap" $dir/osd.*.log || return 1
    #
    # obj was written with jerasure: decoding it with isa does not give
    # the original bytes back
    #
    local -a osds=($(get_osds $poolname obj))
    kill_shards_0_1 $dir $poolname || return 1
    read_obj_wrong $dir $poolname || return 1
    activate_osd $dir ${osds[0]} "${osd_args[@]}" || return 1
    activate_osd $dir ${osds[1]} "${osd_args[@]}" || return 1
    wait_for_clean || return 1
    #
    # back to jerasure: the same degraded read now succeeds
    #
    ceph osd erasure-code-profile set p $lrc default-layer-plugin=jerasure \
        --force --yes-i-really-mean-it || return 1
    wait_for_osd_map $(ceph osd dump -f json | jq .epoch) $(seq 0 7) || return 1
    restart_osds $dir 8 "${osd_args[@]}" || return 1
    grep -q "using default-layer-plugin=jerasure from osdmap" $dir/osd.*.log || return 1
    kill_shards_0_1 $dir $poolname || return 1
    read_obj $dir $poolname || return 1

    ceph osd unset noout || return 1
    teardown $dir || return 1
}

# The first monitor that records default-layer-plugin finds LRC
# profiles without it, written by older monitors. While no OSD has run
# Tentacle or later their layers were all encoded with jerasure, and the
# monitor records that.
function TEST_lrc_record_pre_tentacle() {
    local dir=$1
    local poolname=lrcpool
    local lrc="plugin=lrc k=4 m=2 l=3 crush-failure-domain=osd"

    setup $dir || return 1
    run_mon $dir a \
        --mon-debug-no-require-umbrella=true \
        --mon-debug-no-require-tentacle=true || return 1
    run_mgr $dir x || return 1
    ceph osd dump | grep 'require_osd_release squid' || return 1
    #
    # an older monitor creates the profile and the pool, before any OSD
    # is upgraded
    #
    ceph config set mon mon_debug_no_lrc_layer_plugin_record true || return 1
    ceph osd erasure-code-profile set p1 $lrc || return 1
    ! ceph osd erasure-code-profile get p1 | \
        grep default-layer-plugin || return 1
    create_pool $poolname 1 1 erasure p1 || return 1
    #
    # upgraded monitor: no OSD has booted, so jerasure is recorded
    #
    ceph config set mon mon_debug_no_lrc_layer_plugin_record false || return 1
    local -i i
    for ((i = 0; i < 60; i++)) ; do
        ceph osd erasure-code-profile get p1 | \
            grep default-layer-plugin=jerasure && break
        sleep 1
    done
    ceph osd erasure-code-profile get p1 | \
        grep default-layer-plugin=jerasure || return 1
    for ((i = 0; i < 30; i++)) ; do
        ceph log last 100 | grep "recorded default-layer-plugin=jerasure in erasure code profile 'p1'" && break
        sleep 1
    done
    ceph log last 100 | grep "recorded default-layer-plugin=jerasure in erasure code profile 'p1'" || return 1
    ceph osd erasure-code-profile get p1 > $dir/p1.before || return 1
    ceph osd erasure-code-profile set p1 $lrc || return 1
    ceph osd erasure-code-profile get p1 > $dir/p1.after || return 1
    diff $dir/p1.before $dir/p1.after || return 1
    #
    # the OSDs encode the pool with jerasure
    #
    local id
    for id in $(seq 0 7) ; do
        run_osd $dir $id || return 1
    done
    wait_for_clean || return 1
    local stripe_width=$(ceph osd pool ls detail -f json | \
        jq ".[] | select(.pool_name == \"$poolname\") | .stripe_width")
    local stripe_unit=$((stripe_width / 4))
    head -c $stripe_width /dev/urandom > $dir/obj || return 1
    rados --pool $poolname put obj $dir/obj || return 1
    local plugin
    for plugin in jerasure isa ; do
        ceph-erasure-code-tool encode \
            plugin=lrc,k=4,m=2,l=3,default-layer-plugin=$plugin \
            $stripe_unit 0,1,2,3,4,5,6,7 $dir/obj || return 1
        for id in $(seq 0 7) ; do
            mv $dir/obj.$id $dir/$plugin.$id || return 1
        done
    done
    local -a osds=($(get_osds $poolname obj))
    local differ=0
    local shard
    for shard in $(seq 0 7) ; do
        cmp -s $dir/jerasure.$shard $dir/isa.$shard && continue
        differ=$((differ + 1))
        objectstore_tool $dir ${osds[$shard]} obj get-bytes \
            > $dir/disk.$shard || return 1
        cmp $dir/disk.$shard $dir/jerasure.$shard || return 1
    done
    test $differ -gt 0 || return 1
    #
    # now that OSDs with the tentacle feature have booted, they may be
    # Tentacle releases that encode with isa: new profiles must set the
    # key, and isa is accepted because every up OSD has the feature.
    # Profiles without the key are left alone: their pools may have
    # been written with isa.
    #
    expect_failure $dir 'set default-layer-plugin explicitly' \
        ceph osd erasure-code-profile set p2 plugin=lrc k=2 m=2 l=2 \
        crush-failure-domain=osd || return 1
    ceph osd erasure-code-profile set p2 plugin=lrc k=2 m=2 l=2 \
        crush-failure-domain=osd default-layer-plugin=isa || return 1
    ceph osd erasure-code-profile get p2 | \
        grep default-layer-plugin=isa || return 1
    ceph config set mon mon_debug_no_lrc_layer_plugin_record true || return 1
    ceph osd erasure-code-profile set p3 $lrc || return 1
    ceph config set mon mon_debug_no_lrc_layer_plugin_record false || return 1
    sleep 15 # a few ticks
    ! ceph osd erasure-code-profile get p3 | \
        grep default-layer-plugin || return 1

    teardown $dir || return 1
}

main test-erasure-code-lrc-layer-plugin "$@"
