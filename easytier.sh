#!/usr/bin/env bash
# shellcheck shell=bash
#
# =============================================================================
#  EasyTier 共享节点一键部署脚本
#  适用：Debian 10+ / Ubuntu 20.04+（需要 systemd、root 权限）
# =============================================================================
#
#  功能：
#    - 交互式选择「牵线(rendezvous)」或「中转(relay)」模式
#    - 交互式输入对外监听端口（适合云厂商只放行高位端口的场景）
#    - 自动下载 Release、解压、安装到 /opt/easytier
#    - 自动创建系统用户、日志目录
#    - 自动写入 systemd 服务并设置开机自启
#    - 自动检测 NAT：若网卡 IP 与公网 IP 不同，自动补 --mapped-listeners
#    - 部署完成后输出完整验证信息
#
#  用法：
#    # 交互式（推荐）
#    sudo bash easytier-shared-node.sh
#
#    # 一行流（把 URL 换成你自己的 GitHub raw 地址）
#    curl -fsSL https://raw.githubusercontent.com/<你>/<仓库>/main/easytier-shared-node.sh | sudo bash
#
#    # 全自动、无交互
#    sudo bash easytier-shared-node.sh --mode rendezvous --port 31010 -y
#
#    # 指定版本
#    sudo bash easytier-shared-node.sh --version 2.6.4
#
#    # 查看帮助
#    bash easytier-shared-node.sh --help
#
#  卸载：
#    systemctl disable --now easytier
#    rm -f /etc/systemd/system/easytier.service /etc/default/easytier
#    systemctl daemon-reload
#    rm -rf /opt/easytier /var/lib/easytier /var/log/easytier
#    userdel easytier 2>/dev/null
#    rm -f /usr/local/bin/easytier-cli
#
#  许可：MIT
# =============================================================================

set -euo pipefail

# ----------------------------- 可调默认值 ------------------------------------
ET_VERSION="${ET_VERSION:-2.6.4}"
INSTALL_DIR="/opt/easytier"
DATA_DIR="/var/lib/easytier"
LOG_DIR="/var/log/easytier"
SVC_NAME="easytier"
SVC_USER="easytier"
ENV_FILE="/etc/default/easytier"
UNIT_FILE="/etc/systemd/system/easytier.service"
CLI_LINK="/usr/local/bin/easytier-cli"
DEFAULT_PORT="31010"
MODE=""
PORT=""
ASSUME_YES=""
FORCE=""
EXTRACT_DIR=""

# ----------------------------- 颜色与输出 ------------------------------------
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
# 关键点：脚本可能通过 curl | bash 执行，此时 stdin 是脚本自身，
# 必须从 /dev/tty 读用户输入，否则会把脚本内容当答案吃掉。
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

confirm() {
	local prompt="$1" default="${2:-n}" ans
	ans="$(ask "$prompt" "$default")"
	[[ "$ans" =~ ^[Yy]([Ee][Ss])?$ ]]
}

usage() {
	cat <<'USAGE'
EasyTier 共享节点一键部署脚本

用法:
  sudo bash easytier-shared-node.sh [选项]

选项:
  --mode <rendezvous|relay>  工作模式：rendezvous=只牵线，relay=牵线+中转兜底
  --port <端口>              对外监听端口（默认 31010）
  --version <版本号>         EasyTier 版本（默认 2.6.4）
  -y, --yes                  全自动，不询问（使用默认值）
  --force                    跳过系统检查（非 Debian/Ubuntu 时）
  -h, --help                 显示本帮助

模式说明:
  rendezvous  只帮节点互相发现/握手配对，不转发业务流量。省带宽，但 P2P 打不通时无兜底。
  relay       帮发现，且 P2P 打不通时替节点转发流量。有兜底，会消耗服务器带宽。
USAGE
}

