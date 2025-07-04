#!/bin/bash

set -euo pipefail

# 通用参数
ROOT=$PWD

# 使用的 GenRL Swarm 版本
GENRL_TAG="v0.1.1"

export IDENTITY_PATH
export GENSYN_RESET_CONFIG
export CONNECT_TO_TESTNET=true
export ORG_ID
export HF_HUB_DOWNLOAD_TIMEOUT=120  # 2 分钟
export SWARM_CONTRACT="0xFaD7C5e93f28257429569B854151A1B8DCD404c2"
export HUGGINGFACE_ACCESS_TOKEN="None"

# RSA 私钥的路径。如果该路径不存在，将创建一个新的密钥对。
# 如果需要新的 PeerID，请删除此文件。
DEFAULT_IDENTITY_PATH="$ROOT"/swarm.pem
IDENTITY_PATH=${IDENTITY_PATH:-$DEFAULT_IDENTITY_PATH}

DOCKER=${DOCKER:-""}
GENSYN_RESET_CONFIG=${GENSYN_RESET_CONFIG:-""}

# 针对非根 Docker 容器的一个变通方法。
if [ -n "$DOCKER" ]; then
    volumes=(
        /home/gensyn/rl_swarm/modal-login/temp-data
        /home/gensyn/rl_swarm/keys
        /home/gensyn/rl_swarm/configs
        /home/gensyn/rl_swarm/logs
    )

    for volume in ${volumes[@]}; do
        sudo chown -R 1001:1001 $volume
    done
fi

# 如果设置了该参数，将忽略所有可见的 GPU。
CPU_ONLY=${CPU_ONLY:-""}

# 如果从 modal-login/temp-data/userData.json 成功解析，则设置该参数。
ORG_ID=${ORG_ID:-""}

GREEN_TEXT="\033[32m"
BLUE_TEXT="\033[34m"
RED_TEXT="\033[31m"
RESET_TEXT="\033[0m"

# 输出绿色文本的函数
echo_green() {
    echo -e "$GREEN_TEXT$1$RESET_TEXT"
}

# 输出蓝色文本的函数
echo_blue() {
    echo -e "$BLUE_TEXT$1$RESET_TEXT"
}

# 输出红色文本的函数
echo_red() {
    echo -e "$RED_TEXT$1$RESET_TEXT"
}

ROOT_DIR="$(cd $(dirname ${BASH_SOURCE[0]}) && pwd)"

# 脚本退出时清理服务器进程的函数
cleanup() {
    echo_green ">> 正在关闭训练器..."

    # 如果存在模态凭证，则删除它们
    # rm -r $ROOT_DIR/modal-login/temp-data/*.json 2> /dev/null || true

    # 杀死属于此脚本进程组的所有进程
    kill -- -$$ || true

    exit 0
}

# 错误通知函数
errnotify() {
    echo_red ">> 运行 rl-swarm 时检测到错误。请查看 $ROOT/logs 中的完整日志。"
}

# 捕获退出信号并执行清理操作
trap cleanup EXIT
# 捕获错误信号并执行错误通知
trap errnotify ERR

echo -e "\033[38;5;224m"
cat << "EOF"
    ██████  ██            ███████ ██     ██  █████  ██████  ███    ███
    ██   ██ ██            ██      ██     ██ ██   ██ ██   ██ ████  ████
    ██████  ██      █████ ███████ ██  █  ██ ███████ ██████  ██ ████ ██
    ██   ██ ██                 ██ ██ ███ ██ ██   ██ ██   ██ ██  ██  ██
    ██   ██ ███████       ███████  ███ ███  ██   ██ ██   ██ ██      ██

    来自 Gensyn

EOF

# 如果日志目录不存在，则创建它
mkdir -p "$ROOT/logs"

