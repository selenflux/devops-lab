#!/bin/bash
################################################################################
# 主机每日巡检脚本
# Author : selenflux
# Version: 2026.08.20‑fix
# 适用   : RHEL / CentOS / Rocky / AlmaLinux / Anolis 7.x / 8.x / 9.x (systemd)
# 用法   : bash host_daily_check.sh
#          crontab 每日 09:00 示例:
#          0 9 * * * /opt/scripts/host_daily_check.sh >/dev/null 2>&1
################################################################################

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LANG="en_US.UTF-8"
umask 022

#---------------------------------- 配置区 ----------------------------------
# 上报接口（按需启用）
# uploadHostDailyCheckApi="http://10.0.0.1:8080/api/uploadHostDailyCheck"
# uploadHostDailyCheckReportApi="http://10.0.0.1:8080/api/uploadHostDailyCheckReport"

LOG_SAVE_DAYS=7         # 旧日志保留天数
LOCK_FILE="/tmp/host_daily_check.lock"

PROGPATH="$(cd "$(dirname "$0")" && pwd)"
LOGPATH="${PROGPATH}/log"
mkdir -p "$LOGPATH"
RESULTFILE="${LOGPATH}/HostDailyCheck-$(hostname)-$(date +%Y%m%d).txt"

# 风险计数
HIGH_RISK=0
WARN_RISK=0

#---------------------------------- 文件锁，防止并发执行 ----------------------
exec 9>"$LOCK_FILE"
if ! flock -n 9 ; then
    echo "[WARN] 脚本已经在运行，退出" >&2
    exit 1
fi

#---------------------------------- 基础检查 ----------------------------------
if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] 请使用 root 用户执行此脚本！" >&2
    exit 1
fi

VERSION="2026.08.20‑fix"

#---------------------------------- 系统识别 ----------------------------------
OS_ID="unknown"
OS_VERSION_ID=0
OS_PRETTY_NAME="unknown"
KERNEL_ARCH="$(uname -m)"
if [ -r /etc/os-release ]; then
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION_ID="${VERSION_ID:-0}"
    OS_PRETTY_NAME="${PRETTY_NAME:-unknown}"
fi
OS_MAJOR="${OS_VERSION_ID%%.*}"
[ "$OS_MAJOR" -ge 1 ] 2>/dev/null || OS_MAJOR=0

#---------------------------------- 报表全局变量 ------------------------------
report_DateTime=""
report_Hostname=""
report_OSRelease=""
report_Kernel=""
report_Language=""
report_LastReboot=""
report_Uptime=""
report_CPUs=""
report_CPUType=""
report_Arch=""
report_MemTotal=""
report_MemFree=""
report_MemUsedPercent=""
report_DiskTotal=""
report_DiskFree=""
report_DiskUsedPercent=""
report_InodeTotal=""
report_InodeFree=""
report_InodeUsedPercent=""
report_IP=""
report_MAC=""
report_Gateway=""
report_DNS=""
report_Listen=""
report_Selinux=""
report_Firewall=""
report_UserCount=""
report_UserEmptyPassword=""
report_UserTheSameUID=""
report_PasswordExpiry=""
report_RootUser=""
report_Sudoers=""
report_SSHAuthorized=""
report_SSHDProtocolVersion=""
report_SSHDPermitRootLogin=""
report_DefunctProcess=""
report_SelfInitiatedService=""
report_SelfInitiatedProgram=""
report_RunningService=""
report_Crontab=""
report_Syslog=""
report_SNMP=""
report_NTP=""
report_JDK=""

TMPDIR_CHECK="$(mktemp -d /tmp/HostDailyCheck.XXXXXX)"
trap 'rm -rf "$TMPDIR_CHECK"' EXIT

#---------------------------------- 工具函数 ----------------------------------
function getServiceState() {
    local state
    state="$(systemctl is-active "$1" 2>/dev/null)"
    echo "${state:-unknown}"
}

function section() {
    echo ""
    echo ""
    echo "############################ $1 ############################"
}

