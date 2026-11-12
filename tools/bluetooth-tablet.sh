#!/bin/sh
set -eu

run_dir=/run/inkbridge-ble
manual_dir=/run/inkbridge-ble-manual
payload_dir=/home/root/.local/share/inkbridge-ble
unit_dir=/usr/local/lib/systemd/system
unit=inkbridge-ble.service
manual_unit=inkbridge-ble-manual.service
host_key=/etc/dropbear/dropbear_ed25519_host_key
suspend_counter=/sys/power/suspend_stats/success

wait_ready() {
    attempts=25
    until [ -f "$run_dir/ready" ]; do
        attempts=$((attempts - 1))
        if [ "$attempts" -eq 0 ]; then
            echo 'The Inkbridge Bluetooth service did not become ready.' >&2
            journalctl -u "$1" -n 20 --no-pager >&2 || :
            return 1
        fi
        sleep 1
    done
}

stop_legacy() {
    systemctl stop inkbridge-ble-advertise.service inkbridge-ble-link.service \
        inkbridge-ble-ssh.service 2>/dev/null || :
    rm -f "$run_dir/started-bluetooth" "$run_dir/server" "$run_dir/input" \
        "$run_dir/inkbridge-pen" "$run_dir/pen.lock"
}

stop_running() {
    systemctl stop "$unit" "$manual_unit" 2>/dev/null || :
    stop_legacy
}

stage_payload() {
    mkdir -p "$1"
    cp "$2" "$1/server"
    cp "$3" "$1/inkbridge-pen"
    cp "$0" "$1/tablet.sh"
    chmod 700 "$1/server" "$1/inkbridge-pen" "$1/tablet.sh"
}

register_boot_unit() (
    set -e
    root_readonly=$(awk '$2 == "/" { print ($4 ~ /(^|,)ro(,|$)/); exit }' /proc/mounts)
    restore_root() {
        status=$1
        trap - 0
        if [ "$root_readonly" = 1 ] && ! mount -o remount,ro /; then
            echo 'Could not restore the tablet root filesystem to read-only.' >&2
            status=1
        fi
        exit "$status"
    }
    if [ "$root_readonly" = 1 ]; then
        trap 'restore_root "$?"' 0
        trap 'restore_root 1' HUP INT TERM
        mount -o remount,rw / || restore_root "$?"
    fi

    wants="$unit_dir/multi-user.target.wants"
    if [ "$1" = remove ]; then
        rm -f "$wants/$unit" "$unit_dir/$unit" "$unit_dir/$unit.new" || restore_root "$?"
        # Rollback can call this from an EXIT trap, where some shells suppress
        # nested EXIT traps.
        restore_root 0
    fi

    (umask 022; mkdir -p "$wants")
    cat > "$unit_dir/$unit.new" <<'UNIT'
[Unit]
Description=Inkbridge Bluetooth bridge
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/bin/sh -c 'until [ -r /home/root/.local/share/inkbridge-ble/tablet.sh ]; do sleep 2; done; exec /bin/sh /home/root/.local/share/inkbridge-ble/tablet.sh supervise /home/root/.local/share/inkbridge-ble'
Restart=always
RestartSec=2s
RuntimeDirectory=inkbridge-ble
RuntimeDirectoryMode=0700
TimeoutStopSec=10s

[Install]
WantedBy=multi-user.target
UNIT
    chmod 644 "$unit_dir/$unit.new"
    mv -f "$unit_dir/$unit.new" "$unit_dir/$unit"
    ln -sfn "../$unit" "$wants/$unit"
    restore_root 0
)

install_bridge() (
    mkdir -p "${payload_dir%/*}"
    staging_dir=$(mktemp -d "${payload_dir%/*}/.inkbridge-install.XXXXXX")
    stage="$staging_dir/new"
    backup="$staging_dir/previous"
    previous_active=0
    previous_manual=0
    previous_installed=0
    replaced=0
    succeeded=0
    if systemctl is-active --quiet "$unit"; then previous_active=1; fi
    if systemctl is-active --quiet "$manual_unit" || systemctl is-active --quiet inkbridge-ble-link.service; then
        previous_manual=1
    fi
    if [ -f "$unit_dir/$unit" ]; then previous_installed=1; fi
    finish_install() {
        status=$?
        trap - 0
        set +e
        if [ "$succeeded" = 0 ] && { [ "$replaced" = 1 ] || [ -d "$backup" ]; }; then
            systemctl stop "$unit" 2>/dev/null
            rm -rf "$payload_dir"
            if [ -d "$backup" ] && ! mv "$backup" "$payload_dir"; then
                echo "Previous Inkbridge files are retained in $backup." >&2
                exit 1
            fi
            if [ "$previous_installed" = 0 ]; then register_boot_unit remove; fi
            systemctl daemon-reload
            if [ "$previous_active" = 1 ]; then
                systemctl start "$unit"
            elif [ "$previous_manual" = 1 ]; then
                start_manual "$server" "$pen"
            fi
        fi
        rm -rf "$staging_dir"
        exit "$status"
    }
    trap finish_install 0
    trap 'exit 1' HUP INT TERM
    server=$1
    pen=$2
    stage_payload "$stage" "$server" "$pen"
    if [ -d "$payload_dir" ]; then
        mv "$payload_dir" "$backup"
    fi
    replaced=1
    mv "$stage" "$payload_dir"
    register_boot_unit add
    stop_running
    systemctl daemon-reload
    systemctl start "$unit"
    wait_ready "$unit"
    succeeded=1
    echo 'Inkbridge Bluetooth is running and enabled at boot.'
)