# ----------------------------- 参数解析 --------------------------------------
while [[ $# -gt 0 ]]; do
	case "$1" in
		--mode)    MODE="${2:-}"; if [[ $# -ge 2 ]]; then shift 2; else shift; fi ;;
		--mode=*)  MODE="${1#*=}"; shift ;;
		--port)    PORT="${2:-}"; if [[ $# -ge 2 ]]; then shift 2; else shift; fi ;;
		--port=*)  PORT="${1#*=}"; shift ;;
		--version) ET_VERSION="${2:-}"; if [[ $# -ge 2 ]]; then shift 2; else shift; fi ;;
		--version=*) ET_VERSION="${1#*=}"; shift ;;
		-y|--yes)  ASSUME_YES=1; shift ;;
		--force)   FORCE=1; shift ;;
		-h|--help) usage; exit 0 ;;
		"")        shift ;;
		*)         die "未知参数: $1（用 --help 查看用法）" ;;
	esac
done

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
			warn "当前系统 ${PRETTY_NAME:-未知} 不在 Debian/Ubuntu 范围内，按 --force 继续"
		else
			die "本脚本面向 Debian/Ubuntu，当前为 ${PRETTY_NAME:-未知}；确认要继续请加 --force"
		fi
	fi

	command -v systemctl >/dev/null 2>&1 || die "需要 systemd，未找到 systemctl"
	command -v awk >/dev/null 2>&1 || die "缺少 awk"
	command -v unzip >/dev/null 2>&1 || info "未找到 unzip，稍后自动安装"

	ok "系统：${PRETTY_NAME:-unknown}  架构：$(uname -m)"
}

detect_arch() {
	local m
	m="$(uname -m)"
	case "$m" in
		x86_64|amd64)  echo "x86_64" ;;
		aarch64|arm64) echo "aarch64" ;;
		armv7l|armv7)  echo "armv7" ;;
		*) die "暂不支持的架构：$m（可手动下载对应 Release 后自行部署）" ;;
	esac
}

# ----------------------------- 交互：模式与端口 ------------------------------
choose_mode() {
	case "$MODE" in
		1) MODE="rendezvous" ;;
		2) MODE="relay" ;;
	esac

	if [[ -z "$MODE" ]]; then
		msg ""
		msg "${C_BLD}请选择这台共享节点的工作模式：${C_RST}"
		msg "  ${C_GRN}1) 牵线（rendezvous）${C_RST}  只帮节点发现/握手配对，不转发业务流量，省带宽"
		msg "  ${C_GRN}2) 中转（relay）${C_RST}       帮节点发现，且 P2P 打不通时替它转发流量，有兜底但费带宽"
		msg ""
		local ans
		ans="$(ask "请输入 1 或 2 [默认 1]: " "1")"
		case "$ans" in
			1) MODE="rendezvous" ;;
			2) MODE="relay" ;;
			*) die "无效选择：$ans" ;;
		esac
	fi

	[[ "$MODE" == "rendezvous" || "$MODE" == "relay" ]] \
		|| die "--mode 只支持 rendezvous 或 relay，收到：$MODE"

	ok "工作模式：$MODE"
}

port_in_use() {
	local p="$1"
	command -v ss >/dev/null 2>&1 || return 1
	ss -lntu 2>/dev/null | awk -v pat=":${p}\$" 'NR>1 && $5 ~ pat {f=1} END{exit f?0:1}'
}

choose_port() {
	if [[ -z "$PORT" ]]; then
		msg ""
		msg "请输入对外监听端口。"
		msg "  默认 ${DEFAULT_PORT}。若云厂商只允许 30000 以上端口，就填 3xxxx。"
		PORT="$(ask "监听端口 [默认 ${DEFAULT_PORT}]: " "$DEFAULT_PORT")"
	fi

	[[ "$PORT" =~ ^[0-9]+$ ]] || die "端口必须是纯数字：$PORT"
	(( PORT >= 1 && PORT <= 65535 )) || die "端口超出 1-65535 范围：$PORT"
	(( PORT > 1024 )) || die "请使用 1024 以上端口（本脚本以非 root 用户运行服务）"

	if port_in_use "$PORT"; then
		if systemctl is-active --quiet "$SVC_NAME" 2>/dev/null; then
			warn "端口 $PORT 当前被运行中的 ${SVC_NAME} 占用（脚本会重启它，正常）"
		else
			local who
			who="$(ss -lntup 2>/dev/null | awk -v pat=":${PORT}\$" '$5 ~ pat' | head -n 3 || true)"
			die "端口 $PORT 已被其他进程占用：${who:-未知进程}"
		fi
	fi

	ok "监听端口：$PORT (TCP + UDP)"
}

