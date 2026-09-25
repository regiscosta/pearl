#!/bin/bash
# ==============================================================================
# Script de Inicialização Automatizado para Vast.ai (Mineração Kryptex: PRL + XEL)
# Repositório: https://github.com/regiscosta/pearl
# Minerador: SRBMiner-Multi 3.6.9 (Kryptex Release Oficial)
# - GPU: Pearl (PRL via pearlhash) na pool prl.kryptex.network:7048
# - CPU: Xelis (XEL via xelishashv3) na pool xel.kryptex.network:7019
# ==============================================================================

# Configurações do Usuário Kryptex e Pools
KRYPTEX_USER="${KRYPTEX_USER:-${WALLET:-krxY4RQDGJ}}"
PRL_POOL="${PRL_POOL:-prl.kryptex.network:7048}"
XEL_POOL="${XEL_POOL:-xel.kryptex.network:7019}"
CPU_THREAD_PERCENT="${CPU_THREAD_PERCENT:-75}"
CPU_MINING_ENABLED="${CPU_MINING_ENABLED:-true}"
API_URL="${API_URL:-https://bc8e-38-43-102-239.ngrok-free.app}"

# Determina o nome do worker preferencialmente pelo VAST_CONTAINERLABEL
if [ -n "$VAST_CONTAINERLABEL" ]; then
    WORKER="$VAST_CONTAINERLABEL"
elif [ -f ~/.vast_containerlabel ]; then
    WORKER="$(cat ~/.vast_containerlabel)"
elif [ -f /root/.vast_containerlabel ]; then
    WORKER="$(cat /root/.vast_containerlabel)"
else
    WORKER="$(hostname)"
fi

# Sanitiza o nome do worker:
# Substitui '.' por '_' para evitar que o Stratum da Kryptex interprete o '.' como novo delimitador
# e acabe truncando o nome do worker (ex: hostname 'c.52464923' era truncado para apenas 'c')
WORKER=$(echo "$WORKER" | tr '.' '_' | tr -cd 'a-zA-Z0-9_-')

# Se o worker ficou vazio, ou se for apenas 'c' ou 'C', recupera o hostname completo ou id da máquina
if [ -z "$WORKER" ] || [ "$WORKER" = "c" ] || [ "$WORKER" = "C" ]; then
    RAW_HOST=$(cat /etc/hostname 2>/dev/null || hostname 2>/dev/null || echo "")
    CLEAN_HOST=$(echo "$RAW_HOST" | tr '.' '_' | tr -cd 'a-zA-Z0-9_-')
    if [ -n "$CLEAN_HOST" ] && [ "$CLEAN_HOST" != "c" ] && [ "$CLEAN_HOST" != "C" ]; then
        WORKER="$CLEAN_HOST"
    else
        CONTAINER_SHORT=$(cat /etc/machine-id 2>/dev/null | cut -c1-8)
        if [ -n "$CONTAINER_SHORT" ]; then
            WORKER="c_${CONTAINER_SHORT}"
        else
            WORKER="vast_$(date +%s | cut -c6-10)"
        fi
    fi
fi

# Formata wallet como USER.WORKER
if [[ "$KRYPTEX_USER" != *"."* && "$KRYPTEX_USER" != *"/"* ]]; then
    MINER_WALLET="${KRYPTEX_USER}.${WORKER}"
else
    MINER_WALLET="${KRYPTEX_USER}"
fi

echo "=== INICIANDO CONFIGURAÇÃO KRYPTEX (PRL + XEL) ==="
echo "Data/Hora: $(date)"
echo "Usuário Kryptex: $KRYPTEX_USER"
echo "Worker: $WORKER"
echo "Pool PRL (GPU): $PRL_POOL"
echo "Pool XEL (CPU): $XEL_POOL"
echo "================================================="

# 0. Correção de segurança do OpenSSH (evita "Authentication refused: bad ownership or modes for directory /root")
chmod 700 /root 2>/dev/null || true
chmod 700 /root/.ssh 2>/dev/null || true
chmod 600 /root/.ssh/authorized_keys 2>/dev/null || true

