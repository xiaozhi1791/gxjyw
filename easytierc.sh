#!/usr/bin/env bash
# shellcheck shell=bash
#
# =============================================================================
#  EasyTier 客户端节点一键安装脚本
#  适用：Ubuntu 20.04+ / Debian 10+（需要 systemd、root、TUN 设备）
# =============================================================================
#
#  功能：
#    - 交互式询问：网络名称、网络密码、共享节点地址、Web 管理端
#    - 可选：指定固定虚拟 IP（不填则 DHCP 自动分配）
#    - 自动下载安装 EasyTier 到 /opt/easytier
#    - 生成 TOML 配置文件（含中文/特殊字符也能正确处理）
#    - 注册 systemd 服务，开机自启、异常自动重启
#    - 安装后输出验证信息
#
#  用法：
#    sudo bash easytier-client-install.sh
#
#    # 一行流（换成你自己的 GitHub raw 地址）
#    curl -fsSL https://raw.githubusercontent.com/<你>/<仓库>/main/easytier-client-install.sh | sudo bash
#
#    # 全自动
#    sudo bash easytier-client-install.sh \
#      --name home --secret 'your-secret' \
#      --peer tcp://1.2.3.4:31010 --peer udp://1.2.3.4:31010 \
#      --ip 192.168.66.50 -y
#
#  卸载：
#    systemctl disable --now easytier
#    rm -f /etc/systemd/system/easytier.service
#    systemctl daemon-reload
#    rm -rf /opt/easytier /etc/easytier /var/lib/easytier /var/log/easytier
#    rm -f /usr/local/bin/easytier-cli
#
#  许可：MIT
# =============================================================================

set -euo pipefail

# ----------------------------- 默认值 ----------------------------------------
ET_VERSION="${ET_VERSION:-2.6.4}"
INSTALL_DIR="/opt/easytier"
CONF_DIR="/etc/easytier"
CONF_FILE="${CONF_DIR}/config.toml"
DATA_DIR="/var/lib/easytier"
LOG_DIR="/var/log/easytier"
SVC_NAME="easytier"
UNIT_FILE="/etc/systemd/system/easytier.service"
CLI_LINK="/usr/local/bin/easytier-cli"
DEFAULT_PORT="11010"

NET_NAME=""
NET_SECRET=""
WEB_CONSOLE=""
VIRTUAL_IP=""
ASSUME_YES=""
FORCE=""
EXTRACT_DIR=""
PEERS=()

# ----------------------------- 输出 ----------------------------------------
C_RST=""; C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BLD=""
if [[ -t 1 ]]; then
	C_RST=$'\033[0m'; C_RED=$'\033[31m'; C_GRN=$'\033[32m'
	C_YEL=$'\033[33m'; C_BLU=$'\033[36m'; C_BLD=$'\033[1m'
fi