function safe_let() {
    local var="$1"; shift
    local val
    val="$(( ${1:-0} ))" 2>/dev/null || val=0
    eval "$var=\$val"
}

# json字符串转义：处理双引号、换行、反斜杠
function json_escape() {
    local str="$1"
    printf '%s' "$str" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e ':a;N;$!ba;s/\n/\\n/g'
}

# 风险记录
function add_high_risk(){
    echo "[HIGH RISK] $1"
    HIGH_RISK=$((HIGH_RISK+1))
}
function add_warn_risk(){
    echo "[WARN RISK] $1"
    WARN_RISK=$((WARN_RISK+1))
}

#---------------------------------- 系统信息 ----------------------------------
function getSystemStatus() {
    section "系统检查"
    local kernel release hostname selinux lastreboot uptime_str lang_now

    kernel="$(uname -r)"
    release="$OS_PRETTY_NAME"
    hostname="$(hostname)"
    selinux="$(getenforce 2>/dev/null || echo Unknown)"
    lastreboot="$(who -b 2>/dev/null | awk '{print $3,$4}')"
    uptime_str="$(uptime -p 2>/dev/null || uptime | sed 's/.*up \([^,]*\), .*/\1/')"
    lang_now="${LANG:-unknown}"

    echo "     系统：GNU/Linux"
    echo " 发行版本：$release"
    echo "     内核：$kernel"
    echo "   主机名：$hostname"
    echo "  SELinux：$selinux"
    echo "语言/编码：$lang_now"
    echo " 当前时间：$(date +'%F %T')"
    echo " 最后启动：$lastreboot"
    echo " 运行时间：$uptime_str"

    report_DateTime="$(date '+%F %T')"
    report_Hostname="$hostname"
    report_OSRelease="$release"
    report_Kernel="$kernel"
    report_Language="$lang_now"
    report_LastReboot="$lastreboot"
    report_Uptime="$uptime_str"
    report_Selinux="$selinux"

    if [[ "$selinux" == "Disabled" ]];then
        add_warn_risk "SELinux已关闭"
    fi
}

#---------------------------------- CPU ---------------------------------------
function getCpuStatus() {
    section "CPU 检查"
    local physical logical cores model
    physical="$(grep "physical id" /proc/cpuinfo 2>/dev/null | sort -u | wc -l)"
    logical="$(grep -c "^processor" /proc/cpuinfo 2>/dev/null)"
    cores="$(awk -F': ' '/^cpu cores/{print $2; exit}' /proc/cpuinfo 2>/dev/null)"
    model="$(grep "model name" /proc/cpuinfo 2>/dev/null | awk -F': ' '{print $2}' | sort -u | head -1)"

    echo "物理 CPU 个数：$physical"
    echo "逻辑 CPU 个数：$logical"
    echo "每 CPU 核心数：${cores:-N/A}"
    echo "    CPU 型号：$model"
    echo "    CPU 架构：$KERNEL_ARCH"

    report_CPUs="$logical"
    report_CPUType="$model"
    report_Arch="$KERNEL_ARCH"
}

#---------------------------------- 内存 --------------------------------------
function getMemStatus() {
    section "内存检查"
    free -h
    echo ""
    swap_value

    local mem_total mem_available mem_used pct
    mem_total="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)"
    mem_available="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)"
    mem_used=$(( ${mem_total:-0} - ${mem_available:-0} ))
    if [ "${mem_total:-0}" -gt 0 ] 2>/dev/null; then
        pct="$(awk "BEGIN{printf \"%.2f\", $mem_used*100/$mem_total}")"
    else
        pct="0.00"
    fi

    report_MemTotal="$(( mem_total / 1024 ))MB"
    report_MemFree="$(( mem_available / 1024 ))MB"
    report_MemUsedPercent="${pct}%"
}

function swap_value() {
    echo "Swap 使用：$(free -h 2>/dev/null | awk '/^Swap:/{print $3"/"$2}')"
}