# ----------------------------- 安装依赖 --------------------------------------
install_deps() {
	step "安装依赖"
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -qq
	apt-get install -y -qq curl unzip ca-certificates iproute2 >/dev/null
	ok "依赖就绪"
}

# ----------------------------- 下载与放置 ------------------------------------
download_and_install() {
	step "下载 EasyTier v${ET_VERSION}"

	local arch primary mirror zip tmp src cand
	arch="$(detect_arch)"
	primary="https://github.com/EasyTier/EasyTier/releases/download/v${ET_VERSION}/easytier-linux-${arch}-v${ET_VERSION}.zip"
	mirror="https://ghfast.top/${primary}"

	mkdir -p "$INSTALL_DIR"
	zip="${INSTALL_DIR}/et.zip"
	rm -f "$zip"

	info "架构 $arch，尝试官方源…"
	if ! curl -fL --connect-timeout 15 --retry 2 -o "$zip" "$primary" 2>/dev/null; then
		warn "官方源失败，改用镜像 ghfast.top…"
		curl -fL --connect-timeout 15 --retry 2 -o "$zip" "$mirror" \
			|| die "下载失败，请检查网络或手动下载：$primary"
	fi
	[[ -s "$zip" ]] || die "下载到的文件为空"

	step "解压并安装"

	# 注意：官方 zip 内带一层 easytier-linux-<arch>/ 子目录，这里递归查找，避免踩坑
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
		|| die "二进制无法执行，可能是架构或依赖不匹配"

	ln -sf "${INSTALL_DIR}/easytier-cli" "$CLI_LINK"
	ok "已安装：$("${INSTALL_DIR}/easytier-core" --version 2>/dev/null | head -n 1)"
}

# ----------------------------- 用户与目录 ------------------------------------
prepare_user() {
	step "准备运行用户与目录"

	if ! id "$SVC_USER" >/dev/null 2>&1; then
		useradd -r -s /usr/sbin/nologin -d "$DATA_DIR" "$SVC_USER"
		ok "已创建系统用户 $SVC_USER"
	else
		info "系统用户 $SVC_USER 已存在"
	fi

	mkdir -p "$DATA_DIR" "$LOG_DIR"
	chown -R "${SVC_USER}:${SVC_USER}" "$DATA_DIR" "$LOG_DIR"
	ok "目录就绪：$DATA_DIR  $LOG_DIR"
}

# ----------------------------- 生成配置 --------------------------------------
HOSTNAME_TAG=""
BASE_ARGS=""

build_args() {
	HOSTNAME_TAG="${ET_HOSTNAME:-relay1}"
	[[ -n "$HOSTNAME_TAG" ]] || HOSTNAME_TAG="relay1"

	local mode_args=""
	if [[ "$MODE" == "rendezvous" ]]; then
		# 官方文档给出的「只牵线不转发」组合：白名单置空 + 仍转发 RPC
		mode_args=" --relay-network-whitelist --relay-all-peer-rpc"
	fi

	BASE_ARGS="--hostname ${HOSTNAME_TAG} -l tcp:${PORT} -l udp:${PORT} --file-log-level info --file-log-dir ${LOG_DIR}${mode_args}"
}

write_env_file() {
	local extra="${1:-}"
	cat >"$ENV_FILE" <<ENVEOF
# 由 easytier-shared-node.sh 生成
# 修改后执行：systemctl restart ${SVC_NAME}
EASYTIER_ARGS="${extra}${BASE_ARGS}"
ENVEOF
}