# 如果连接到测试网络
if [ "$CONNECT_TO_TESTNET" = true ]; then
    # 运行模态登录服务器
    echo "请登录以创建一个以太坊服务器钱包"
    cd modal-login
    # 检查 yarn 命令是否存在；如果不存在，则安装 Yarn。

    # Node.js + NVM 设置
    if ! command -v node > /dev/null 2>&1; then
        echo "未找到 Node.js。正在安装 NVM 和最新的 Node.js..."
        export NVM_DIR="$HOME/.nvm"
        if [ ! -d "$NVM_DIR" ]; then
            curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
        fi
        [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
        [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
        nvm install node
    else
        echo "Node.js 已安装: $(node -v)"
    fi

    if ! command -v yarn > /dev/null 2>&1; then
        # 检测 Ubuntu（包括 WSL Ubuntu）并相应地安装 Yarn
        if grep -qi "ubuntu" /etc/os-release 2> /dev/null || uname -r | grep -qi "microsoft"; then
            echo "检测到 Ubuntu 或 WSL Ubuntu。正在通过 apt 安装 Yarn..."
            curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | sudo apt-key add -
            echo "deb https://dl.yarnpkg.com/debian/ stable main" | sudo tee /etc/apt/sources.list.d/yarn.list
            sudo apt update && sudo apt install -y yarn
        else
            echo "未找到 Yarn。正在使用 npm 全局安装 Yarn（不编辑配置文件）…"
            # 此命令将 Yarn 安装到 $NVM_DIR/versions/node/<ver>/bin 目录，该目录已在 PATH 中
            npm install -g --silent yarn
        fi
    fi

    ENV_FILE="$ROOT"/modal-login/.env
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS 版本
        sed -i '' "3s/.*/SMART_CONTRACT_ADDRESS=$SWARM_CONTRACT/" "$ENV_FILE"
    else
        # Linux 版本
        sed -i "3s/.*/SMART_CONTRACT_ADDRESS=$SWARM_CONTRACT/" "$ENV_FILE"
    fi

    # Docker 镜像已经构建过，无需再次构建。
    if [ -z "$DOCKER" ]; then
        yarn install --immutable
        echo "正在构建服务器"
        yarn build > "$ROOT/logs/yarn.log" 2>&1
    fi
    yarn start >> "$ROOT/logs/yarn.log" 2>&1 & # 在后台运行并记录输出

    SERVER_PID=$!  # 存储进程 ID
    echo "已启动服务器进程: $SERVER_PID"
    sleep 5

    # 尝试在默认浏览器中打开 URL
    #if [ -z "$DOCKER" ]; then
    #    if open http://localhost:3000 2> /dev/null; then
    #        echo_green ">> 已成功在默认浏览器中打开 http://localhost:3000。"
    #    else
    #        echo ">> 无法打开 http://localhost:3000。请手动打开。"
    #    fi
    #else
    #    echo_green ">> 请在主机浏览器中打开 http://localhost:3000。"
    #fi

    cd ..

    echo_green ">> 正在等待 modal userData.json 文件创建... 请在浏览器中打开 http://localhost:3000 并登录账号"
    while [ ! -f "modal-login/temp-data/userData.json" ]; do
        sleep 5  # 每 5 秒检查一次
    done
    echo "找到 userData.json 文件。继续执行..."

    ORG_ID=$(awk 'BEGIN { FS = "\"" } !/^[ \t]*[{}]/ { print $(NF - 1); exit }' modal-login/temp-data/userData.json)
    echo "您的 ORG_ID 已设置为: $ORG_ID"

    # 等待客户端激活 API 密钥
    echo "正在等待 API 密钥激活..."
    while true; do
        STATUS=$(curl -s "http://localhost:3000/api/get-api-key-status?orgId=$ORG_ID")
        if [[ "$STATUS" == "activated" ]]; then
            echo "API 密钥已激活！继续执行..."
            break
        else
            echo "正在等待 API 密钥激活..."
            sleep 5
        fi
    done
fi

echo_green ">> 正在获取依赖项..."
pip install --upgrade pip

# echo_green ">> 正在安装 GenRL..."
pip install gensyn-genrl==0.1.4
pip install reasoning-gym>=0.1.20 # 用于推理健身房环境
pip install trl # 用于 grpo 配置，不久后将弃用
pip install hivemind@git+https://github.com/learning-at-home/hivemind@4d5c41495be082490ea44cce4e9dd58f9926bb4e # 需要最新版本，1.1.11 版本有问题

# 如果配置目录不存在，则创建它
if [ ! -d "$ROOT/configs" ]; then
    mkdir "$ROOT/configs"
fi
# 如果配置文件存在
if [ -f "$ROOT/configs/rg-swarm.yaml" ]; then
    # 使用 cmp -s 进行静默比较。如果不同，则备份并复制。
    if ! cmp -s "$ROOT/rgym_exp/config/rg-swarm.yaml" "$ROOT/configs/rg-swarm.yaml"; then
        if [ -z "$GENSYN_RESET_CONFIG" ]; then
            echo_green ">> 发现 rg-swarm.yaml 文件存在差异。如果您想重置为默认配置，请将 GENSYN_RESET_CONFIG 设置为非空值。"
        else
            echo_green ">> 发现 rg-swarm.yaml 文件存在差异。正在备份现有配置。"
            mv "$ROOT/configs/rg-swarm.yaml" "$ROOT/configs/rg-swarm.yaml.bak"
            cp "$ROOT/rgym_exp/config/rg-swarm.yaml" "$ROOT/configs/rg-swarm.yaml"
        fi
    fi
else
    # 如果配置文件不存在，则直接复制
    cp "$ROOT/rgym_exp/config/rg-swarm.yaml" "$ROOT/configs/rg-swarm.yaml"
fi

if [ -n "$DOCKER" ]; then
    # 方便在 Linux 系统上编辑配置文件
    sudo chmod -R 0777 /home/gensyn/rl_swarm/configs
fi

echo_green ">> 完成！"

HF_TOKEN=${HF_TOKEN:-""}
# 检查 HF_TOKEN 是否已经设置，如果设置则使用，否则提示用户选择
if [ -n "${HF_TOKEN}" ]; then
    HUGGINGFACE_ACCESS_TOKEN=${HF_TOKEN}
else
    echo -en $GREEN_TEXT
    read -p ">> 您是否想将在 RL 集群中训练的模型推送到 Hugging Face Hub？[y/N] " yn
    echo -en $RESET_TEXT
    yn=${yn:-N} # 默认选择 "N"
    case $yn in
        [Yy]*) read -p "请输入您的 Hugging Face 访问令牌: " HUGGINGFACE_ACCESS_TOKEN ;;
        [Nn]*) HUGGINGFACE_ACCESS_TOKEN="None" ;;
        *) echo ">>> 未给出有效答案，因此不会将模型推送到 Hugging Face Hub" && HUGGINGFACE_ACCESS_TOKEN="None" ;;
    esac
fi

echo -en $GREEN_TEXT
read -p ">> 请以 huggingface 仓库/名称的格式输入您要使用的模型名称，或按 [Enter] 使用默认模型。 " MODEL_NAME
echo -en $RESET_TEXT

# 仅当用户提供非空值时才导出 MODEL_NAME
if [ -n "$MODEL_NAME" ]; then
    export MODEL_NAME
    echo_green ">> 使用模型: $MODEL_NAME"
else
    echo_green ">> 使用配置中的默认模型"
fi

echo_green ">> 祝您好运，加入集群！"
echo_blue ">> 记得在 GitHub 上给仓库加星哦！ --> https://github.com/gensyn-ai/rl-swarm"

python -m rgym_exp.runner.swarm_launcher \
    --config-path "$ROOT/rgym_exp/config" \
    --config-name "rg-swarm.yaml" 

wait  # 保持脚本运行，直到用户按下 Ctrl+C