#---------------------------------- 磁盘 / Inode ------------------------------
function getDiskStatus() {
    section "磁盘检查"
    df -hTP -x tmpfs -x devtmpfs
    echo ""
    echo "Inode信息"
    df -hiP -x tmpfs -x devtmpfs

    echo ""
    echo "使用率超过 80% 的挂载点："
    df -hP -x tmpfs -x devtmpfs 2>/dev/null | awk 'NR>1 && ($5+0)>80{print "  "$6" : "$5}' || true
    echo "Inode 使用率超过 80% 的挂载点："
    df -hiP -x tmpfs -x devtmpfs 2>/dev/null | awk 'NR>1 && ($5+0)>80{print "  "$6" : "$5}' || true

    local disk_total disk_used disk_free disk_pct inode_total inode_used inode_free inode_pct
    disk_total="$(df -kP -x tmpfs -x devtmpfs 2>/dev/null | awk 'NR>1{s+=$2}END{print s+0}')"
    disk_used="$(df -kP -x tmpfs -x devtmpfs 2>/dev/null | awk 'NR>1{s+=$3}END{print s+0}')"
    disk_free=$(( disk_total - disk_used ))
    if [ "$disk_total" -gt 0 ] 2>/dev/null; then
        disk_pct="$(awk "BEGIN{printf \"%.2f\", $disk_used*100/$disk_total}")"
    else
        disk_pct="0.00"
    fi

    inode_total="$(df -iP -x tmpfs -x devtmpfs 2>/dev/null | awk 'NR>1{s+=$2}END{print s+0}')"
    inode_used="$(df -iP -x tmpfs -x devtmpfs 2>/dev/null | awk 'NR>1{s+=$3}END{print s+0}')"
    inode_free=$(( inode_total - inode_used ))
    if [ "$inode_total" -gt 0 ] 2>/dev/null; then
        inode_pct="$(awk "BEGIN{printf \"%.2f\", $inode_used*100/$inode_total}")"
    else
        inode_pct="0.00"
    fi

    report_DiskTotal="$(( disk_total / 1024 / 1024 ))GB"
    report_DiskFree="$(( disk_free / 1024 / 1024 ))GB"
    report_DiskUsedPercent="${disk_pct}%"
    report_InodeTotal="$(( inode_total / 1000 ))K"
    report_InodeFree="$(( inode_free / 1000 ))K"
    report_InodeUsedPercent="${inode_pct}%"
}

#---------------------------------- 网络 --------------------------------------
function getNetworkStatus() {
    section "网络检查"
    local gateway dns ip_list mac_list
    gateway="$(ip route show default 2>/dev/null | awk '{print $3; exit}')"
    dns="$(grep -E "^nameserver" /etc/resolv.conf 2>/dev/null | awk '{print $2}' | paste -sd, -)"

    for iface in $(ip -o link show 2>/dev/null | awk -F': ' '$2!="lo"{print $2}'); do
        addr="$(ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet /{print $2}' | paste -sd' ' -)"
        [ -n "$addr" ] && echo "$iface: $addr"
    done

    echo ""
    echo "网关：${gateway:-N/A}"
    echo " DNS：${dns:-N/A}"

    ip_list="$(ip -4 -o addr show 2>/dev/null | awk '$2!="lo"{split($4,a,"/");print $2"="a[1]}' | paste -sd, -)"
    mac_list="$(ip -o link show 2>/dev/null | awk -F': ' '$2!="lo"{print $2"="$17}' | paste -sd, -)"

    report_IP="$ip_list"
    report_MAC="$mac_list"
    report_Gateway="$gateway"
    report_DNS="$dns"
}

#---------------------------------- 监听端口 ----------------------------------
function getListenStatus() {
    section "监听检查"
    ss -ntulp 2>/dev/null | column -t
    report_Listen="$(ss -ntulH 2>/dev/null | awk '/^tcp/{print $5}' | awk -F: '{print $NF}' | sort -un | wc -l)"
}

