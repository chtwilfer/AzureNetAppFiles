#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fixture=$(mktemp -d)
trap 'find "$fixture" -depth -type f -delete; find "$fixture" -depth -type d -empty -delete' 0
mkdir "$fixture/bin" "$fixture/share"
export DEMO_FIXTURE="$fixture"
export DEMO_SOURCE='10.42.2.4:/demo'
export DEMO_FSTYPE=nfs
export PATH="$fixture/bin:$PATH"

cat > "$fixture/bin/mountpoint" <<'STUB'
#!/bin/sh
[ -f "$DEMO_FIXTURE/mounted" ]
STUB
cat > "$fixture/bin/findmnt" <<'STUB'
#!/bin/sh
case "$*" in
    *SOURCE*) printf '%s\n' "$DEMO_SOURCE" ;;
    *FSTYPE*) printf '%s\n' "$DEMO_FSTYPE" ;;
    *) exit 1 ;;
esac
STUB
cat > "$fixture/bin/mount" <<'STUB'
#!/bin/sh
touch "$DEMO_FIXTURE/mounted"
STUB
cat > "$fixture/bin/timeout" <<'STUB'
#!/bin/sh
shift
exec "$@"
STUB
for command in cloud-init mount.nfs sync sleep; do
    printf '#!/bin/sh\nexit 0\n' > "$fixture/bin/$command"
done
chmod +x "$fixture/bin/"*

run_step() {
    sed -e "s|__ACTION__|$1|g" -e 's|__SERVER__|10.42.2.4|g' \
        -e 's|__DEMO_ID__|customer01|g' -e 's|__RUN_ID__|test-run|g' \
        -e "s|__MOUNT_ROOT__|$fixture/share|g" "$root/demo/client.sh" > "$fixture/step.sh"
    sh "$fixture/step.sh" > "$fixture/output" 2>&1
}
expect_failure() {
    if run_step "$1"; then
        printf 'FAIL: %s unexpectedly succeeded\n' "$1" >&2
        exit 1
    fi
    grep -q "$2" "$fixture/output" || { cat "$fixture/output"; exit 1; }
    if grep -q ANF_DEMO_OK "$fixture/output"; then
        printf 'FAIL: unsuccessful step emitted a completion marker\n' >&2
        exit 1
    fi
}

expect_failure Check 'not mounted'
touch "$fixture/share/local-file"
expect_failure Prepare 'refusing to hide local files'
rm "$fixture/share/local-file"
run_step Prepare
grep -q 'ANF_DEMO_OK:Prepare:test-run' "$fixture/output"
file="$fixture/share/customer-demo/example.txt"
[ "$(cat "$file")" = 'ANF demo: original customer data' ]
run_step Check
expect_failure Change 'Snapshot file is not visible'
mkdir -p "$fixture/share/.snapshot/demo-baseline"
cp -R "$fixture/share/customer-demo" "$fixture/share/.snapshot/demo-baseline/"
printf 'Do not touch\n' > "$fixture/share/unrelated.txt"
run_step Change
[ "$(cat "$file")" = 'ANF demo: changed during presentation' ]
run_step Prepare
[ "$(cat "$file")" = 'ANF demo: changed during presentation' ]
expect_failure Check 'requires the original'
run_step Restore
cmp "$file" "$fixture/share/.snapshot/demo-baseline/customer-demo/example.txt"
[ "$(cat "$fixture/share/unrelated.txt")" = 'Do not touch' ]
run_step Change
run_step Restore
export DEMO_SOURCE='10.42.2.99:/foreign'
expect_failure Restore 'Unexpected mount source'
export DEMO_SOURCE='10.42.2.4:/demo'
export DEMO_FSTYPE=ext4
expect_failure Restore 'Unexpected filesystem'
export DEMO_FSTYPE=nfs
printf 'other-demo\n' > "$fixture/share/customer-demo/.anf-demo-id"
expect_failure Change 'another DemoId'
printf 'customer01\n' > "$fixture/share/customer-demo/.anf-demo-id"
printf 'not original\n' > "$fixture/share/.snapshot/demo-baseline/customer-demo/example.txt"
expect_failure Restore 'expected original data'
rm "$file"
ln -s "$fixture/share/unrelated.txt" "$file"
expect_failure Change 'Symbolic links'
rm "$file"
printf 'PASS Linux demo client: mount guards, initialization, repeat runs, snapshot baseline, change and file restore\n'
