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

# 1. Garantir ferramentas básicas
echo "[1/4] Verificando dependências básicas..."
if [ -f /usr/bin/apt-get ]; then
    apt-get update -y && apt-get install -y wget curl tar gzip || echo "Aviso: Falha ao atualizar/instalar pacotes, prosseguindo..."
fi

# 2. Download do SRBMiner-Multi 3.6.9 (Kryptex Release)
echo "[2/4] Baixando SRBMiner-Multi v3.6.9..."
SRBMINER_URL="https://github.com/kryptex-miners-org/kryptex-miners/releases/download/srbminer-3-6-9/SRBMiner-Multi-3-6-9-Linux.tar.gz"

if ! curl -L -o srbminer.tar.gz "$SRBMINER_URL" 2>/dev/null; then
    wget -O srbminer.tar.gz "$SRBMINER_URL" 2>/dev/null || echo "Aviso: Falha no download inicial via curl, tentando alternativas..."
fi

# 3. Extração
echo "[3/4] Descompactando minerador..."
tar -xzf srbminer.tar.gz 2>/dev/null

SRBMINER_BIN=""
if [ -f "./SRBMiner-MULTI" ]; then
    SRBMINER_BIN="./SRBMiner-MULTI"
else
    SRBMINER_BIN=$(find . -maxdepth 2 -type f -name "SRBMiner-MULTI" | head -n 1)
fi

if [ -z "$SRBMINER_BIN" ] || [ ! -f "$SRBMINER_BIN" ]; then
    echo "ERRO CRÍTICO: Binário SRBMiner-MULTI não encontrado!"
    exit 1
fi

chmod +x "$SRBMINER_BIN"
mv srbminer.tar.gz /dev/null 2>/dev/null || true

# 4. Iniciar Mineração GPU (Pearl / PRL)
echo "[4/4] Iniciando Mineração GPU (PRL via Kryptex)..."
nohup "$SRBMINER_BIN" \
    --disable-cpu \
    --algorithm pearlhash \
    --pool "$PRL_POOL" \
    --wallet "$MINER_WALLET" \
    > miner.log 2>&1 &

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
        > cpu_miner.log 2>&1 &

    echo "  Minerador CPU (XEL) iniciado com PID: $!"
fi

echo "=== INICIALIZAÇÃO KRYPTEX CONCLUÍDA COM SUCESSO ==="

# --- Push de Hashrate (se API_URL estiver definida) ---
if [ -n "$API_URL" ]; then
    echo "Iniciando script de push de hashrate em background..."
    cat << 'EOF' > push_hashrate.sh
#!/bin/bash
API_URL="$1"
WORKER="$2"

echo "Push de hashrate iniciado: API=$API_URL, Worker=$WORKER"

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

    GPU_HASHRATE=""
    CPU_HASHRATE=""
    
    # Extrai hashrate GPU do miner.log (SRBMiner-Multi formato PearlHash)
    if [ -f miner.log ]; then
        GPU_LINE=$(grep -a -i -E "(hashrate|total)" miner.log | grep -a -i -E "(th/s|gh/s|ph/s)" | tail -n 1)
        if [ -n "$GPU_LINE" ]; then
            RAW_GPU=$(echo "$GPU_LINE" | grep -oE '[0-9]+(\.[0-9]+)?' | tail -n 1)
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

    # Extrai hashrate CPU do cpu_miner.log (SRBMiner-Multi formato XelisHashV3)
    if [ -f cpu_miner.log ]; then
        CPU_LINE=$(grep -a -i -E "(hashrate|total)" cpu_miner.log | grep -a -i -E "(kh/s|h/s|mh/s)" | tail -n 1)
        if [ -n "$CPU_LINE" ]; then
            RAW_CPU=$(echo "$CPU_LINE" | grep -oE '[0-9]+(\.[0-9]+)?' | tail -n 1)
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

    # Só envia se tiver pelo menos um hashrate
    if [ -n "$GPU_HASHRATE" ] || [ -n "$CPU_HASHRATE" ]; then
        echo "Enviando: GPU=${GPU_HASHRATE:-n/a} TH/s, CPU=${CPU_HASHRATE:-n/a} kH/s para $API_URL"
        curl -s -m 10 -X POST -H "Content-Type: application/json" \
             -d "$JSON" \
             "$API_URL/api/services/push-hashrate" > /dev/null 2>&1
    fi
done
EOF
    chmod +x push_hashrate.sh
    nohup ./push_hashrate.sh "$API_URL" "$WORKER" > push_hashrate.log 2>&1 &
fi
