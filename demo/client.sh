#!/bin/sh
set -eu

action='__ACTION__'
server='__SERVER__'
demo_id='__DEMO_ID__'
mount_root='__MOUNT_ROOT__'
source="$server:/demo"
data_dir="$mount_root/customer-demo"
file="$data_dir/example.txt"
snapshot_file="$mount_root/.snapshot/demo-baseline/customer-demo/example.txt"
original='ANF demo: original customer data'
changed='ANF demo: changed during presentation'

fail() { printf '%s\n' "$*" >&2; exit 1; }
assert_mount() {
    mountpoint -q "$mount_root" || fail 'Run Prepare first: demo volume is not mounted.'
    actual=$(findmnt -rn -M "$mount_root" -o SOURCE)
    [ "$actual" = "$source" ] || fail "Unexpected mount source: $actual"
    filesystem=$(findmnt -rn -M "$mount_root" -o FSTYPE)
    [ "$filesystem" = nfs ] || fail "Unexpected filesystem: $filesystem"
}
assert_demo() {
    [ ! -L "$data_dir" ] && [ ! -L "$file" ] && [ ! -L "$data_dir/.anf-demo-id" ] ||
        fail 'Symbolic links are not supported in demo data.'
    [ -f "$data_dir/.anf-demo-id" ] || fail 'Demo data is not initialized; run Prepare.'
    [ "$(cat "$data_dir/.anf-demo-id")" = "$demo_id" ] || fail 'Demo data belongs to another DemoId.'
    [ -f "$file" ] || fail 'Example file is missing; inspect the demo data before continuing.'
}
assert_snapshot() {
    # Snapshot visibility can lag behind successful control-plane provisioning.
    attempt=0
    until [ -f "$snapshot_file" ]; do
        attempt=$((attempt + 1))
        [ "$attempt" -le 12 ] || fail 'Snapshot file is not visible; verify demo-baseline and snapshot directory visibility.'
        sleep 5
    done
    [ "$(cat "$snapshot_file")" = "$original" ] || fail 'Snapshot does not contain the expected original data.'
    [ ! -L "$snapshot_file" ] || fail 'Snapshot example must be a regular file, not a symbolic link.'
    [ "$(cat "$mount_root/.snapshot/demo-baseline/customer-demo/.anf-demo-id")" = "$demo_id" ] ||
        fail 'Snapshot belongs to another DemoId.'
}
show_file() {
    printf '\n%s\n' "$file"
    cat "$file"
    sha256sum "$file"
}

case "$action" in
    Prepare)
        if command -v cloud-init >/dev/null 2>&1; then
            timeout 300 cloud-init status --wait || fail 'cloud-init did not finish successfully.'
        fi
        if ! command -v mount.nfs >/dev/null 2>&1; then
            export DEBIAN_FRONTEND=noninteractive
            timeout 300 apt-get -o APT::Update::Error-Mode=any -o DPkg::Lock::Timeout=120 update
            timeout 300 apt-get -o DPkg::Lock::Timeout=120 install -y --no-install-recommends nfs-common
        fi
        [ ! -L "$mount_root" ] || fail 'Mount directory must not be a symbolic link.'
        mkdir -p "$mount_root"
        if ! mountpoint -q "$mount_root"; then
            [ -z "$(ls -A "$mount_root")" ] || fail 'Mount directory is not empty; refusing to hide local files.'
            timeout 90 mount -t nfs -o vers=3,proto=tcp,sec=sys "$source" "$mount_root"
        fi
        assert_mount
        if [ ! -e "$data_dir" ]; then
            mkdir "$data_dir"
            printf '%s\n' "$original" > "$file"
            printf '%s\n' "$demo_id" > "$data_dir/.anf-demo-id"
            sync
        fi
        assert_demo
        show_file
        ;;
    Check)
        assert_mount
        assert_demo
        [ "$(cat "$file")" = "$original" ] || fail 'Snapshot baseline requires the original example content.'
        sync
        show_file
        ;;
    Change)
        assert_mount
        assert_demo
        assert_snapshot
        printf '%s\n' "$changed" > "$file"
        sync
        show_file
        ;;
    Restore)
        assert_mount
        assert_demo
        assert_snapshot
        cp "$snapshot_file" "$file"
        sync
        cmp "$snapshot_file" "$file" || fail 'Restored file differs from the snapshot.'
        show_file
        ;;
    *) fail "Unsupported client action: $action" ;;
esac
printf '\nANF_DEMO_OK:__ACTION__:__RUN_ID__\n'
