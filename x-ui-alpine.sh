#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

#Add some basic function here
function LOGD() {
    echo -e "${yellow}[DEG] $* ${plain}"
}

function LOGE() {
    echo -e "${red}[ERR] $* ${plain}"
}

function LOGI() {
    echo -e "${green}[INF] $* ${plain}"
}

# check root
[[ $EUID -ne 0 ]] && LOGE "严重错误: ${plain} 请以 root 权限运行此脚本 \n" && exit 1

# Check OS and set release variable
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    release=$ID
elif [[ -f /usr/lib/os-release ]]; then
    source /usr/lib/os-release
    release=$ID
else
    echo "系统OS检查失败, 请联系作者!" >&2
    exit 1
fi

echo "您的系统类型为: $release"

os_version=""
os_version=$(grep "^VERSION_ID" /etc/os-release | cut -d '=' -f2 | tr -d '"' | tr -d '.')

if [[ "${release}" == "alpine" ]]; then
    echo "您的系统类型为Alpine Linux"
else
    echo -e "${red}该脚本不支持您的操作系统${plain}\n"
    exit 1
fi

# Declare Variables
log_folder="${XUI_LOG_FOLDER:=/var/log}"
iplimit_log_path="${log_folder}/3xipl.log"
iplimit_banned_log_path="${log_folder}/3xipl-banned.log"

# 添加网络检查函数
check_network() {
    # 尝试使用IPv6访问GitHub
    if curl -6 -s https://github.com >/dev/null; then
        return 0
    fi
    
    # 如果IPv6失败，给出提示
    echo "警告: IPv6连接GitHub失败，请检查网络设置"
    return 1
}