msg()  { printf '%s\n' "$*"; }
info() { printf '%s[*]%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }
step() { printf '\n%s==> %s%s\n' "$C_BLD" "$*" "$C_RST"; }

trap 'die "脚本在第 ${LINENO} 行意外中止"' ERR

# ----------------------------- 交互助手 --------------------------------------
# 脚本可能通过 curl | bash 执行，此时 stdin 是脚本自身，
# 必须从 /dev/tty 读输入，否则会把脚本内容当成答案吃掉。
ask() {
	local prompt="$1" default="${2:-}" answer=""
	if [[ -n "$ASSUME_YES" ]]; then
		printf '%s\n' "$default"
		return 0
	fi
	if [[ -r /dev/tty ]]; then
		read -r -p "$prompt" answer < /dev/tty || answer=""
	else
		read -r -p "$prompt" answer || answer=""
	fi
	printf '%s\n' "${answer:-$default}"
}

# 隐藏输入（密码）
ask_secret() {
	local prompt="$1" answer=""
	if [[ -n "$ASSUME_YES" ]]; then
		printf '%s\n' "${2:-}"
		return 0
	fi
	if [[ -r /dev/tty ]]; then
		read -r -s -p "$prompt" answer < /dev/tty || answer=""
	else
		read -r -s -p "$prompt" answer || answer=""
	fi
	printf '\n' >&2
	printf '%s\n' "$answer"
}

usage() {
	cat <<'USAGE'
EasyTier 客户端节点安装脚本

用法:
  sudo bash easytier-client-install.sh [选项]

选项:
  --name <网络名称>       虚拟网络名称（必填）
  --secret <网络密码>     虚拟网络密钥（必填）
  --peer <地址>           共享节点地址，可重复；支持 tcp:///udp:// 前缀
  --web <地址>            Web 管理端（配置服务器），可留空
  --ip <虚拟IP>           固定虚拟 IP，留空则 DHCP 自动分配
  --version <版本号>      EasyTier 版本（默认 2.6.4）
  -y, --yes               全自动，不询问
  --force                 跳过系统检查
  -h, --help              显示帮助

示例:
  sudo bash easytier-client-install.sh
  sudo bash easytier-client-install.sh --name home --secret 'p@ss' \
       --peer 1.2.3.4:31010 --ip 192.168.66.50 -y
USAGE
}

# ----------------------------- 参数解析 --------------------------------------
while [[ $# -gt 0 ]]; do
	case "$1" in
		--name)    NET_NAME="${2:-}";     if [[ $# -ge 2 ]]; then shift 2; else shift; fi ;;
		--name=*)  NET_NAME="${1#*=}"; shift ;;
		--secret)  NET_SECRET="${2:-}";   if [[ $# -ge 2 ]]; then shift 2; else shift; fi ;;
		--secret=*) NET_SECRET="${1#*=}"; shift ;;
		--peer)    PEERS+=("${2:-}");     if [[ $# -ge 2 ]]; then shift 2; else shift; fi ;;
		--peer=*)  PEERS+=("${1#*=}"); shift ;;
		--web)     WEB_CONSOLE="${2:-}";  if [[ $# -ge 2 ]]; then shift 2; else shift; fi ;;
		--web=*)   WEB_CONSOLE="${1#*=}"; shift ;;
		--ip)      VIRTUAL_IP="${2:-}";   if [[ $# -ge 2 ]]; then shift 2; else shift; fi ;;
		--ip=*)    VIRTUAL_IP="${1#*=}"; shift ;;
		--version) ET_VERSION="${2:-}";   if [[ $# -ge 2 ]]; then shift 2; else shift; fi ;;
		--version=*) ET_VERSION="${1#*=}"; shift ;;
		-y|--yes)  ASSUME_YES=1; shift ;;
		--force)   FORCE=1; shift ;;
		-h|--help) usage; exit 0 ;;
		"")        shift ;;
		*)         die "未知参数: $1（用 --help 查看用法）" ;;
	esac
done

# ----------------------------- 工具函数 --------------------------------------
# TOML 字符串转义：反斜杠和双引号
toml_escape() {
	local s="$1"
	s="${s//\\/\\\\}"
	s="${s//\"/\\\"}"
	printf '%s' "$s"
}

