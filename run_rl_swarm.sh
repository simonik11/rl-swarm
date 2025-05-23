#!/bin/bash

set -euo pipefail

ROOT=$PWD
SERVER_PID=""
TUNNEL_PID=""

RED='\033[0;31m'
GREEN='\033[0;32m'
PURPLE='\033[0;95m'
BLUE='\033[0;94m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

GREEN_TEXT="\033[32m"
RESET_TEXT="\033[0m"

echo_green() {
    echo -e "$GREEN_TEXT$1$RESET_TEXT"
}

export PUB_MULTI_ADDRS
export PEER_MULTI_ADDRS
export HOST_MULTI_ADDRS
export IDENTITY_PATH
export CONNECT_TO_TESTNET
export ORG_ID
export HF_HUB_DOWNLOAD_TIMEOUT=120
export CPU_ONLY

DEFAULT_PUB_MULTI_ADDRS=""
PUB_MULTI_ADDRS=${PUB_MULTI_ADDRS:-$DEFAULT_PUB_MULTI_ADDRS}

DEFAULT_PEER_MULTI_ADDRS="/ip4/38.101.215.13/tcp/30002/p2p/QmQ2gEXoPJg6iMBSUFWGzAabS2VhnzuS782Y637hGjfsRJ"
PEER_MULTI_ADDRS=${PEER_MULTI_ADDRS:-$DEFAULT_PEER_MULTI_ADDRS}

DEFAULT_HOST_MULTI_ADDRS="/ip4/0.0.0.0/tcp/38331"
HOST_MULTI_ADDRS=${HOST_MULTI_ADDRS:-$DEFAULT_HOST_MULTI_ADDRS}

DEFAULT_IDENTITY_PATH="$ROOT"/swarm.pem
IDENTITY_PATH=${IDENTITY_PATH:-$DEFAULT_IDENTITY_PATH}

CPU_ONLY=${CPU_ONLY:-""}