confirm() {
    if [[ $# > 1 ]]; then
        echo && read -p "$1 [Default $2]: " temp
        if [[ "${temp}" == "" ]]; then
            temp=$2
        fi
    else
        read -p "$1 [y/n]: " temp
    fi
    if [[ "${temp}" == "y" || "${temp}" == "Y" ]]; then
        return 0
    else
        return 1
    fi
}

confirm_restart() {
    confirm "重启面板, 注意: 重启面板也会重启xray" "y"
    if [[ $? == 0 ]]; then
        restart
    else
        show_menu
    fi
}

before_show_menu() {
    echo && echo -n -e "${yellow}按回车键返回主菜单: ${plain}" && read temp
    show_menu
}

install() {
    bash <(curl -Ls https://raw.githubusercontent.com/56idc/3x-ui-alpine/main/install_alpine.sh)
    if [[ $? == 0 ]]; then
        if [[ $# == 0 ]]; then
            start
        else
            start 0
        fi
    fi
}

update() {
    confirm "此功能将强制重新安装最新版本, 数据不会丢失是否继续?" "y"
    if [[ $? != 0 ]]; then
        LOGE "已取消"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 0
    fi
    bash <(curl -Ls https://raw.githubusercontent.com/56idc/3x-ui-alpine/main/install_alpine.sh)
    if [[ $? == 0 ]]; then
        LOGI "更新完成, 面板已自动重启"
        before_show_menu
    fi
}

check_config() {
    local info=$(/usr/local/x-ui/x-ui setting -show true)
    if [[ $? != 0 ]]; then
        LOGE "获取当前设置错误, 请检查日志"
        show_menu
        return
    fi
    LOGI "${info}"

    local existing_webBasePath=$(echo "$info" | grep -Eo 'webBasePath: .+' | awk '{print $2}')
    local existing_port=$(echo "$info" | grep -Eo 'port: .+' | awk '{print $2}')
    local existing_cert=$(/usr/local/x-ui/x-ui setting -getCert true | grep -Eo 'cert: .+' | awk '{print $2}')
    
    # 获取IPv6地址
    local server_ipv6=$(ip -6 addr show scope global | grep -oP '(?<=inet6 )[\da-f:]+' | head -1)

    if [[ -n "$existing_cert" ]]; then
        local domain=$(basename "$(dirname "$existing_cert")")

        if [[ "$domain" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            echo -e "${green}访问面板URL: https://${domain}:${existing_port}${existing_webBasePath}${plain}"
        else
            echo -e "${green}访问面板URL: https://[${server_ipv6}]:${existing_port}${existing_webBasePath}${plain}"
        fi
    else
        echo -e "${green}访问面板URL: http://[${server_ipv6}]:${existing_port}${existing_webBasePath}${plain}"
    fi
}

# SSL证书申请函数
ssl_cert_issue() {
    local existing_webBasePath=$(/usr/local/x-ui/x-ui setting -show true | grep -Eo 'webBasePath: .+' | awk '{print $2}')
    local existing_port=$(/usr/local/x-ui/x-ui setting -show true | grep -Eo 'port: .+' | awk '{print $2}')
    # check for acme.sh first
    if ! command -v ~/.acme.sh/acme.sh &>/dev/null; then
        echo "acme.sh无法找到, 我们将安装它"
        install_acme
        if [ $? -ne 0 ]; then
            LOGE "安装 acme 失败, 请检查日志"
            exit 1
        fi
    fi

    if [[ "${release}" == "alpine" ]]; then
        apk update && apk add socat
    else
        echo -e "${red}该脚本不支持您的操作系统${plain}\n"
        exit 1
    fi

    if [ $? -ne 0 ]; then
        LOGE "安装socat失败"
        exit 1
    else
        LOGI "安装socat成功"
    fi

    # get the domain here, and we need to verify it
    local domain=""
    read -p "请输入您的域名: " domain
    LOGD "您的域名是: ${domain}"

    # check if there already exists a certificate
    local currentCert=$(~/.acme.sh/acme.sh --list | tail -1 | awk '{print $1}')
    if [ "${currentCert}" == "${domain}" ]; then
        local certInfo=$(~/.acme.sh/acme.sh --list)
        LOGE "系统已有此域名的证书。无法再次颁发。当前证书详细信息:"
        LOGI "$certInfo"
        exit 1
    else
        LOGI "您的域名现在已准备好颁发证书..."
    fi

    # create a directory for the certificate
    certPath="/root/cert/${domain}"
    if [ ! -d "$certPath" ]; then
        mkdir -p "$certPath"
    else
        rm -rf "$certPath"
        mkdir -p "$certPath"
    fi

    # get the port number for the standalone server
    local WebPort=80
    read -p "请选择要使用的端口(默认为 80): " WebPort
    if [[ ${WebPort} -gt 65535 || ${WebPort} -lt 1 ]]; then
        LOGE "您输入的${WebPort}端口无效, 将使用默认端口80"
        WebPort=80
    fi
    LOGI "将使用端口: ${WebPort} 颁发证书, 请确保此端口已开放"

    # 修改后的证书申请命令，添加IPv6支持
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    ~/.acme.sh/acme.sh --issue -d ${domain} --listen-v6 --standalone --httpport ${WebPort}
    if [ $? -ne 0 ]; then
        LOGE "颁发证书失败, 请检查日志"
        rm -rf ~/.acme.sh/${domain}
        exit 1
    else
        LOGE "颁发证书成功, 正在安装证书……"
    fi

    # install the certificate
    ~/.acme.sh/acme.sh --installcert -d ${domain} \
        --key-file /root/cert/${domain}/privkey.pem \
        --fullchain-file /root/cert/${domain}/fullchain.pem

    if [ $? -ne 0 ]; then
        LOGE "安装证书失败, 退出"
        rm -rf ~/.acme.sh/${domain}
        exit 1
    else
        LOGI "证书安装成功, 正在启用自动更新..."
    fi

    # enable auto-renew
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade
    if [ $? -ne 0 ]; then
        LOGE "自动续订失败, 证书详细信息:"
        ls -lah cert/*
        chmod 755 $certPath/*
        exit 1
    else
        LOGI "自动续订成功, 证书详细信息:"
        ls -lah cert/*
        chmod 755 $certPath/*
    fi

    # Prompt user to set panel paths after successful certificate installation
    read -p "是否要为面板设置此证书? (y/n): " setPanel
    if [[ "$setPanel" == "y" || "$setPanel" == "Y" ]]; then
        local webCertFile="/root/cert/${domain}/fullchain.pem"
        local webKeyFile="/root/cert/${domain}/privkey.pem"

        if [[ -f "$webCertFile" && -f "$webKeyFile" ]]; then
            /usr/local/x-ui/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile"
            LOGI "配置面板域名: $domain"
            LOGI "  - 证书文件: $webCertFile"
            LOGI "  - 私钥文件: $webKeyFile"
            echo -e "${green}访问面板URL: https://${domain}:${existing_port}${existing_webBasePath}${plain}"
            restart
        else
            LOGE "错误: 未找到域的证书或私钥文件: $domain."
        fi
    else
        LOGI "跳过面板路径设置"
    fi
}

# 防火墙配置函数
open_ports() {
    # 添加IPv6防火墙规则
    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -I INPUT -p tcp --dport $1 -j ACCEPT
        ip6tables-save > /etc/iptables/rules.v6
    fi
}

delete_ports() {
    # 删除IPv6防火墙规则
    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -D INPUT -p tcp --dport $1 -j ACCEPT
        ip6tables-save > /etc/iptables/rules.v6
    fi
}

show_status() {
    check_status
    case $? in
    0)
        echo -e "面板状态: ${green}运行中...${plain}"
        # 获取并显示IPv6地址
        local ipv6_addr=$(ip -6 addr show scope global | grep -oP '(?<=inet6 )[\da-f:]+' | head -1)
        if [[ -n "$ipv6_addr" ]]; then
            echo -e "IPv6地址: ${green}${ipv6_addr}${plain}"
        fi
        show_enable_status
        ;;
    1)
        echo -e "面板状态: ${yellow}未启动${plain}"
        show_enable_status
        ;;
    2)
        echo -e "面板状态: ${red}未安装${plain}"
        ;;
    esac
    show_xray_status
}

[其余原有函数保持不变...]

# 主菜单函数
show_menu() {
    echo -e "
  ${green}3X-UI面板管理脚本 (IPv6版本)${plain}
  ${green}0.${plain} 退出菜单
————————————————
  ${green}1.${plain} 安装
  ${green}2.${plain} 更新
  ${green}3.${plain} 更新主菜单
  ${green}4.${plain} 安装指定版本
  ${green}5.${plain} 卸载
————————————————
  ${green}6.${plain} 重置用户名密码
  ${green}7.${plain} 重置面板路径
  ${green}8.${plain} 重置配置数据(用户名密码和面板路径不变)
  ${green}9.${plain} 重置面板端口
  ${green}10.${plain} 查看面板配置
————————————————
  ${green}11.${plain} 启动服务
  ${green}12.${plain} 停止服务
  ${green}13.${plain} 重启服务
  ${green}14.${plain} 查看服务状态
  ${green}15.${plain} 查看日志
————————————————
  ${green}16.${plain} 设置开机启动
  ${green}17.${plain} 关闭开机启动
————————————————
  ${green}18.${plain} ACME证书管理 (IPv6支持)
  ${green}19.${plain} Cloudflare证书管理
  ${green}20.${plain} IP限制管理
  ${green}21.${plain} 防火墙管理
  ${green}22.${plain} SSH端口转发管理
————————————————
  ${green}23.${plain} BBR功能
  ${green}24.${plain} 更新Geo文件
  ${green}25.${plain} 速度测试(Ookla)
"
    show_status
    echo && read -p "请输入选项[0-25]: " num

    case "${num}" in
        [原有case语句保持不变...]
    esac
}

# 主程序入口
if [[ $# > 0 ]]; then
    case $1 in
        [原有case语句保持不变...]
    esac
else
    show_menu
fi