# 规范化共享节点地址：补协议、补默认端口、去首尾空白
normalize_peer() {
	local p="$1"
	p="${p#"${p%%[![:space:]]*}"}"
	p="${p%"${p##*[![:space:]]}"}"
	[[ -z "$p" ]] && return 0
	[[ "$p" == *"://"* ]] || p="tcp://${p}"
	local rest="${p#*://}"
	# 末尾没有 :端口 就补默认端口（兼容 IPv6 的 [::1] 写法）
	if [[ ! "$rest" =~ :[0-9]+/?$ ]]; then
		p="${p%/}:${DEFAULT_PORT}"
	fi
	printf '%s' "$p"
}

# 规范化 Web 管理端地址
normalize_web() {
	local w="$1"
	w="${w#"${w%%[![:space:]]*}"}"
	w="${w%"${w##*[![:space:]]}"}"
	[[ -z "$w" ]] && return 0
	if [[ "$w" == *"://"* ]]; then
		printf '%s' "$w"
	elif [[ "$w" == *":"* ]]; then
		printf 'udp://%s' "$w"
	else
		printf '%s' "$w"
	fi
}

# ----------------------------- 环境检查 --------------------------------------
check_env() {
	step "环境检查"

	[[ $EUID -eq 0 ]] || die "请用 root 运行：sudo bash $0"

	[[ -r /etc/os-release ]] || die "无法识别系统（缺少 /etc/os-release）"
	# shellcheck disable=SC1091
	. /etc/os-release

	local idstr="${ID:-} ${ID_LIKE:-}"
	if [[ "$idstr" != *debian* && "$idstr" != *ubuntu* ]]; then
		if [[ -n "$FORCE" ]]; then
			warn "当前系统 ${PRETTY_NAME:-未知} 不在 Ubuntu/Debian 范围内，按 --force 继续"
		else
			die "本脚本面向 Ubuntu/Debian，当前为 ${PRETTY_NAME:-未知}；确认要继续请加 --force"
		fi
	fi

	command -v systemctl >/dev/null 2>&1 || die "需要 systemd，未找到 systemctl"
	command -v awk >/dev/null 2>&1 || die "缺少 awk"

	ok "系统：${PRETTY_NAME:-unknown}  架构：$(uname -m)"
}

# 客户端节点要建 TUN，必须确认设备存在
ensure_tun() {
	step "检查 TUN 设备"

	modprobe tun 2>/dev/null || true

	if [[ ! -e /dev/net/tun ]]; then
		mkdir -p /dev/net 2>/dev/null || true
		mknod /dev/net/tun c 10 200 2>/dev/null || true
		chmod 600 /dev/net/tun 2>/dev/null || true
	fi

	if [[ ! -c /dev/net/tun ]]; then
		cat >&2 <<'HINT'
[x] 找不到 /dev/net/tun，无法创建虚拟网卡。
    常见原因与处理：
      1) 宿主机内核未加载 tun 模块       → modprobe tun
      2) 运行在容器里且未加权限          → docker 需 --device /dev/net/tun --cap-add NET_ADMIN
    如果你只想让它作为「被访问端」而不访问别人，
    可以改用无 TUN 模式（--no-tun），但那需要单独配置。
HINT
		exit 1
	fi

	ok "TUN 设备就绪：/dev/net/tun"
}