write_unit_file() {
	cat >"$UNIT_FILE" <<UNITEOF
[Unit]
Description=EasyTier Shared Node (${MODE})
Documentation=https://www.easytier.cn
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SVC_USER}
Group=${SVC_USER}
WorkingDirectory=${DATA_DIR}
EnvironmentFile=-${ENV_FILE}
ExecStart=${INSTALL_DIR}/easytier-core \$EASYTIER_ARGS
Restart=always
RestartSec=3

# 共享节点连接数高，必须抬高 fd 上限，否则会假死
LimitNOFILE=1048576

# 轻量加固
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
UNITEOF
}

# ----------------------------- 启停服务 --------------------------------------
restart_service() {
	systemctl daemon-reload
	systemctl enable "$SVC_NAME" >/dev/null 2>&1 || true
	systemctl restart "$SVC_NAME"

	local i
	for i in $(seq 1 20); do
		systemctl is-active --quiet "$SVC_NAME" && return 0
		sleep 0.5
	done

	warn "服务未能启动，最近日志如下："
	journalctl -u "$SVC_NAME" -n 40 --no-pager || true
	die "服务启动失败"
}

# ----------------------------- 读取节点信息 ----------------------------------
node_field() {
	local key="$1"
	"${INSTALL_DIR}/easytier-cli" node 2>/dev/null \
		| awk -F'|' -v k="$key" '$2 ~ k {v=$3; sub(/^[ \t]+/,"",v); sub(/[ \t]+$/,"",v); print v; exit}' \
		|| true
}

wait_public_ip() {
	local i ip
	for i in $(seq 1 20); do
		ip="$(node_field 'Public IPv4')"
		[[ -z "$ip" ]] && ip="$(node_field 'Public IP')"
		if [[ -n "$ip" && "$ip" != "0.0.0.0" ]]; then
			printf '%s' "$ip"
			return 0
		fi
		sleep 1
	done
	return 1
}

# 网卡 IP 与公网 IP 不一致 => 机器在 NAT 后面，需要显式告知对外地址
autofix_mapped_listeners() {
	PUB_IP=""
	IFACE_IP=""

	PUB_IP="$(wait_public_ip || true)"
	IFACE_IP="$(node_field 'Interface IPv4')"

	if [[ -z "$PUB_IP" ]]; then
		warn "未获取到公网 IP（STUN 失败），多半是 UDP 出站被拦或安全组未放行"
		return 0
	fi

	if [[ -n "$IFACE_IP" && "$PUB_IP" == "$IFACE_IP" ]]; then
		info "网卡地址与公网地址一致，无需 mapped-listeners"
		return 0
	fi

	if grep -q -- "--mapped-listeners" "$ENV_FILE" 2>/dev/null; then
		info "已存在 mapped-listeners 配置，跳过"
		return 0
	fi

	step "检测到 NAT，自动补全对外地址"
	warn "网卡 IP: ${IFACE_IP:-未知}  公网 IP: ${PUB_IP}"
	info "追加 --mapped-listeners，让其他节点能用正确地址连到本机"

	local extra
	extra="--mapped-listeners tcp://${PUB_IP}:${PORT} --mapped-listeners udp://${PUB_IP}:${PORT} "
	write_env_file "$extra"
	restart_service
	ok "已写入 mapped-listeners 并重启服务"
}