start_manual() {
    if systemctl is-active --quiet "$manual_unit"; then
        wait_ready "$manual_unit"
        return
    fi
    stop_legacy
    stage_payload "$manual_dir" "$1" "$2"
    systemd-run --quiet --unit="$manual_unit" \
        --property=Restart=always --property=RestartSec=2s \
        --property=StartLimitIntervalSec=0 \
        --property=RuntimeDirectory=inkbridge-ble --property=RuntimeDirectoryMode=0700 \
        --property=TimeoutStopSec=10s \
        /bin/sh "$manual_dir/tablet.sh" supervise "$manual_dir"
    if ! wait_ready "$manual_unit"; then
        systemctl stop "$manual_unit"
        return 1
    fi
}

controller_powered() {
    timeout 2 bluetoothctl show 2>/dev/null | grep -q 'Powered: yes'
}

prepare_radio() {
    modprobe btnxpuart
    systemctl start bluetooth.service
    attempts=10
    until controller_powered; do
        attempts=$((attempts - 1))
        if [ "$attempts" -eq 0 ]; then
            echo 'The tablet Bluetooth controller did not power on.' >&2
            return 1
        fi
        timeout 2 bluetoothctl power on >/dev/null 2>&1 || :
        sleep 1
    done
}

read_advertiser() {
    while IFS= read -r line; do
        case "$line" in
            *'Advertising object registered'*) touch "$run_dir/advertising" ;;
            *'Advertising object unregistered'*|*'Failed to register advertisement'*)
                rm -f "$run_dir/advertising"
                echo "$line" >&2
                ;;
        esac
    done
}

start_advertiser() {
    mkfifo "$run_dir/input" "$run_dir/output"
    read_advertiser < "$run_dir/output" &
    log_pid=$!
    (
        exec 3<> "$run_dir/input"
        exec /usr/bin/bluetoothctl <&3 > "$run_dir/output" 2>&1
    ) &
    advertiser_pid=$!
    sleep 1
    timeout 3 sh -c 'cat > "$1/input"' sh "$run_dir" <<'COMMANDS'
menu advertise
uuids 76ec1d74-84ab-4bef-8b80-1b646d28b235
name Inkbridge
back
advertise on
agent off
COMMANDS
}

read_suspend_counter() {
    if [ -r "$suspend_counter" ]; then cat "$suspend_counter"; fi
}

supervise() {
    payload=$1
    # The encrypted home partition and the stock SSH key become available as
    # the tablet finishes its normal startup.
    until [ -x "$payload/server" ] && [ -x "$payload/inkbridge-pen" ] && [ -r "$host_key" ]; do
        sleep 2
    done
    prepare_radio
    rm -f "$run_dir/ready" "$run_dir/advertising" "$run_dir/input" "$run_dir/output"
    ln -sfn "$payload/inkbridge-pen" "$run_dir/inkbridge-pen"
    trap 'rm -f "$run_dir/ready"' 0
    trap 'exit 0' HUP INT TERM

    /usr/sbin/dropbear -F -E -G root -j -k -p 127.0.0.1:2222 -r "$host_key" &
    ssh_pid=$!
    # SSH supplies encryption and authentication for the BLE transport.
    "$payload/server" 127.0.0.1 2222 low &
    server_pid=$!
    resume_count=$(read_suspend_counter)
    start_advertiser

    attempts=10
    until [ -f "$run_dir/advertising" ]; do
        attempts=$((attempts - 1))
        if [ "$attempts" -eq 0 ] || ! kill -0 "$advertiser_pid"; then
            echo 'The Inkbridge Bluetooth advertisement did not start.' >&2
            return 1
        fi
        sleep 1
    done
    kill -0 "$ssh_pid" "$server_pid"
    touch "$run_dir/ready"
    echo 'Inkbridge Bluetooth is advertising.'

    while sleep 3; do
        if [ "$(read_suspend_counter)" != "$resume_count" ]; then
            echo 'Tablet resumed from suspend; restarting the Inkbridge Bluetooth advertisement.'
            return 1
        fi
        if ! kill -0 "$ssh_pid" "$server_pid" "$advertiser_pid" "$log_pid" ||
           [ ! -f "$run_dir/advertising" ] || ! controller_powered; then
            echo 'Inkbridge Bluetooth lost a bridge process or controller; restarting.' >&2
            return 1
        fi
    done
}

umask 077
case "${1:-}" in
    install)
        install_bridge "$2" "$3"
        ;;
    start)
        if [ -f "$unit_dir/$unit" ]; then
            systemctl start "$unit"
            wait_ready "$unit"
        else
            start_manual "$2" "$3"
        fi
        echo 'Inkbridge Bluetooth is ready. Start ./inkbridge --bluetooth on the Mac.'
        ;;
    stop)
        stop_running
        echo 'Inkbridge Bluetooth stopped.'
        ;;
    status)
        if [ -L "$unit_dir/multi-user.target.wants/$unit" ]; then
            echo 'Boot startup: enabled'
        else
            echo 'Boot startup: disabled'
        fi
        if [ -f "$run_dir/ready" ]; then
            echo 'Bluetooth bridge: ready'
        elif systemctl is-active --quiet "$unit" || systemctl is-active --quiet "$manual_unit"; then
            echo 'Bluetooth bridge: starting'
        else
            echo 'Bluetooth bridge: stopped'
        fi
        ;;
    uninstall)
        if [ -f "$unit_dir/$unit" ]; then register_boot_unit remove; fi
        stop_running
        systemctl daemon-reload
        rm -rf "$payload_dir" "$manual_dir"
        echo 'Inkbridge Bluetooth startup service removed.'
        ;;
    supervise)
        supervise "$2"
        ;;
    *)
        echo 'Usage: bluetooth-tablet.sh install|start|stop|status|uninstall' >&2
        exit 2
        ;;
esac
