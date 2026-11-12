#!/usr/bin/env bats
# CI shards of the bats suite (#522): every file in exactly one shard.

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SHARD="$ROOT/manage/test/shard.sh"
}

@test "shard: the four shards together list every bats file once" {
    cd "$ROOT"
    local all
    all="$(for i in 1 2 3 4; do bash "$SHARD" "$i" 4; done | LC_ALL=C sort)"
    [ "$all" = "$(LC_ALL=C ls -1 manage/test/*.bats | LC_ALL=C sort)" ]
    [ -z "$(printf '%s\n' "$all" | uniq -d)" ]
}

@test "shard: a shard is stable from one call to the next" {
    [ "$(bash "$SHARD" 2 4)" = "$(bash "$SHARD" 2 4)" ]
    [ -n "$(bash "$SHARD" 2 4)" ]
}

@test "shard: index out of range or not a number is refused" {
    run bash "$SHARD" 0 4
    [ "$status" -eq 2 ]
    run bash "$SHARD" 5 4
    [ "$status" -eq 2 ]
    run bash "$SHARD" x 4
    [ "$status" -eq 2 ]
    run bash "$SHARD"
    [ "$status" -eq 2 ]
}
