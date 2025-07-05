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

# RSA 私钥的路径
DEFAULT_IDENTITY_PATH="$ROOT"/swarm.pem
IDENTITY_PATH=${IDENTITY_PATH:-$DEFAULT_IDENTITY_PATH}

GENSYN_RESET_CONFIG=${GENSYN_RESET_CONFIG:-""}

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

# 内存清理函数（macOS专用）
clean_memory() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo_blue ">> 正在清理 macOS 内存缓存..."
        # 尝试不同方法释放内存
        sudo purge 2>/dev/null || true
        sync && sudo sysctl vm.drop_caches=3 2>/dev/null || true
        sleep 2
    fi
}

ROOT_DIR="$(cd $(dirname ${BASH_SOURCE[0]}) && pwd)"

# 脚本退出时清理服务器进程的函数
cleanup() {
    echo_green ">> 正在关闭训练器..."
    
    # 清理内存
    clean_memory

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
    
    # 安装 Homebrew（如果尚未安装）
    if [[ "$OSTYPE" == "darwin"* ]] && ! command -v brew > /dev/null 2>&1; then
        echo "正在安装 Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        # 配置环境变量
        if [[ $(uname -m) == 'arm64' ]]; then
            echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
            eval "$(/opt/homebrew/bin/brew shellenv)"
        else
            echo 'eval "$(/usr/local/bin/brew shellenv)"' >> ~/.zprofile
            eval "$(/usr/local/bin/brew shellenv)"
        fi
    fi
    
    # Node.js + Homebrew 设置
    if ! command -v node > /dev/null 2>&1; then
        echo "未找到 Node.js。正在使用 Homebrew 安装 Node.js..."
        brew install node
    else
        echo "Node.js 已安装: $(node -v)"
    fi

    if ! command -v yarn > /dev/null 2>&1; then
        echo "检测到 macOS。正在通过 Homebrew 安装 Yarn..."
        brew install yarn
    fi

    ENV_FILE="$ROOT"/modal-login/.env
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS 版本
        sed -i '' "3s/.*/SMART_CONTRACT_ADDRESS=$SWARM_CONTRACT/" "$ENV_FILE"
    else
        # Linux 版本
        sed -i "3s/.*/SMART_CONTRACT_ADDRESS=$SWARM_CONTRACT/" "$ENV_FILE"
    fi

    # 构建服务器
    yarn install --immutable
    echo "正在构建服务器"
    yarn build > "$ROOT/logs/yarn.log" 2>&1
    yarn start >> "$ROOT/logs/yarn.log" 2>&1 & # 在后台运行并记录输出

    SERVER_PID=$!  # 存储进程 ID
    echo "已启动服务器进程: $SERVER_PID"
    sleep 5

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

# M4 优化安装
# 安装针对 Apple Silicon 优化的 PyTorch
if [[ "$OSTYPE" == "darwin"* ]] && [[ $(uname -m) == 'arm64' ]]; then
    echo_green ">> 为 Apple Silicon M4 安装优化的 PyTorch..."
    # 安装 PyTorch 和 Metal Performance Shaders (MPS) 支持
    pip install torch torchvision torchaudio
else
    # 其他系统的标准安装
    pip install torch torchvision torchaudio
fi

# 安装其他依赖
echo_green ">> 安装 GenRL..."
pip install gensyn-genrl==0.1.4
pip install reasoning-gym>=0.1.20 # 用于推理健身房环境
pip install trl # 用于 grpo 配置，不久后将弃用
pip install hivemind@git+https://github.com/learning-at-home/hivemind@4d5c41495be082490ea44cce4e9dd58f9926bb4e # 需要最新版本，1.1.11 版本有问题

# 安装性能优化库
echo_green ">> 安装性能优化库..."
pip install --pre torch torchvision torchaudio --extra-index-url https://download.pytorch.org/whl/nightly/cpu
pip install accelerate  # 分布式训练加速
pip install bitsandbytes  # 量化支持
pip install flash-attn  # 注意力机制优化
pip install optimum  # Hugging Face 优化库

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

# 设置工作线程数为 CPU 核心数
export NUM_WORKERS=$(sysctl -n hw.ncpu)
echo_green ">> 设置工作线程数: $NUM_WORKERS"

echo_green ">> 祝您好运，加入集群！"
echo_blue ">> 记得在 GitHub 上给仓库加星哦！ --> https://github.com/gensyn-ai/rl-swarm"

# 定时内存清理任务（仅 macOS）
if [[ "$OSTYPE" == "darwin"* ]]; then
    (
        while true; do
            sleep 600  # 每10分钟清理一次
            clean_memory
        done
    ) &
    CLEANER_PID=$!
    trap "kill $CLEANER_PID 2>/dev/null || true" EXIT  # 确保清理进程会被终止
fi

# M4 训练优化
# 设置环境变量以优化 Apple Silicon 性能
if [[ "$OSTYPE" == "darwin"* ]] && [[ $(uname -m) == 'arm64' ]]; then
    echo_green ">> 启用 Apple M4 优化..."
    # 启用 Metal Performance Shaders (MPS)
    export PYTORCH_ENABLE_MPS_FALLBACK=1
    
    # 优化线程和内存管理
    export OMP_NUM_THREADS=$NUM_WORKERS
    export MKL_NUM_THREADS=$OMP_NUM_THREADS
    export NUMEXPR_NUM_THREADS=$OMP_NUM_THREADS
    export VECLIB_MAXIMUM_THREADS=$OMP_NUM_THREADS
    
    # 启用低精度训练
    export USE_FP16=1
    export USE_BF16=1
    
    # JIT 编译优化
    export PYTORCH_JIT=1
    export TORCHINDUCTOR_CACHE_DIR="$ROOT/torch_cache"
    mkdir -p "$TORCHINDUCTOR_CACHE_DIR"
    
    # 设置 GPU 利用率模式为高
    osascript -e 'tell application "System Events" to set power mode of every graphics card to high'
fi

# 启动训练 - 添加性能优化参数
python -m rgym_exp.runner.swarm_launcher \
    --config-path "$ROOT/rgym_exp/config" \
    --config-name "rg-swarm.yaml"

wait  # 保持脚本运行，直到用户按下 Ctrl+C