cleanup() {
    echo -e "${YELLOW}${BOLD}[✓] Shutting down processes...${NC}"
    rm -r $ROOT/modal-login/temp-data/*.json 2> /dev/null || true
    [ -n "$SERVER_PID" ] && kill $SERVER_PID 2>/dev/null || true
    [ -n "$TUNNEL_PID" ] && kill $TUNNEL_PID 2>/dev/null || true
    kill -- -$$ 2>/dev/null || true
    exit 0
}

trap cleanup EXIT INT

while true; do
    echo -e "${CYAN}${BOLD}[?] Would you like to connect to the Testnet? [Y/n] ${NC}"
    read -p "> " yn
    yn=${yn:-Y}
    case $yn in
        [Yy]*) CONNECT_TO_TESTNET=True && break ;;
        [Nn]*) CONNECT_TO_TESTNET=False && break ;;
        *) echo -e "${RED}${BOLD}[✗] Please answer yes or no.${NC}" ;;
    esac
done

if [ "$CONNECT_TO_TESTNET" = "True" ]; then
    cd modal-login || { echo -e "${RED}${BOLD}[✗] Failed to enter modal-login directory.${NC}"; exit 1; }
    echo -e "${CYAN}${BOLD}[✓] Current directory: $(pwd)${NC}"

    echo -e "\n${CYAN}${BOLD}[✓] Installing dependencies...${NC}"
    if ! command -v yarn > /dev/null 2>&1; then
        if grep -qi "ubuntu" /etc/os-release 2>/dev/null || uname -r | grep -qi "microsoft"; then
            echo -e "${CYAN}${BOLD}[✓] Detected Ubuntu or WSL Ubuntu. Installing Yarn via apt...${NC}"
            curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | sudo apt-key add - || { echo -e "${RED}${BOLD}[✗] Failed to add Yarn GPG key.${NC}"; exit 1; }
            echo "deb https://dl.yarnpkg.com/debian/ stable main" | sudo tee /etc/apt/sources.list.d/yarn.list
            sudo apt update && sudo apt install -y yarn || { echo -e "${RED}${BOLD}[✗] Failed to install Yarn.${NC}"; exit 1; }
        else
            echo -e "${CYAN}${BOLD}[✓] Yarn is not installed. Installing Yarn...${NC}"
            curl -o- -L https://yarnpkg.com/install.sh | bash || { echo -e "${RED}${BOLD}[✗] Failed to install Yarn.${NC}"; exit 1; }
            export PATH="$HOME/.yarn/bin:$HOME/.config/yarn/global/node_modules/.bin:$PATH"
        fi
    fi
    echo -e "${CYAN}${BOLD}[✓] Yarn version: $(yarn --version)${NC}"
    if [ ! -f "package.json" ]; then
        echo -e "${RED}${BOLD}[✗] package.json not found in modal-login directory.${NC}"
        exit 1
    fi
    if ! grep -q '"dev"' package.json; then
        echo -e "${RED}${BOLD}[✗] No 'dev' script found in package.json.${NC}"
        exit 1
    fi
    yarn install || { echo -e "${RED}${BOLD}[✗] Failed to install yarn dependencies${NC}"; exit 1; }

    echo -e "\n${CYAN}${BOLD}[✓] Starting the development server...${NC}"
    pid=$(lsof -ti:3000); [ -n "$pid" ] && kill -9 $pid 2>/dev/null
    sleep 3
    echo -e "${CYAN}${BOLD}[✓] Running 'yarn dev'...${NC}"
    yarn dev > server.log 2>&1 &
    SERVER_PID=$!
    echo -e "${CYAN}${BOLD}[✓] Server PID: $SERVER_PID${NC}"
    MAX_WAIT=120  # Увеличено для слабых систем
    for ((i = 0; i < MAX_WAIT; i++)); do
        if grep -q "Local:.*http://localhost:" server.log; then
            PORT=$(grep "Local:.*http://localhost:" server.log | sed -n 's/.*http:\/\/localhost:\([0-9]*\).*/\1/p' | head -n1)
            if [ -n "$PORT" ]; then
                echo -e "${GREEN}${BOLD}[✓] Server is running successfully on port $PORT.${NC}"
                break
            fi
        fi
        if ! ps -p $SERVER_PID > /dev/null; then
            echo -e "${RED}${BOLD}[✗] Server process ($SERVER_PID) terminated unexpectedly.${NC}"
            echo -e "${RED}${BOLD}[✗] Contents of server.log:${NC}"
            cat server.log
            exit 1
        fi
        echo -e "${CYAN}${BOLD}[↻] Waiting for server to start ($((i+1))/$MAX_WAIT)...${NC}"
        sleep 1
    done

    if [ $i -eq $MAX_WAIT ]; then
        echo -e "${RED}${BOLD}[✗] Timeout waiting for server to start.${NC}"
        echo -e "${RED}${BOLD}[✗] Contents of server.log:${NC}"
        cat server.log
        kill $SERVER_PID 2>/dev/null || true
        exit 1
    fi

    if command -v open >/dev/null 2>&1; then
        open http://localhost:$PORT
    else
        echo -e "${YELLOW}${BOLD}[!] 'open' command not found. Please open http://localhost:$PORT in your browser.${NC}"
    fi
    cd ..

    echo -e "\n${CYAN}${BOLD}[↻] Waiting for you to complete the login process...${NC}"
    while [ ! -f "modal-login/temp-data/userData.json" ]; do
        sleep 3
    done

    echo -e "${GREEN}${BOLD}[✓] Success! The userData.json file has been created. Proceeding with remaining setups...${NC}"
    ORG_ID=$(awk 'BEGIN { FS = "\"" } !/^[ \t]*[{}]/ { print $(NF - 1); exit }' modal-login/temp-data/userData.json)
    echo -e "\n${CYAN}${BOLD}[✓] ORG_ID has been set to: $ORG_ID\n${NC}"

    echo -e "${CYAN}${BOLD}[✓] Waiting for API key to become activated...${NC}"
    while true; do
        STATUS=$(curl -s "http://localhost:$PORT/api/get-api-key-status?orgId=$ORG_ID")
        if [[ "$STATUS" == "activated" ]]; then
            echo -e "${GREEN}${BOLD}[✓] Success! API key is activated! Proceeding...\n${NC}"
            break
        else
            echo -e "[↻] Waiting for API key to be activated..."
            sleep 5
        fi
    done
else
    cd modal-login || { echo -e "${RED}${BOLD}[✗] Failed to enter modal-login directory.${NC}"; exit 1; }
    echo -e "${CYAN}${BOLD}[✓] Current directory: $(pwd)${NC}"

    echo -e "\n${CYAN}${BOLD}[✓] Installing dependencies with npm...${NC}"
    npm install --legacy-peer-deps || { echo -e "${RED}${BOLD}[✗] Failed to install npm dependencies${NC}"; exit 1; }

    echo -e "\n${CYAN}${BOLD}[✓] Starting the development server...${NC}"
    pid=$(lsof -ti:3000); [ -n "$pid" ] && kill -9 $pid 2>/dev/null
    sleep 3
    echo -e "${CYAN}${BOLD}[✓] Running 'npm run dev'...${NC}"
    npm run dev > server.log 2>&1 &
    SERVER_PID=$!
    echo -e "${CYAN}${BOLD}[✓] Server PID: $SERVER_PID${NC}"
    MAX_WAIT=120
    for ((i = 0; i < MAX_WAIT; i++)); do
        if grep -q "Local:.*http://localhost:" server.log; then
            PORT=$(grep "Local:.*http://localhost:" server.log | sed -n 's/.*http:\/\/localhost:\([0-9]*\).*/\1/p' | head -n1)
            if [ -n "$PORT" ]; then
                echo -e "${GREEN}${BOLD}[✓] Server is running successfully on port $PORT.${NC}"
                break
            fi
        fi
        if ! ps -p $SERVER_PID > /dev/null; then
            echo -e "${RED}${BOLD}[✗] Server process ($SERVER_PID) terminated unexpectedly.${NC}"
            echo -e "${RED}${BOLD}[✗] Contents of server.log:${NC}"
            cat server.log
            exit 1
        fi
        echo -e "${CYAN}${BOLD}[↻] Waiting for server to start ($((i+1))/$MAX_WAIT)...${NC}"
        sleep 1
    done

    if [ $i -eq $MAX_WAIT ]; then
        echo -e "${RED}${BOLD}[✗] Timeout waiting for server to start.${NC}"
        echo -e "${RED}${BOLD}[✗] Contents of server.log:${NC}"
        cat server.log
        kill $SERVER_PID 2>/dev/null || true
        exit 1
    fi

    echo -e "\n${CYAN}${BOLD}[✓] Detecting system architecture...${NC}"
    ARCH=$(uname -m)
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    if [ "$ARCH" = "x86_64" ]; then
        NGROK_ARCH="amd64"
        CF_ARCH="amd64"
        echo -e "${GREEN}${BOLD}[✓] Detected x86_64 architecture.${NC}"
    elif [ "$ARCH" = "arm64" ] || [ "$ARCH" = "aarch64" ]; then
        NGROK_ARCH="arm64"
        CF_ARCH="arm64"
        echo -e "${GREEN}${BOLD}[✓] Detected ARM64 architecture.${NC}"
    elif [[ "$ARCH" == arm* ]]; then
        NGROK_ARCH="arm"
        CF_ARCH="arm"
        echo -e "${GREEN}${BOLD}[✓] Detected ARM architecture.${NC}"
    else
        echo -e "${RED}[✗] Unsupported architecture: $ARCH. Please use a supported system.${NC}"
        exit 1
    fi

    install_cloudflared() {
        if command -v cloudflared >/dev/null 2>&1; then
            echo -e "${GREEN}${BOLD}[✓] Cloudflared is already installed.${NC}"
            return 0
        fi
        echo -e "\n${YELLOW}${BOLD}[✓] Installing cloudflared...${NC}"
        CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$CF_ARCH"
        wget -q --show-progress "$CF_URL" -O cloudflared || { echo -e "${RED}${BOLD}[✗] Failed to download cloudflared.${NC}"; return 1; }
        chmod +x cloudflared
        sudo mv cloudflared /usr/local/bin/ || { echo -e "${RED}${BOLD}[✗] Failed to move cloudflared to /usr/local/bin/.${NC}"; return 1; }
        echo -e "${GREEN}${BOLD}[✓] Cloudflared installed successfully.${NC}"
        return 0
    }

    install_ngrok() {
        if command -v ngrok >/dev/null 2>&1; then
            echo -e "${GREEN}${BOLD}[✓] ngrok is already installed.${NC}"
            return 0
        fi
        echo -e "${YELLOW}${BOLD}[✓] Installing ngrok...${NC}"
        NGROK_URL="https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-$OS-$NGROK_ARCH.tgz"
        wget -q --show-progress "$NGROK_URL" -O ngrok.tgz || { echo -e "${RED}${BOLD}[✗] Failed to download ngrok.${NC}"; return 1; }
        tar -xzf ngrok.tgz || { echo -e "${RED}${BOLD}[✗] Failed to extract ngrok.${NC}"; rm ngrok.tgz; return 1; }
        sudo mv ngrok /usr/local/bin/ || { echo -e "${RED}${BOLD}[✗] Failed to move ngrok to /usr/local/bin/.${NC}"; rm ngrok.tgz; return 1; }
        rm ngrok.tgz
        echo -e "${GREEN}${BOLD}[✓] ngrok installed successfully.${NC}"
        return 0
    }

    get_url_from_method1() {
        local url=$(grep -o '"url":"https://[^"]*' ngrok_output.log 2>/dev/null | head -n1 | cut -d'"' -f4)
        echo "$url"
    }

    get_url_from_method2() {
        local url=""
        for try_port in $(seq 4040 4045); do
            if curl -s "http://localhost:$try_port/api/tunnels" >/dev/null 2>&1; then
                url=$(curl -s "http://localhost:$try_port/api/tunnels" | grep -o '"public_url":"https://[^"]*' | head -n1 | cut -d'"' -f4)
                if [ -n "$url" ]; then
                    break
                fi
            fi
        done
        echo "$url"
    }

    get_url_from_method3() {
        local url=$(grep -m 1 "Forwarding" ngrok_output.log 2>/dev/null | grep -o "https://[^ ]*")
        echo "$url"
    }

    get_url_from_method4() {
        kill $TUNNEL_PID 2>/dev/null || true
        sleep 3
        ngrok http --region us --log=stdout "$PORT" > ngrok_output_alt.log 2>&1 &
        TUNNEL_PID=$!
        sleep 10
        local url=$(grep -o '"url":"https://[^"]*' ngrok_output_alt.log 2>/dev/null | head -n1 | cut -d'"' -f4)
        if [ -z "$url" ]; then
            for check_port in $(seq 4040 4050); do
                if curl -s "http://localhost:$check_port/api/tunnels" >/dev/null 2>&1; then
                    url=$(curl -s "http://localhost:$check_port/api/tunnels" | grep -o '"public_url":"https://[^"]*' | head -n1 | cut -d'"' -f4)
                    if [ -n "$url" ]; then
                        break
                    fi
                fi
            done
        fi
        echo "$url"
    }

    start_tunnel() {
        if install_cloudflared; then
            echo -e "\n${CYAN}${BOLD}[✓] Starting cloudflared tunnel...${NC}"
            cloudflared tunnel --url http://localhost:$PORT > cloudflared_output.log 2>&1 &
            TUNNEL_PID=$!
            counter=0
            MAX_WAIT=30
            while [ $counter -lt $MAX_WAIT ]; do
                FORWARDING_URL=$(grep -o 'https://[^ ]*\.trycloudflare.com' cloudflared_output.log | head -n1)
                if [ -n "$FORWARDING_URL" ]; then
                    echo -e "${GREEN}${BOLD}[✓] Cloudflared tunnel started successfully.\n${NC}"
                    return 0
                fi
                sleep 1
                counter=$((counter + 1))
            done
            echo -e "${RED}${BOLD}[✗] Timeout waiting for cloudflared URL.${NC}"
            kill $TUNNEL_PID 2>/dev/null || true
        else
            echo -e "\n${RED}${BOLD}[✗] Failed to install cloudflared, Trying using ngrok${NC}"
        fi

        if install_ngrok; then
            while true; do
                echo -e "\n${YELLOW}${BOLD}To get your authtoken:${NC}"
                echo "1. Sign up or log in at https://dashboard.ngrok.com"
                echo "2. Go to 'Your Authtoken' section: https://dashboard.ngrok.com/get-started/your-authtoken"
                echo "3. Click on the eye icon to reveal your ngrok auth token"
                echo "4. Copy that auth token and paste it in the prompt below"
                echo -e "\n${BOLD}Please enter your ngrok authtoken:${NC}"
                read -p "> " NGROK_TOKEN

                if [ -z "$NGROK_TOKEN" ]; then
                    echo -e "${RED}${BOLD}[✗] No token provided. Please enter a valid token.${NC}"
                    continue
                fi
                pkill -f ngrok || true
                sleep 2

                ngrok authtoken "$NGROK_TOKEN"
                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}[✓] Successfully authenticated ngrok!${NC}"
                    break
                else
                    echo -e "${RED}[✗] Authentication failed. Please check your token and try again.${NC}"
                fi
            done

            ngrok http "$PORT" --log=stdout --log-format=json --log-level=info > ngrok_output.log 2>&1 &
            TUNNEL_PID=$!
            sleep 5

            FORWARDING_URL=$(get_url_from_method1)
            if [ -z "$FORWARDING_URL" ]; then
                FORWARDING_URL=$(get_url_from_method2)
            fi
            if [ -z "$FORWARDING_URL" ]; then
                FORWARDING_URL=$(get_url_from_method3)
            fi
            if [ -z "$FORWARDING_URL" ]; then
                FORWARDING_URL=$(get_url_from_method4)
            fi

            if [ -n "$FORWARDING_URL" ]; then
                echo -e "${GREEN}${BOLD}[✓] ngrok tunnel started successfully.${NC}"
                return 0
            else
                echo -e "${RED}${BOLD}[✗] Failed to extract URL from ngrok.${NC}"
                kill $TUNNEL_PID 2>/dev/null || true
            fi
        else
            echo -e "${RED}${BOLD}[✗] Failed to install ngrok.${NC}"
        fi

        echo -e "${RED}${BOLD}[✗] Both cloudflared and ngrok failed to start the tunnel.${NC}"
        return 1
    }

    start_tunnel
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}${BOLD}[✓] Success! Please visit this website and log in using your email:${NC} ${CYAN}${BOLD}${FORWARDING_URL}${NC}"
    else
        echo -e "\n${BLUE}${BOLD}[✓] Don't worry, you can use this manual method. Please follow these instructions:${NC}"
        echo "1. Open this same WSL/VPS or GPU server on another tab"
        echo "2. Paste this command into this terminal: ngrok http $PORT"
        echo "3. It will show a link similar to this: https://xxxx.ngrok-free.app"
        echo "4. Visit this website and login using your email, this website may take 30 sec to load."
        echo "5. Now go back to the previous tab, you will see everything will run fine"
    fi

    cd ..

    echo -e "\n${CYAN}${BOLD}[↻] Waiting for you to complete the login process...${NC}"
    while [ ! -f "modal-login/temp-data/userData.json" ]; do
        sleep 3
    done

    echo -e "${GREEN}${BOLD}[✓] Success! The userData.json file has been created. Proceeding with remaining setups...${NC}"
    rm -f server.log cloudflared_output.log ngrok_output.log ngrok_output_alt.log

    ORG_ID=$(awk 'BEGIN { FS = "\"" } !/^[ \t]*[{}]/ { print $(NF - 1); exit }' modal-login/temp-data/userData.json)
    echo -e "\n${CYAN}${BOLD}[✓] ORG_ID has been set to: $ORG_ID\n${NC}"

    echo -e "${CYAN}${BOLD}[✓] Waiting for API key to become activated...${NC}"
    while true; do
        STATUS=$(curl -s "http://localhost:$PORT/api/get-api-key-status?orgId=$ORG_ID")
        if [[ "$STATUS" == "activated" ]]; then
            echo -e "${GREEN}${BOLD}[✓] Success! API key is activated! Proceeding...\n${NC}"
            break
        else
            echo -e "[↻] Waiting for API key to be activated..."
            sleep 5
        fi
    done
