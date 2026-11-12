#!/bin/sh
# Manage the Paper Pro Bluetooth bridge over USB.
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
action=${1:-}

ssh_tablet() {
    key_file="$HOME/.config/inkbridge/ssh-key"
    identity=''
    if [ -r "$key_file" ]; then
        IFS= read -r identity < "$key_file" || :
    fi
    if [ -n "$identity" ] && [ -r "$identity" ]; then
        ssh -o ConnectTimeout=8 -i "$identity" root@10.11.99.1 "$@"
    else
        ssh -o ConnectTimeout=8 root@10.11.99.1 "$@"
    fi
}

case "$action" in
    install|start)
        if [ ! -x "$repo/inkbridge-ble-server" ] || [ ! -x "$repo/inkbridge-ble-pen" ]; then
            echo 'Build the Bluetooth tools with make bluetooth.' >&2
            exit 1
        fi
        tar -C "$repo" -cf - inkbridge-ble-server inkbridge-ble-pen tools/bluetooth-tablet.sh |
            ssh_tablet '
                set -eu
                umask 077
                stage=$(mktemp -d /run/inkbridge-ble-upload.XXXXXX)
                trap "rm -rf -- \"$stage\"" 0
                tar -xf - -C "$stage"
                flock -w 15 /run/inkbridge-ble-setup.lock sh "$stage/tools/bluetooth-tablet.sh" '"$action"' \
                    "$stage/inkbridge-ble-server" "$stage/inkbridge-ble-pen"
            '
        ;;
    stop|status|uninstall)
        ssh_tablet "flock -w 15 /run/inkbridge-ble-setup.lock sh -s -- $action" < "$repo/tools/bluetooth-tablet.sh"
        ;;
    *)
        echo 'Usage: sh tools/bluetooth.sh install|start|stop|status|uninstall' >&2
        exit 1
        ;;
esac