#---------------------------------- 进程 --------------------------------------
function getProcessStatus() {
    section "进程检查"
    local defunct_count
    defunct_count="$(ps -eo stat,pid,ppid,cmd 2>/dev/null | awk '$1 ~ /^Z/{c++}END{print c+0}')"

    if [ "$defunct_count" -ge 1 ]; then
        echo ""
        echo "僵尸进程：${defunct_count} 个"
        echo "--------"
        ps -eo stat,pid,ppid,cmd 2>/dev/null | awk '$1 ~ /^Z/'
        add_warn_risk "存在${defunct_count}个僵尸进程"
    fi

    echo ""
    echo "内存占用 TOP10"
    echo "--------------"
    ps -eo pid,pmem,rss,comm --sort=-rss 2>/dev/null | head -n 11 | column -t
    echo ""
    echo "CPU 占用 TOP10"
    echo "--------------"
    ps -eo pid,pcpu,pmem,comm --sort=-pcpu 2>/dev/null | head -n 11 | column -t

    report_DefunctProcess="$defunct_count"
}

#---------------------------------- 服务 --------------------------------------
function getServiceStatus() {
    section "服务检查"
    local enabled_count running_count
    enabled_count="$(systemctl list-unit-files --type=service --state=enabled --no-pager 2>/dev/null | grep -c "enabled")"
    running_count="$(systemctl list-units --type=service --state=running --no-pager 2>/dev/null | grep -c "\.service")"

    echo "自启动服务"
    echo "----------"
    systemctl list-unit-files --type=service --state=enabled --no-pager 2>/dev/null | grep "enabled" | column -t
    echo ""
    echo "正在运行的服务"
    echo "--------------"
    systemctl list-units --type=service --state=running --no-pager 2>/dev/null | grep "\.service"

    report_SelfInitiatedService="$enabled_count"
    report_RunningService="$running_count"
}

#---------------------------------- 自启动脚本 --------------------------------
function getAutoStartStatus() {
    section "自启动检查"
    local conf
    if [ -f /etc/rc.d/rc.local ]; then
        conf="$(grep -v "^#" /etc/rc.d/rc.local | sed '/^[[:space:]]*$/d')"
        echo "$conf"
        report_SelfInitiatedProgram="$(echo "$conf" | grep -c . )"
        if [ ! -x /etc/rc.d/rc.local ];then
            echo "[NOTE] /etc/rc.d/rc.local 没有执行权限，内容不会自动执行"
        fi
    else
        echo "/etc/rc.d/rc.local 不存在"
        report_SelfInitiatedProgram="0"
    fi
}

#---------------------------------- 最近登录 ----------------------------------
function getLoginStatus() {
    section "登录检查"
    echo "最近 10 次登录："
    echo "----------------"
    last -a 2>/dev/null | head -n 11
    echo ""
    echo "当前在线用户："
    echo "--------------"
    who 2>/dev/null
}

#---------------------------------- 计划任务 ----------------------------------
function getCronStatus() {
    section "计划任务检查"
    local total=0 user_cron_lines sys_cron_count

    for user in $(awk -F: '$7 !~ /(nologin|false|sync|halt|shutdown)/{print $1}' /etc/passwd 2>/dev/null); do
        if crontab -l -u "$user" >/dev/null 2>&1; then
            echo "用户 [$user] 的 crontab："
            echo "--------"
            crontab -l -u "$user" 2>/dev/null
            user_cron_lines="$(crontab -l -u "$user" 2>/dev/null | grep -vc '^[[:space:]]*#' )"
            user_cron_lines="${user_cron_lines:-0}"
            total=$(( total + user_cron_lines ))
            echo ""
        fi
    done

    echo "系统级 /etc/cron*："
    echo "-------------------"
    find /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/cron.monthly -type f 2>/dev/null | xargs -r ls -l 2>/dev/null | column -t
    sys_cron_count="$(grep -vhc '^[[:space:]]*#' /etc/crontab /etc/cron.d/* 2>/dev/null | awk '{s+=$1}END{print s+0}')"
    total=$(( total + sys_cron_count ))

    report_Crontab="$total"
}