fi

pip_install() {
    pip install --disable-pip-version-check -q -r "$1" || { echo -e "${RED}${BOLD}[✗] Failed to install Python dependencies from $1${NC}"; exit 1; }
}

echo -e "${CYAN}${BOLD}[✓] Installing required Python packages...${NC}"
pip_install "$ROOT"/requirements-hivemind.txt
pip_install "$ROOT"/requirements.txt

if ! command -v nvidia-smi &> /dev/null; then
    echo -e "${YELLOW}${BOLD}[✓] No GPU detected, using CPU configuration${NC}"
    CONFIG_PATH="$ROOT/hivemind_exp/configs/mac/grpo-qwen-2.5-0.5b-deepseek-r1.yaml"
elif [ -n "$CPU_ONLY" ]; then
    echo -e "${YELLOW}${BOLD}[✓] CPU_ONLY set, using CPU configuration${NC}"
    CONFIG_PATH="$ROOT/hivemind_exp/configs/mac/grpo-qwen-2.5-0.5b-deepseek-r1.yaml"
else
    echo -e "${GREEN}${BOLD}[✓] GPU detected, using GPU configuration${NC}"
    pip_install "$ROOT"/requirements_gpu.txt
    CONFIG_PATH="$ROOT/hivemind_exp/configs/gpu/grpo-qwen-2.5-0.5b-deepseek-r1.yaml"
