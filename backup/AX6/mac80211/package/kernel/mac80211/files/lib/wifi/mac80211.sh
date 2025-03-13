#!/bin/sh

# 追加 mac80211 驱动到 DRIVERS 列表
append DRIVERS "mac80211"

# 检查指定的无线设备是否已存在于配置中
check_mac80211_device() {
    local device="$1"
    local path="$2"
    local macaddr="$3"

    [ -n "$found" ] && return 0

    phy_path=
    config_get phy "$device" phy
    json_select wlan
    [ -n "$phy" ] && case "$phy" in
        phy*)
            [ -d /sys/class/ieee80211/$phy ] && \
                phy_path="$(iwinfo nl80211 path "$dev")"
        ;;
        *)
            if json_is_a "$phy" object; then
                json_select "$phy"
                json_get_var phy_path path
                json_select ..
            elif json_is_a "${phy%.*}" object; then
                json_select "${phy%.*}"
                json_get_var phy_path path
                json_select ..
                phy_path="$phy_path+${phy##*.}"
            fi
        ;;
    esac
    json_select ..
    [ -n "$phy_path" ] || config_get phy_path "$device" path
    [ -n "$path" -a "$phy_path" = "$path" ] && {
        found=1
        return 0
    }

    config_get dev_macaddr "$device" macaddr

    [ -n "$macaddr" -a "$dev_macaddr" = "$macaddr" ] && found=1

    return 0
}

# 通过 iw 命令获取指定物理设备的频段、信道和模式信息
__get_band_defaults() {
    local phy="$1"

    ( iw phy "$phy" info; echo ) | awk '
BEGIN {
        bands = ""
}

($1 == "Band" || $1 == "") && band {
        if (channel) {
                mode="NOHT"
                if (ht) mode="HT20"
                if (vht && band != "1:") mode="VHT80"
                if (he) mode="HE80"
                if (he && band == "1:") mode="HE20"
                sub("\\[", "", channel)
                sub("\\]", "", channel)
                bands = bands band channel ":" mode " "
        }
        band=""
}

$1 == "Band" {
        band = $2
        channel = ""
        vht = ""
        ht = ""
        he = ""
}

$0 ~ "Capabilities:" {
        ht=1
}

$0 ~ "VHT Capabilities" {
        vht=1
}

$0 ~ "HE Iftypes" {
        he=1
}

$1 == "*" && $3 == "MHz" && $0 !~ /disabled/ && band && !channel {
        channel = $4
}

END {
        print bands
}'
}

# 处理 __get_band_defaults 函数的输出，获取频段、信道和模式信息
get_band_defaults() {
    local phy="$1"

    for c in $(__get_band_defaults "$phy"); do
        local band="${c%%:*}"
        c="${c#*:}"
        local chan="${c%%:*}"
        c="${c#*:}"
        local mode="${c%%:*}"

        case "$band" in
            1) band=2g;;
            2) band=5g;;
            3) band=60g;;
            4) band=6g;;
            *) band="";;
        esac

        [ -n "$band" ] || continue
        [ -n "$mode_band" -a "$band" = "6g" ] && return

        mode_band="$band"
        channel="$chan"
        htmode="$mode"
    done
}

# 检查无线设备名称，更新设备编号
check_devidx() {
    case "$1" in
        radio[0-9]*)
            local idx="${1#radio}"
            [ "$devidx" -ge "${1#radio}" ] && devidx=$((idx + 1))
            ;;
    esac
}

# 从 board.json 文件中查找与当前设备路径匹配的设备名称
check_board_phy() {
    local name="$2"

    json_select "$name"
    json_get_var phy_path path
    json_select ..

    if [ "$path" = "$phy_path" ]; then
        board_dev="$name"
    elif [ "${path%+*}" = "$phy_path" ]; then
        fallback_board_dev="$name.${path#*+}"
    fi
}