#---------------------------------- 用户与安全 --------------------------------
function getUserStatus() {
    section "用户检查"
    local pwd_modify root_users="" empty_pwd="" same_uid="" user_count
    pwd_modify="$(stat -c %y /etc/passwd 2>/dev/null | cut -d. -f1)"
    echo "/etc/passwd 最后修改时间：$pwd_modify"

    echo ""
    echo "特权用户（UID=0）"
    echo "------------------"
    root_users="$(awk -F: '$3==0{print $1}' /etc/passwd 2>/dev/null | paste -sd, -)"
    echo "${root_users:-无}"
    root_cnt=$(echo "$root_users" | tr ',' '\n' | wc -l)
    if [ "$root_cnt" -gt 1 ];then
        add_high_risk "存在多个UID=0账号：$root_users"
    fi

    echo ""
    echo "可登录用户"
    echo "----------"
    awk -F: '$7 !~ /(nologin|false|sync|halt|shutdown)/{printf "%-15s UID=%s GID=%s HOME=%s SHELL=%s\n",$1,$3,$4,$6,$7}' /etc/passwd 2>/dev/null | column -t

    user_count="$(awk -F: '$7 !~ /(nologin|false|sync|halt|shutdown)/' /etc/passwd 2>/dev/null | wc -l)"

    echo ""
    echo "空密码 / 锁定用户"
    echo "------------------"
    empty_pwd="$(awk -F: '($2==""){print $1"(空密码)"} ($2 ~ /^!|^\*$/){print $1"(锁定)"}' /etc/shadow 2>/dev/null | paste -sd, -)"
    echo "${empty_pwd:-无}"

    echo ""
    echo "相同 UID 的用户"
    echo "---------------"
    same_uid="$(awk -F: '{cnt[$3]=cnt[$3]" "$1} END{for(u in cnt){n=split(cnt[u],a," ");if(n>1)printf "%s:%s\n",u,cnt[u]}}' /etc/passwd 2>/dev/null | paste -sd, -)"
    echo "${same_uid:-无}"
    if [ -n "$same_uid" ];then
        add_high_risk "发现重复UID用户：$same_uid"
    fi

    echo ""
    echo "空密码可登录用户（重点风险）"
    echo "----------------------------"
    login_empty_user=$(awk -F: '$2=="" && $7 !~ /(nologin|false)/{print $1}' /etc/shadow 2>/dev/null)
    if [ -n "$login_empty_user" ];then
        echo "$login_empty_user"
        add_high_risk "可登录账号存在空密码：$login_empty_user"
    else
        echo "无"
    fi

    report_UserCount="$user_count"
    report_RootUser="$root_users"
    report_UserEmptyPassword="${empty_pwd:-无}"
    report_UserTheSameUID="${same_uid:-无}"
}

function getPasswordStatus() {
    section "密码检查"
    echo "密码过期检查"
    echo "------------"
    local result=""
    for user in $(awk -F: '$7 !~ /(nologin|false|sync|halt|shutdown)/{print $1}' /etc/passwd 2>/dev/null); do
        expiry=""
        if chage -l "$user" 2>/dev/null;then
            expiry="$(chage -l "$user" 2>/dev/null | awk -F: '/Password expires/{gsub(/^ +/,"",$2);print $2}')"
        fi
        if [ -z "$expiry" ] || [ "$expiry" = "never" ]; then
            printf "%-15s 永不过期\n" "$user"
            result="${result},${user}:never"
            add_warn_risk "用户 $user 密码永不过期"
        else
            ts_exp=$(date -d "$expiry" +%s 2>/dev/null)
            ts_now=$(date +%s)
            if [ -n "$ts_exp" ];then
                days=$(( (ts_exp - ts_now) / 86400 ))
                printf "%-15s %s 天后过期\n" "$user" "$days"
                result="${result},${user}:${days}d"
            else
                printf "%-15s 解析过期时间失败\n" "$user"
                result="${result},${user}:parse_err"
            fi
        fi
    done
    report_PasswordExpiry="${result#,}"

    echo ""
    echo "密码策略（/etc/login.defs）"
    echo "---------------------------"
    grep -E "^\s*(PASS_MAX_DAYS|PASS_MIN_DAYS|PASS_MIN_LEN|PASS_WARN_AGE)" /etc/login.defs 2>/dev/null
    echo ""
    echo "pwquality 密码强度配置："
    grep -vE "^\s*#|^\s*$" /etc/security/pwquality.conf 2>/dev/null || echo "未配置"
}