# ----------------------------- 交互收集 --------------------------------------
collect_params() {
	step "配置虚拟网络"

	# 1) 网络名称
	if [[ -z "$NET_NAME" ]]; then
		msg ""
		msg "${C_BLD}【1/4】虚拟网络名称${C_RST}"
		msg "  所有要互通的节点必须使用完全相同的网络名称（支持中文）。"
		NET_NAME="$(ask "网络名称: " "")"
	fi
	[[ -n "$NET_NAME" ]] || die "网络名称不能为空"
	case "$NET_NAME" in
		*$'\n'*) die "网络名称不能包含换行" ;;
	esac

	# 2) 网络密码
	if [[ -z "$NET_SECRET" ]]; then
		msg ""
		msg "${C_BLD}【2/4】虚拟网络密码${C_RST}"
		msg "  所有节点必须一致，建议用强密码。输入时不回显。"
		local s1 s2
		s1="$(ask_secret "网络密码: " "")"
		[[ -n "$s1" ]] || die "网络密码不能为空"
		s2="$(ask_secret "再输入一次确认: " "")"
		[[ "$s1" == "$s2" ]] || die "两次输入的密码不一致"
		NET_SECRET="$s1"
	fi
	case "$NET_SECRET" in
		*$'\n'*) die "网络密码不能包含换行" ;;
	esac

	# 3) 共享节点
	if [[ ${#PEERS[@]} -eq 0 ]]; then
		msg ""
		msg "${C_BLD}【3/4】共享节点地址${C_RST}"
		msg "  填你能连上的那个入口，例如："
		msg "    1.2.3.4:31010              （自动补 tcp:// 和端口）"
		msg "    udp://1.2.3.4:31010        （指定协议）"
		msg "  多个用逗号或空格分隔，建议把 tcp 和 udp 都写上，容错更好。"
		local raw
		raw="$(ask "共享节点: " "")"
		[[ -n "$raw" ]] || die "共享节点地址不能为空"
		local item
		for item in ${raw//,/ }; do
			local np
			np="$(normalize_peer "$item")"
			[[ -n "$np" ]] && PEERS+=("$np")
		done
	fi
	[[ ${#PEERS[@]} -gt 0 ]] || die "至少需要一个共享节点地址"

	# 规范化命令行传入的 peer
	local i
	for i in "${!PEERS[@]}"; do
		PEERS[$i]="$(normalize_peer "${PEERS[$i]}")"
	done

	# 剔除空项（例如误写 --peer 但没给值）
	local clean=()
	local q
	for q in "${PEERS[@]}"; do
		[[ -n "$q" ]] && clean+=("$q")
	done
	PEERS=("${clean[@]}")
	[[ ${#PEERS[@]} -gt 0 ]] || die "共享节点地址解析后为空，请检查格式"

	# 4) Web 管理端（可留空）
	if [[ -z "$WEB_CONSOLE" && -z "$ASSUME_YES" ]]; then
		msg ""
		msg "${C_BLD}【4/4】Web 管理端（配置服务器）${C_RST}"
		msg "  格式：udp://1.2.3.4:22020/用户名   或只填用户名（走官方服务器）"
		msg "  不需要就直接回车跳过。"
		WEB_CONSOLE="$(ask "Web 管理端 [留空跳过]: " "")"
	fi
	if [[ -n "$WEB_CONSOLE" ]]; then
		WEB_CONSOLE="$(normalize_web "$WEB_CONSOLE")"
		if [[ "$WEB_CONSOLE" == *[[:space:]]* ]]; then
			die "Web 管理端地址不能包含空格"
		fi
	fi

	# 可选：固定虚拟 IP
	if [[ -z "$VIRTUAL_IP" && -z "$ASSUME_YES" ]]; then
		msg ""
		msg "${C_BLD}【可选】固定虚拟 IP${C_RST}"
		msg "  作为被访问端（服务器）时强烈建议固定，避免 DHCP 重新分配后地址变化。"
		msg "  例如 192.168.66.50（需与网络内其他节点同网段）。留空则自动分配。"
		VIRTUAL_IP="$(ask "固定虚拟 IP [留空=自动分配]: " "")"
	fi

	# 结果汇总
	msg ""
	ok "网络名称   : ${NET_NAME}"
	ok "网络密码   : $(printf '%*s' "${#NET_SECRET}" '' | tr ' ' '*')  (${#NET_SECRET} 位)"
	local p
	for p in "${PEERS[@]}"; do
		ok "共享节点   : ${p}"
	done
	ok "Web 管理端 : ${WEB_CONSOLE:-未启用}"
	ok "虚拟 IP    : ${VIRTUAL_IP:-自动分配(DHCP)}"
}

# ----------------------------- 安装 ------------------------------------------
detect_arch() {
	local m
	m="$(uname -m)"
	case "$m" in
		x86_64|amd64)  echo "x86_64" ;;
		aarch64|arm64) echo "aarch64" ;;
		armv7l|armv7)  echo "armv7" ;;
		*) die "暂不支持的架构：$m" ;;
	esac
}

install_deps() {
	step "安装依赖"
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -qq
	apt-get install -y -qq curl unzip ca-certificates iproute2 >/dev/null
	ok "依赖就绪"
}

download_and_install() {
	step "下载 EasyTier v${ET_VERSION}"

	local arch primary mirror zip src cand
	arch="$(detect_arch)"
	primary="https://github.com/EasyTier/EasyTier/releases/download/v${ET_VERSION}/easytier-linux-${arch}-v${ET_VERSION}.zip"
	mirror="https://ghfast.top/${primary}"

	mkdir -p "$INSTALL_DIR"
	zip="${INSTALL_DIR}/et.zip"
	rm -f "$zip"

	info "架构 ${arch}，尝试官方源…"
	if ! curl -fL --connect-timeout 15 --retry 2 -o "$zip" "$primary" 2>/dev/null; then
		warn "官方源失败，改用镜像 ghfast.top…"
		curl -fL --connect-timeout 15 --retry 2 -o "$zip" "$mirror" \
			|| die "下载失败，请检查网络或手动下载：$primary"
	fi
	[[ -s "$zip" ]] || die "下载到的文件为空"

	step "解压并安装"

	# 官方 zip 内带一层 easytier-linux-<arch>/ 子目录，递归查找避免踩坑
	local tmp
	tmp="$(mktemp -d)"
	EXTRACT_DIR="$tmp"
	trap 'if [[ -n "${EXTRACT_DIR:-}" ]]; then rm -rf "$EXTRACT_DIR"; fi' EXIT
	unzip -q -o "$zip" -d "$tmp"

	src="$tmp"
	if [[ ! -f "$tmp/easytier-core" ]]; then
		cand="$(find "$tmp" -maxdepth 3 -type f -name easytier-core | head -n 1 || true)"
		[[ -n "$cand" ]] || die "压缩包结构异常，找不到 easytier-core"
		src="$(dirname "$cand")"
	fi
	[[ -f "$src/easytier-cli" ]] || die "压缩包结构异常，找不到 easytier-cli"

	install -m 0755 "$src/easytier-core" "${INSTALL_DIR}/easytier-core.new"
	install -m 0755 "$src/easytier-cli"  "${INSTALL_DIR}/easytier-cli.new"
	mv -f "${INSTALL_DIR}/easytier-core.new" "${INSTALL_DIR}/easytier-core"
	mv -f "${INSTALL_DIR}/easytier-cli.new"  "${INSTALL_DIR}/easytier-cli"

	rm -f "$zip"
	"${INSTALL_DIR}/easytier-core" --version >/dev/null 2>&1 \
		|| die "二进制无法执行，可能是架构不匹配"

	ln -sf "${INSTALL_DIR}/easytier-cli" "$CLI_LINK"
	ok "已安装：$("${INSTALL_DIR}/easytier-core" --version 2>/dev/null | head -n 1)"
}

# ----------------------------- 生成配置 --------------------------------------
write_config() {
	step "生成配置文件"

	mkdir -p "$CONF_DIR" "$DATA_DIR" "$LOG_DIR"
	chmod 700 "$CONF_DIR"

	local host
	host="$(hostname -s 2>/dev/null || echo ubuntu)"

	{
		printf '# 由 easytier-client-install.sh 生成\n'
		printf '# 修改后执行：systemctl restart %s\n' "$SVC_NAME"
		printf 'instance_name = "default"\n'
		printf 'hostname = "%s"\n' "$(toml_escape "$host")"
		if [[ -n "$VIRTUAL_IP" ]]; then
			printf 'ipv4 = "%s"\n' "$(toml_escape "$VIRTUAL_IP")"
		else
			printf 'dhcp = true\n'
		fi
		printf '\n[network_identity]\n'
		printf 'network_name = "%s"\n' "$(toml_escape "$NET_NAME")"
		printf 'network_secret = "%s"\n' "$(toml_escape "$NET_SECRET")"

		local p
		for p in "${PEERS[@]}"; do
			printf '\n[[peer]]\n'
			printf 'uri = "%s"\n' "$(toml_escape "$p")"
		done
	} >"$CONF_FILE"

	chmod 600 "$CONF_FILE"
	ok "配置已写入：$CONF_FILE"
}

write_unit() {
	step "注册系统服务"

	local exec_args
	exec_args="-c ${CONF_FILE} --file-log-level info --file-log-dir ${LOG_DIR}"
	if [[ -n "$WEB_CONSOLE" ]]; then
		exec_args="${exec_args} -w \"${WEB_CONSOLE}\""
	fi

	cat >"$UNIT_FILE" <<UNITEOF
[Unit]
Description=EasyTier Client Node
Documentation=https://www.easytier.cn
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
# 客户端节点需要创建 TUN 设备并配置路由，必须以 root 运行
WorkingDirectory=${DATA_DIR}
ExecStart=${INSTALL_DIR}/easytier-core ${exec_args}
Restart=always
RestartSec=5

# 连接数较多时避免 fd 耗尽
LimitNOFILE=1048576

# 基础加固（保留创建网卡所需的能力）
NoNewPrivileges=false
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=${DATA_DIR} ${LOG_DIR}

[Install]
WantedBy=multi-user.target
UNITEOF

	systemctl daemon-reload
	systemctl enable "$SVC_NAME" >/dev/null 2>&1 || true
	ok "服务已注册并设为开机自启：$UNIT_FILE"
}

restart_service() {
	step "启动服务"
	systemctl restart "$SVC_NAME"

	local i
	for i in $(seq 1 24); do
		systemctl is-active --quiet "$SVC_NAME" && return 0
		sleep 0.5
	done

	warn "服务未能启动，最近日志如下："
	journalctl -u "$SVC_NAME" -n 40 --no-pager || true
	die "服务启动失败"
}

# ----------------------------- 验证 ------------------------------------------
node_field() {
	local key="$1"
	"${INSTALL_DIR}/easytier-cli" node 2>/dev/null \
		| awk -F'|' -v k="$key" '$2 ~ k {v=$3; sub(/^[ \t]+/,"",v); sub(/[ \t]+$/,"",v); print v; exit}' \
		|| true
}

print_verification() {
	local vip hostname peers
	vip="$(node_field 'Virtual IP')"
	hostname="$(node_field 'Hostname')"

	# 等一小会儿让 peer 建连
	sleep 2
	peers="$("${INSTALL_DIR}/easytier-cli" peer 2>/dev/null | head -n 12 || true)"

	msg ""
	msg "=================================================================="
	msg "${C_BLD} EasyTier 客户端节点安装完成${C_RST}"
	msg "=================================================================="
	msg ""
	msg " 服务状态   : $(systemctl is-active "$SVC_NAME" 2>/dev/null || echo unknown) / 开机自启 $(systemctl is-enabled "$SVC_NAME" 2>/dev/null || echo unknown)"
	msg " 网络名称   : ${NET_NAME}"
	msg " 共享节点   : ${PEERS[*]}"
	msg " Web 管理端 : ${WEB_CONSOLE:-未启用}"
	msg " 虚拟 IP    : ${vip:-尚未分配}"
	msg " 主机名     : ${hostname:-未知}"
	msg ""
	msg "------------------------------------------------------------------"
	msg " ${C_BLD}对端连接情况${C_RST}"
	msg "------------------------------------------------------------------"
	if [[ -n "$peers" ]]; then
		printf '%s\n' "$peers"
	else
		msg "  （暂无对端，可能网络里还没有其他节点）"
	fi
	msg ""
	msg "------------------------------------------------------------------"
	msg " ${C_BLD}常用命令${C_RST}"
	msg "------------------------------------------------------------------"
	msg "  查看本节点   : easytier-cli node"
	msg "  查看对端     : easytier-cli peer"
	msg "  查看路由     : easytier-cli route      # next_hop 为 DIRECT 即直连"
	msg "  查看日志     : journalctl -u ${SVC_NAME} -f"
	msg "  重启服务     : systemctl restart ${SVC_NAME}"
	msg "  修改配置     : vi ${CONF_FILE}  然后 systemctl restart ${SVC_NAME}"
	msg ""

	if [[ -n "$vip" ]]; then
		msg "------------------------------------------------------------------"
		msg " ${C_BLD}现在可以这样访问本机${C_RST}"
		msg "------------------------------------------------------------------"
		msg "  ssh <用户>@${vip}"
		msg "  curl http://${vip}:<端口>/"
		msg ""
	fi

	if [[ -n "$WEB_CONSOLE" ]]; then
		msg "------------------------------------------------------------------"
		msg " ${C_YEL}注意：已启用 Web 管理端${C_RST}"
		msg "------------------------------------------------------------------"
		msg " 该节点的配置可能会被控制台下发的配置覆盖，"
		msg " 如果发现本地改的参数不生效，请到控制台里改。"
		msg ""
	fi

	if [[ -z "$VIRTUAL_IP" ]]; then
		msg "提示：当前使用 DHCP 自动分配虚拟 IP。如果这台机器要给别人长期访问，"
		msg "     建议改成本地固定 IP，避免地址变化："
		msg "     编辑 ${CONF_FILE}，把 dhcp = true 换成 ipv4 = \"192.168.66.50\""
		msg ""
	fi

	msg "=================================================================="
	msg " 防火墙提醒：本机需要放行 EasyTier 的监听端口（默认 11010 TCP/UDP）"
	msg " 才能被其他节点主动连入；只做客户端可不放行。"
	msg "=================================================================="
	msg ""
}

# ----------------------------- 主流程 ----------------------------------------
main() {
	msg ""
	msg "${C_BLD}EasyTier 客户端节点安装脚本${C_RST}  (v${ET_VERSION})"
	msg "--------------------------------------------------------------"

	check_env
	ensure_tun
	collect_params
	install_deps
	download_and_install
	write_config
	write_unit
	restart_service
	print_verification
}

main "$@"