# 主检测函数，负责检测并配置无线设备
detect_mac80211() {
    devidx=0
    config_load wireless
    config_foreach check_devidx wifi-device

    json_load_file /etc/board.json

    # 标记 2.4G 和 5G 频段是否已经配置
    configured_2g=0
    configured_5g=0

    for _dev in /sys/class/ieee80211/*; do
        [ -e "$_dev" ] || continue

        dev="${_dev##*/}"

        mode_band=""
        channel=""
        htmode=""
        get_band_defaults "$dev"

        path="$(iwinfo nl80211 path "$dev")"
        macaddr="$(cat /sys/class/ieee80211/${dev}/macaddress)"

        [ -n "$path" -o -n "$macaddr" ] || continue

        board_dev=
        fallback_board_dev=
        json_for_each_item check_board_phy wlan
        [ -n "$board_dev" ] || board_dev="$fallback_board_dev"
        [ -n "$board_dev" ] && dev="$board_dev"

        found=
        config_foreach check_mac80211_device wifi-device "$path" "$macaddr"
        [ -n "$found" ] && continue

        case "$mode_band" in
            2g)
                if [ $configured_2g -eq 0 ]; then
                    name="radio${devidx}"
                    devidx=$(($devidx + 1))
                    case "$dev" in
                        phy*)
                            if [ -n "$path" ]; then
                                dev_id="set wireless.${name}.path='$path'"
                            else
                                dev_id="set wireless.${name}.macaddr='$macaddr'"
                            fi
                            ;;
                        *)
                            dev_id="set wireless.${name}.phy='$dev'"
                            ;;
                    esac

                    uci -q batch <<-EOF
                        set wireless.${name}=wifi-device
                        set wireless.${name}.type=mac80211
                        ${dev_id}
                        set wireless.${name}.channel=${channel}
                        set wireless.${name}.band=${mode_band}
                        set wireless.${name}.htmode=$htmode
                        set wireless.${name}.disabled=0

                        set wireless.default_${name}=wifi-iface
                        set wireless.default_${name}.device=${name}
                        set wireless.default_${name}.network=lan
                        set wireless.default_${name}.mode=ap
                        set wireless.default_${name}.ssid=Soft-Routing
                        set wireless.default_${name}.encryption=psk2
                        set wireless.default_${name}.key=88888888
EOF
                    configured_2g=1
                fi
                ;;
            5g)
                if [ $configured_5g -eq 0 ]; then
                    name="radio${devidx}"
                    devidx=$(($devidx + 1))
                    case "$dev" in
                        phy*)
                            if [ -n "$path" ]; then
                                dev_id="set wireless.${name}.path='$path'"
                            else
                                dev_id="set wireless.${name}.macaddr='$macaddr'"
                            fi
                            ;;
                        *)
                            dev_id="set wireless.${name}.phy='$dev'"
                            ;;
                    esac

                    uci -q batch <<-EOF
                        set wireless.${name}=wifi-device
                        set wireless.${name}.type=mac80211
                        ${dev_id}
                        set wireless.${name}.channel=${channel}
                        set wireless.${name}.band=${mode_band}
                        set wireless.${name}.htmode=$htmode
                        set wireless.${name}.disabled=0

                        set wireless.default_${name}=wifi-iface
                        set wireless.default_${name}.device=${name}
                        set wireless.default_${name}.network=lan
                        set wireless.default_${name}.mode=ap
                        set wireless.default_${name}.ssid=Soft-Routing-5G
                        set wireless.default_${name}.encryption=psk2
                        set wireless.default_${name}.key=88888888
EOF
                    configured_5g=1
                fi
                ;;
        esac

        # 如果 2.4G 和 5G 频段都已经配置，跳出循环
        if [ $configured_2g -eq 1 -a $configured_5g -eq 1 ]; then
            break
        fi
    done
    uci -q commit wireless
}

# 调用主检测函数
detect_mac80211