function getSudoersStatus() {
    section "Sudoers 检查"
    local conf
    conf="$(grep -vE "^\s*#|^\s*Defaults|^\s*$" /etc/sudoers 2>/dev/null)"
    if [ -d /etc/sudoers.d ]; then
        conf="${conf}
$(grep -vE "^\s*#|^\s*Defaults|^\s*$" /etc/sudoers.d/* 2>/dev/null)"
    fi
    echo "$conf"
    report_Sudoers="$(echo "$conf" | grep -c .)"
}

#---------------------------------- SSH ---------------------------------------
function getSSHStatus() {
    section "SSH 检查"
    local authorized=0 permit_root
    echo "服务状态：$(getServiceState sshd)"

    permit_root="$(sshd -T 2>/dev/null | awk '/^permitrootlogin/{print $2}')"
    [ -n "$permit_root" ] || permit_root="yes"
    echo "允许 root 远程登录：$permit_root"
    if [[ "$permit_root" == "yes" ]];then
        add_warn_risk "SSH允许root远程登录"
    fi

    echo ""
    echo "信任主机/免密密钥"
    echo "--------"
    for user in $(awk -F: '$7 !~ /(nologin|false)/{print $1}' /etc/passwd 2>/dev/null); do
        home="$(awk -F: -v u="$user" '$1==u{print $6}' /etc/passwd 2>/dev/null)"
        auth_file="${home}/.ssh/authorized_keys"
        if [ -r "$auth_file" ]; then
            cnt="$(grep -c . "$auth_file" 2>/dev/null)"
            if [ "$cnt" -gt 0 ]; then
                echo "$user 授权 ${cnt} 个密钥可免密访问"
                authorized=$(( authorized + cnt ))
            fi
        fi
    done

    echo ""
    echo "sshd_config 生效配置"
    echo "--------------------"
    grep -vE "^\s*#|^\s*$" /etc/ssh/sshd_config 2>/dev/null

    report_SSHAuthorized="$authorized"
    report_SSHDProtocolVersion="2"
    report_SSHDPermitRootLogin="$permit_root"
}

#---------------------------------- 日志 / SNMP / 时间同步 --------------------
function getSyslogStatus() {
    section "Syslog 检查"
    local state
    state="$(getServiceState rsyslog)"
    echo "服务状态：$state"
    echo ""
    grep -vE "^\s*#|^\s*\$|^\s*$" /etc/rsyslog.conf 2>/dev/null | column -t
    report_Syslog="$state"
}

function getSNMPStatus() {
    section "SNMP 检查"
    local state
    state="$(getServiceState snmpd)"
    echo "服务状态：$state"
    echo ""
    if [ -f /etc/snmp/snmpd.conf ]; then
        grep -vE "^\s*#|^\s*$" /etc/snmp/snmpd.conf 2>/dev/null
    else
        echo "/etc/snmp/snmpd.conf 不存在"
    fi
    report_SNMP="$state"
}

function getNTPStatus() {
    section "时间同步检查"
    if systemctl list-unit-files 2>/dev/null | grep -q "^chronyd.service"; then
        state="$(getServiceState chronyd)"
        echo "同步服务：chronyd（$state）"
        sync_result="$(chronyc tracking 2>/dev/null | grep -E "System time|Leap status" )"
        echo "${sync_result:-chronyc 不可用}"
        echo ""
        echo "时间源："
        chronyc sources -v 2>/dev/null | head -n 12
        report_NTP="chronyd:$state"
    elif systemctl list-unit-files 2>/dev/null | grep -q "^ntpd.service"; then
        state="$(getServiceState ntpd)"
        echo "同步服务：ntpd（$state）"
        ntpstat 2>/dev/null || echo "ntpstat 不可用"
        report_NTP="ntpd:$state"
    else
        echo "未安装 chrony / ntp"
        report_NTP="not‑installed"
        add_warn_risk "未部署时间同步服务chrony/ntp"
    fi
}

#---------------------------------- 防火墙 ------------------------------------
function getFirewallStatus() {
    section "防火墙检查"
    local state
    if systemctl list-unit-files 2>/dev/null | grep -q "^firewalld.service"; then
        state="$(getServiceState firewalld)"
        echo "firewalld：$state"
        echo ""
        echo "开放区域与端口："
        firewall‑cmd --list‑all 2>/dev/null || echo "firewall‑cmd 不可用"
        report_Firewall="firewalld:$state"
        if [[ "$state" != "active" ]];then
            add_warn_risk "firewalld未运行"
        fi
    elif systemctl list-unit-files 2>/dev/null | grep -q "^iptables.service"; then
        state="$(getServiceState iptables)"
        echo "iptables：$state"
        iptables -L -n 2>/dev/null | head -n 30
        report_Firewall="iptables:$state"
        if [[ "$state" != "active" ]];then
            add_warn_risk "iptables未运行"
        fi
    else
        echo "未发现 firewalld / iptables 服务"
        report_Firewall="not‑installed"
        add_high_risk "无防火墙服务"
    fi
}

#---------------------------------- JDK / 软件 --------------------------------
function getJDKStatus() {
    section "JDK 检查"
    if command -v java >/dev/null 2>&1; then
        java -version 2>&1
        report_JDK="$(java -version 2>&1 | awk -F'"' '/version/{print $2; exit}')"
    else
        echo "未安装 java"
        report_JDK="not‑installed"
    fi
    echo "JAVA_HOME=\"${JAVA_HOME:-未设置}\""
}

function getInstalledStatus() {
    section "最近安装的软件（TOP10）"
    if command -v rpm >/dev/null 2>&1; then
        rpm -qa --last 2>/dev/null | head -n 10 | column -t
    else
        echo "非 RPM 系发行版，跳过"
    fi
}

#---------------------------------- 安全更新（可选）---------------------------
function getSecurityUpdateStatus() {
    section "安全更新检查"
    if command -v dnf >/dev/null 2>&1; then
        dnf -q updateinfo summary 2>/dev/null | head -n 15 || echo "无法获取更新信息"
    elif command -v yum >/dev/null 2>&1; then
        yum -q updateinfo summary 2>/dev/null | head -n 15 || echo "无法获取更新信息"
    else
        echo "未找到 dnf / yum"
    fi
}

#---------------------------------- JSON 上报 ---------------------------------
function uploadHostDailyCheckReport() {
    local json
    json=$(cat <<EOF
{
  "DateTime": "$(json_escape "$report_DateTime")",
  "Hostname": "$(json_escape "$report_Hostname")",
  "OSRelease": "$(json_escape "$report_OSRelease")",
  "Kernel": "$(json_escape "$report_Kernel")",
  "Language": "$(json_escape "$report_Language")",
  "LastReboot": "$(json_escape "$report_LastReboot")",
  "Uptime": "$(json_escape "$report_Uptime")",
  "CPUs": "$(json_escape "$report_CPUs")",
  "CPUType": "$(json_escape "$report_CPUType")",
  "Arch": "$(json_escape "$report_Arch")",
  "MemTotal": "$(json_escape "$report_MemTotal")",
  "MemFree": "$(json_escape "$report_MemFree")",
  "MemUsedPercent": "$(json_escape "$report_MemUsedPercent")",
  "DiskTotal": "$(json_escape "$report_DiskTotal")",
  "DiskFree": "$(json_escape "$report_DiskFree")",
  "DiskUsedPercent": "$(json_escape "$report_DiskUsedPercent")",
  "InodeTotal": "$(json_escape "$report_InodeTotal")",
  "InodeFree": "$(json_escape "$report_InodeFree")",
  "InodeUsedPercent": "$(json_escape "$report_InodeUsedPercent")",
  "IP": "$(json_escape "$report_IP")",
  "MAC": "$(json_escape "$report_MAC")",
  "Gateway": "$(json_escape "$report_Gateway")",
  "DNS": "$(json_escape "$report_DNS")",
  "Listen": "$(json_escape "$report_Listen")",
  "Selinux": "$(json_escape "$report_Selinux")",
  "Firewall": "$(json_escape "$report_Firewall")",
  "UserCount": "$(json_escape "$report_UserCount")",
  "UserEmptyPassword": "$(json_escape "$report_UserEmptyPassword")",
  "UserTheSameUID": "$(json_escape "$report_UserTheSameUID")",
  "PasswordExpiry": "$(json_escape "$report_PasswordExpiry")",
  "RootUser": "$(json_escape "$report_RootUser")",
  "Sudoers": "$(json_escape "$report_Sudoers")",
  "SSHAuthorized": "$(json_escape "$report_SSHAuthorized")",
  "SSHDProtocolVersion": "$(json_escape "$report_SSHDProtocolVersion")",
  "SSHDPermitRootLogin": "$(json_escape "$report_SSHDPermitRootLogin")",
  "DefunctProcess": "$(json_escape "$report_DefunctProcess")",
  "SelfInitiatedService": "$(json_escape "$report_SelfInitiatedService")",
  "SelfInitiatedProgram": "$(json_escape "$report_SelfInitiatedProgram")",
  "RunningService": "$(json_escape "$report_RunningService")",
  "Crontab": "$(json_escape "$report_Crontab")",
  "Syslog": "$(json_escape "$report_Syslog")",
  "SNMP": "$(json_escape "$report_SNMP")",
  "NTP": "$(json_escape "$report_NTP")",
  "JDK": "$(json_escape "$report_JDK")",
  "HighRiskCount": ${HIGH_RISK},
  "WarnRiskCount": ${WARN_RISK}
}
EOF
)
    echo "$json"
}

#---------------------------------- 主检查流程 --------------------------------
function version() {
    echo "主机每日巡检脚本 Version: $VERSION (Author: selenflux)"
    echo "适用平台：RHEL / CentOS / Rocky / AlmaLinux / Anolis 7+ (systemd)"
}

function check() {
    version
    getSystemStatus
    getCpuStatus
    getMemStatus
    getDiskStatus
    getNetworkStatus
    getListenStatus
    getProcessStatus
    getServiceStatus
    getAutoStartStatus
    getLoginStatus
    getCronStatus
    getUserStatus
    getPasswordStatus
    getSudoersStatus
    getJDKStatus
    getFirewallStatus
    getSSHStatus
    getSyslogStatus
    getSNMPStatus
    getNTPStatus
    getInstalledStatus
    getSecurityUpdateStatus

    section "巡检风险汇总"
    echo "高危风险数量：${HIGH_RISK}"
    echo "警告风险数量：${WARN_RISK}"
}

#---------------------------------- 清理旧日志 --------------------------------
find "${LOGPATH}" -name "HostDailyCheck-*.txt" -type f -mtime +${LOG_SAVE_DAYS} -delete

#---------------------------------- 执行入口 ----------------------------------
check | tee "$RESULTFILE"
chmod 600 "$RESULTFILE"

echo ""
echo "检查结果文件：$RESULTFILE"

# 按需启用：上传巡检文件
# curl -sS -F "filename=@$RESULTFILE" "$uploadHostDailyCheckApi"

# 按需启用：输出JSON并上报
# uploadHostDailyCheckReport | curl -sS -H "Content‑Type: application/json" -X POST -d @‑ "$uploadHostDailyCheckReportApi"

# 根据风险数量设置退出码，供zabbix监控
if [ ${HIGH_RISK} -gt 0 ];then
    exit 2
elif [ ${WARN_RISK} -gt 0 ];then
    exit 1
else
    exit 0
fi