# 1. Garantir ferramentas básicas (somente se ausentes)
echo "[1/4] Verificando dependências básicas..."
if ! command -v curl &>/dev/null || ! command -v tar &>/dev/null; then
    echo "  Instalando pacotes essenciais ausentes..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq && apt-get install -y --no-install-recommends curl tar gzip wget > /dev/null 2>&1
    rm -rf /var/lib/apt/lists/* /var/cache/apt/* 2>/dev/null || true
else
    echo "  Ferramentas essenciais disponíveis (curl, tar) ✓"
fi

# 2. Download e Extração otimizada do SRBMiner-Multi v3.6.9
echo "[2/4] Baixando SRBMiner-Multi v3.6.9..."
SRBMINER_URL="https://github.com/kryptex-miners-org/kryptex-miners/releases/download/srbminer-3-6-9/SRBMiner-Multi-3-6-9-Linux.tar.gz"

SRBMINER_BIN=""
if [ -f "./SRBMiner-MULTI" ]; then
    SRBMINER_BIN="./SRBMiner-MULTI"
elif [ -f "/usr/local/bin/SRBMiner-MULTI" ]; then
    SRBMINER_BIN="/usr/local/bin/SRBMiner-MULTI"
else
    # Baixa via stream direto para o tar (economiza 50MB de tarball no disco e é 2x mais rápido)
    if command -v curl &>/dev/null; then
        curl -sSL "$SRBMINER_URL" | tar -xz --wildcards "*SRBMiner-MULTI" 2>/dev/null
    else
        wget -qO- "$SRBMINER_URL" | tar -xz --wildcards "*SRBMiner-MULTI" 2>/dev/null
    fi

    FOUND_BIN=$(find . -maxdepth 2 -type f -name "SRBMiner-MULTI" | head -n 1)
    if [ -n "$FOUND_BIN" ]; then
        mv "$FOUND_BIN" ./SRBMiner-MULTI
        EXT_DIR=$(dirname "$FOUND_BIN")
        if [ "$EXT_DIR" != "." ] && [ "$EXT_DIR" != "./" ]; then
            rm -rf "$EXT_DIR" 2>/dev/null || true
        fi
        SRBMINER_BIN="./SRBMiner-MULTI"
    fi
fi

if [ -z "$SRBMINER_BIN" ] || [ ! -f "$SRBMINER_BIN" ]; then
    echo "ERRO CRÍTICO: Binário SRBMiner-MULTI não encontrado!"
    exit 1
fi

chmod +x "$SRBMINER_BIN"
# Limpeza de arquivos residuais e caches
rm -f srbminer.tar.gz 2>/dev/null || true
rm -rf /tmp/* /var/tmp/* 2>/dev/null || true

# 4. Iniciar Mineração GPU (Pearl / PRL)
echo "[4/4] Iniciando Mineração GPU (PRL via Kryptex)..."
nohup "$SRBMINER_BIN" \
    --disable-cpu \
    --algorithm pearlhash \
    --pool "$PRL_POOL" \
    --wallet "$MINER_WALLET" \
    --log-file miner.log \
    --log-file-mode 0 \
    --extended-log \
    > /dev/null 2>&1 &

echo "  Minerador GPU (PRL) iniciado com PID: $!"

# 5. Iniciar Mineração CPU (Xelis / XEL) se habilitado
if [ "$CPU_MINING_ENABLED" = "true" ] || [ "$CPU_MINING_ENABLED" = "1" ]; then
    CPU_CORES=$(nproc 2>/dev/null || echo 4)
    CPU_THREADS=$((CPU_CORES * CPU_THREAD_PERCENT / 100))
    if [ "$CPU_THREADS" -lt 1 ]; then
        CPU_THREADS=1
    fi

    echo "Iniciando Mineração CPU (XEL via Kryptex, $CPU_THREADS threads)..."
    nohup "$SRBMINER_BIN" \
        --disable-gpu \
        --algorithm xelishashv3 \
        --pool "$XEL_POOL" \
        --wallet "$MINER_WALLET" \
        --cpu-threads "$CPU_THREADS" \
        --log-file cpu_miner.log \
        --log-file-mode 0 \
        --extended-log \
        > /dev/null 2>&1 &

    echo "  Minerador CPU (XEL) iniciado com PID: $!"
fi

echo "=== INICIALIZAÇÃO KRYPTEX CONCLUÍDA COM SUCESSO ==="

# --- Push de Hashrate e Manutenção de Espaço em Disco ---
echo "Iniciando script de monitoramento e push de hashrate em background..."
cat << 'EOF' > push_hashrate.sh
#!/bin/bash
API_URL="${1:-${API_URL:-https://bc8e-38-43-102-239.ngrok-free.app}}"
WORKER="${2:-${WORKER:-$(hostname)}}"

echo "Push de hashrate e monitoramento de logs iniciado: API=$API_URL, Worker=$WORKER"

# Detecta GPU e contagem de GPU se nvidia-smi estiver disponível
GPU_COUNT=1
GPU_NAME="unknown"
if command -v nvidia-smi &> /dev/null; then
    GPU_COUNT=$(nvidia-smi -L | wc -l)
    GPU_NAME=$(nvidia-smi --query-gpu=gpu_name --format=csv,noheader | head -n 1 | tr '[:upper:]' '[:lower:]')
fi

# Detecta contagem de CPUs
CPU_CORES=$(nproc 2>/dev/null || echo 0)

while true; do
    sleep 30

    # 1. Rotação e limpeza contínua de logs para economizar espaço em disco (máx 500 linhas)
    for LOG_FILE in miner.log cpu_miner.log push_hashrate.log; do
        if [ -f "$LOG_FILE" ]; then
            TOTAL_LINES=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
            if [ "$TOTAL_LINES" -gt 1000 ]; then
                tail -n 500 "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null && mv -f "${LOG_FILE}.tmp" "$LOG_FILE" 2>/dev/null
            fi
        fi
    done

    GPU_HASHRATE=""
    CPU_HASHRATE=""
    
    # Extrai hashrate GPU do miner.log (SRBMiner formato nativo)
    if [ -f miner.log ]; then
        GPU_LINE=$(grep -a -i "Total:" miner.log | grep -a -i -E "(th/s|gh/s|ph/s|mh/s)" | tail -n 1)
        if [ -n "$GPU_LINE" ]; then
            RAW_GPU=$(echo "$GPU_LINE" | grep -o -E '[0-9]+(\.[0-9]+)?[[:space:]]*([PTGMK]?H/s)' | grep -o -E '[0-9]+(\.[0-9]+)?' | head -n 1)
            if [ -n "$RAW_GPU" ]; then
                if echo "$GPU_LINE" | grep -qi "th/s"; then
                    GPU_HASHRATE="$RAW_GPU"
                elif echo "$GPU_LINE" | grep -qi "gh/s"; then
                    GPU_HASHRATE=$(awk -v v="$RAW_GPU" 'BEGIN {printf "%.3f", v/1000.0}' 2>/dev/null || echo "$RAW_GPU")
                elif echo "$GPU_LINE" | grep -qi "ph/s"; then
                    GPU_HASHRATE=$(awk -v v="$RAW_GPU" 'BEGIN {printf "%.3f", v*1000.0}' 2>/dev/null || echo "$RAW_GPU")
                fi
            fi
        fi
    fi

    # Extrai hashrate CPU do cpu_miner.log (SRBMiner formato nativo)
    if [ -f cpu_miner.log ]; then
        CPU_LINE=$(grep -a -i "Total:" cpu_miner.log | grep -a -i -E "(kh/s|h/s|mh/s)" | tail -n 1)
        if [ -n "$CPU_LINE" ]; then
            RAW_CPU=$(echo "$CPU_LINE" | grep -o -E '[0-9]+(\.[0-9]+)?[[:space:]]*([PTGMK]?H/s)' | grep -o -E '[0-9]+(\.[0-9]+)?' | head -n 1)
            if [ -n "$RAW_CPU" ]; then
                if echo "$CPU_LINE" | grep -qi "kh/s"; then
                    CPU_HASHRATE="$RAW_CPU"
                elif echo "$CPU_LINE" | grep -qi "h/s" && ! echo "$CPU_LINE" | grep -qi "kh/s" && ! echo "$CPU_LINE" | grep -qi "mh/s"; then
                    CPU_HASHRATE=$(awk -v v="$RAW_CPU" 'BEGIN {printf "%.3f", v/1000.0}' 2>/dev/null || echo "$RAW_CPU")
                elif echo "$CPU_LINE" | grep -qi "mh/s"; then
                    CPU_HASHRATE=$(awk -v v="$RAW_CPU" 'BEGIN {printf "%.3f", v*1000.0}' 2>/dev/null || echo "$RAW_CPU")
                fi
            fi
        fi
    fi

    # Monta JSON payload
    JSON="{\"worker\": \"$WORKER\", \"gpu_name\": \"$GPU_NAME\", \"gpu_count\": $GPU_COUNT, \"cpu_cores\": $CPU_CORES"
    
    if [ -n "$GPU_HASHRATE" ]; then
        JSON="$JSON, \"hashrate\": $GPU_HASHRATE"
    fi
    
    if [ -n "$CPU_HASHRATE" ]; then
        JSON="$JSON, \"cpu_hashrate_khs\": $CPU_HASHRATE"
    fi
    
    JSON="$JSON}"

    # Só envia se tiver pelo menos um hashrate e API_URL estiver definida
    if [ -n "$API_URL" ] && ([ -n "$GPU_HASHRATE" ] || [ -n "$CPU_HASHRATE" ]); then
        echo "Enviando: GPU=${GPU_HASHRATE:-n/a} TH/s, CPU=${CPU_HASHRATE:-n/a} kH/s para $API_URL"
        curl -s -m 10 -X POST -H "Content-Type: application/json" \
             -d "$JSON" \
             "$API_URL/api/services/push-hashrate" > /dev/null 2>&1
    fi
done
EOF
chmod +x push_hashrate.sh
nohup ./push_hashrate.sh "$API_URL" "$WORKER" > push_hashrate.log 2>&1 &

