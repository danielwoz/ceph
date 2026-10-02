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

main test-erasure-code-lrc-layer-plugin "$@"