# ----------------------------- 验证输出 --------------------------------------
print_verification() {
	local pub stun listeners client_host
	pub="$(wait_public_ip || true)"
	stun="$(node_field 'UDP Stun Type')"
	listeners="$(ss -lntu 2>/dev/null | awk -v pat=":${PORT}\$" 'NR>1 && $5 ~ pat {print "  " $1 "  " $5}' || true)"

	client_host="${pub:-<你的VPS公网IP>}"

	msg ""
	msg "=================================================================="
	msg "${C_BLD} EasyTier 共享节点部署完成${C_RST}"
	msg "=================================================================="
	msg ""
	msg " 服务状态   : $(systemctl is-active "$SVC_NAME" 2>/dev/null || echo unknown) / 开机自启 $(systemctl is-enabled "$SVC_NAME" 2>/dev/null || echo unknown)"
	msg " 工作模式   : ${MODE}"
	msg " 监听端口   : ${PORT} (TCP + UDP)"
	msg " 公网 IP    : ${pub:-未获取到}"
	msg " NAT 类型   : ${stun:-未知}"
	msg " 主机名标识 : ${HOSTNAME_TAG}"
	msg ""
	msg " 当前监听:"
	if [[ -n "$listeners" ]]; then
		printf '%s\n' "$listeners"
	else
		msg "  （未检测到，请执行 ss -lntup | grep ${PORT} 排查）"
	fi
	msg ""
	msg "------------------------------------------------------------------"
	msg " ${C_BLD}客户端接入方式${C_RST}"
	msg "------------------------------------------------------------------"
	msg " 命令行："
	msg "   easytier-core -d --network-name <网络名> --network-secret <密钥> \\"
	msg "     -p tcp://${client_host}:${PORT} \\"
	msg "     -p udp://${client_host}:${PORT}"
	msg ""
	msg " GUI：在「初始节点 / 对等节点」里逐个填入："
	msg "   tcp://${client_host}:${PORT}"
	msg "   udp://${client_host}:${PORT}"
	msg ""
	msg "------------------------------------------------------------------"
	msg " ${C_BLD}运维命令${C_RST}"
	msg "------------------------------------------------------------------"
	msg "  查看节点信息 : easytier-cli node"
	msg "  查看对端     : easytier-cli peer"
	msg "  查看路由     : easytier-cli route"
	msg "  查看日志     : journalctl -u ${SVC_NAME} -f"
	msg "  文件日志     : tail -f ${LOG_DIR}/*.log"
	msg "  重启服务     : systemctl restart ${SVC_NAME}"
	msg "  停止服务     : systemctl stop ${SVC_NAME}"
	msg "  修改参数     : vi ${ENV_FILE} 然后 systemctl restart ${SVC_NAME}"
	msg ""

	# 关键提醒
	if [[ -n "$stun" && "$stun" != "OpenInternet" ]]; then
		msg "------------------------------------------------------------------"
		msg " ${C_YEL}注意：NAT 类型为 ${stun}${C_RST}"
		msg "------------------------------------------------------------------"
		msg " 说明本机不在「完全开放的公网」上，入站可能受限。建议："
		msg "   1) 在云控制台确认 安全组 已放行 TCP ${PORT} 和 UDP ${PORT}（两条都要）"
		msg "   2) 若厂商使用 1:1 NAT / 弹性公网IP，确认端口转发包含 ${PORT}"
		msg "   3) 从外网验证： nc -vz ${client_host} ${PORT}"
		msg ""
	fi

	if [[ "$MODE" == "rendezvous" ]]; then
		msg "------------------------------------------------------------------"
		msg " ${C_YEL}牵线模式的限制${C_RST}"
		msg "------------------------------------------------------------------"
		msg " 本节点只帮节点互相发现，不转发业务流量。"
		msg " 如果两端 P2P 打不通（例如双方都是 NAT4），它们将无法通信。"
		msg " 需要兜底请改用： --mode relay"
		msg ""
	fi

	msg "=================================================================="
	msg " ${C_BLD}务必检查：云厂商安全组还需放行 TCP ${PORT} 和 UDP ${PORT}${C_RST}"
	msg "=================================================================="
	msg ""
}

# ----------------------------- 主流程 ----------------------------------------
main() {
	msg ""
	msg "${C_BLD}EasyTier 共享节点部署脚本${C_RST}  (v${ET_VERSION})"
	msg "--------------------------------------------------------------"

	check_env
	choose_mode
	choose_port
	install_deps
	download_and_install
	prepare_user

	step "写入配置与服务"
	build_args
	write_env_file ""
	write_unit_file
	ok "配置已写入：$ENV_FILE"
	ok "服务已写入：$UNIT_FILE"

	step "启动服务"
	restart_service
	ok "服务已启动并设置开机自启"

	autofix_mapped_listeners

	print_verification
}

main "$@"