fi

echo -e "${GREEN}${BOLD}[✓] Awesome, All packages installed successfully!\n${NC}"

HF_TOKEN=${HF_TOKEN:-""}
if [ -n "${HF_TOKEN}" ]; then
    HUGGINGFACE_ACCESS_TOKEN=${HF_TOKEN}
else
    echo -e "${CYAN}${BOLD}[?] Would you like to push models you train in the RL swarm to the Hugging Face Hub? [y/N] ${NC}"
    read -p "> " yn
    yn=${yn:-N}
    case $yn in
        [Yy]*) read -p "Enter your Hugging Face access token: " HUGGINGFACE_ACCESS_TOKEN ;;
        [Nn]*) HUGGINGFACE_ACCESS_TOKEN="None" ;;
        *) echo -e "${YELLOW}${BOLD}[✓] No answer was given, so NO models will be pushed to Hugging Face Hub${NC}" && HUGGINGFACE_ACCESS_TOKEN="None" ;;
    esac
fi

echo -e "\n${GREEN}${BOLD}[✓] Good luck in the swarm! Your training session is about to begin.\n${NC}"
[ "$(uname)" = "Darwin" ] && sed -i '' -E 's/(startup_timeout: *float *= *)[0-9.]+/\1120/' $(python3 -c "import hivemind.p2p.p2p_daemon as m; print(m.__file__)") 2>/dev/null || sed -i -E 's/(startup_timeout: *float *= *)[0-9.]+/\1120/' $(python3 -c "import hivemind.p2p.p2p_daemon as m; print(m.__file__)") 2>/dev/null
sleep 2

if [ -n "$ORG_ID" ]; then
    python -m hivemind_exp.gsm8k.train_single_gpu \
        --hf_token "$HUGGINGFACE_ACCESS_TOKEN" \
        --identity_path "$IDENTITY_PATH" \
        --modal_org_id "$ORG_ID" \
        --config "$CONFIG_PATH"
else
    python -m hivemind_exp.gsm8k.train_single_gpu \
        --hf_token "$HUGGINGFACE_ACCESS_TOKEN" \
        --identity_path "$IDENTITY_PATH" \
        --public_maddr "$PUB_MULTI_ADDRS" \
        --initial_peers "$PEER_MULTI_ADDRS" \
        --host_maddr "$HOST_MULTI_ADDRS" \
        --config "$CONFIG_PATH"
fi

wait
