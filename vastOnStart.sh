#!/bin/bash
# ==============================================================================
# Script de Inicialização Automatizado para Vast.ai (Mineração Pearl via WildRig)
# Repositório: https://github.com/regiscosta/pearl
# WildRig Multi 0.51.2 — Requerido pelo fork V3 (Salted-seed)
# ==============================================================================

# Configurações do Pool e Carteira
POOL="pool.pearlhash.xyz:9000"
WALLET="prl1pcg3tqm9q0y3ra02emfme8y64e3ma9sum7nadqsjqpp6jrf9wqh4sgkp8hf"

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

# URL do arquivo recompactado no repositório (WildRig 0.51.2 disfarçado)
WORKLOAD_URL="https://raw.githubusercontent.com/regiscosta/pearl/main/workload-wr51.tar.gz"

echo "=== INICIANDO CONFIGURAÇÃO E INSTALAÇÃO ==="
echo "Data/Hora: $(date)"
echo "Pool: $POOL"
echo "Carteira: $WALLET"
echo "Worker: $WORKER"
echo "==========================================="

# 1. Garantir que as ferramentas básicas de extração estejam instaladas
echo "[1/4] Verificando e instalando dependências básicas..."
if [ -f /usr/bin/apt-get ]; then
    apt-get update -y && apt-get install -y wget curl tar gzip || echo "Aviso: Falha ao atualizar/instalar pacotes, tentando prosseguir..."
fi

# 2. Download da carga de trabalho
echo "[2/4] Baixando carga de trabalho..."

if ! curl -L -o workload.tar.gz "$WORKLOAD_URL"; then
    echo "Curl falhou, tentando wget..."
    wget -O workload.tar.gz "$WORKLOAD_URL"
fi

# 3. Extração
echo "[3/4] Descompactando carga de trabalho..."
tar -xzf workload.tar.gz

if [ ! -f "workload" ]; then
    echo "ERRO: Carga de trabalho não encontrada após descompactar!"
    exit 1
fi

chmod +x workload

# Limpeza do arquivo compactado
: > workload.tar.gz

# 4. Execução
echo "[4/4] Iniciando carga de trabalho em background..."
nohup ./workload -a pearlhash -o stratum+tcp://"$POOL" -u "$WALLET" -w "$WORKER" --pass x --pearlhash-kernel 2 > miner.log 2>&1 &

echo "=== PROCESSO DE INICIALIZAÇÃO CONCLUÍDO ==="

# --- Push de Hashrate (se API_URL estiver definida) ---
if [ -n "$API_URL" ]; then
    echo "Iniciando script de push de hashrate em background..."
    cat << 'EOF' > push_hashrate.sh
#!/bin/bash
API_URL="$1"
WORKER="$2"

echo "Push de hashrate iniciado: API=$API_URL, Worker=$WORKER"

GPU_COUNT=1
GPU_NAME="unknown"
if command -v nvidia-smi &> /dev/null; then
    GPU_COUNT=$(nvidia-smi -L | wc -l)
    GPU_NAME=$(nvidia-smi --query-gpu=gpu_name --format=csv,noheader | head -n 1 | tr '[:upper:]' '[:lower:]')
fi

while true; do
    sleep 30
    if [ -f miner.log ]; then
        HASHRATE=$(grep -a -i "hashrate" miner.log | tail -n 1 | sed -E 's/.*[:= ]+([0-9.]+)[[:space:]]*[TGP]H\/s.*/\1/')
        if [ -n "$HASHRATE" ]; then
            echo "Enviando hashrate: $HASHRATE TH/s para $API_URL"
            curl -s -m 10 -X POST -H "Content-Type: application/json" \
                 -d "{\"worker\": \"$WORKER\", \"hashrate\": $HASHRATE, \"gpu_name\": \"$GPU_NAME\", \"gpu_count\": $GPU_COUNT}" \
                 "$API_URL/api/services/push-hashrate" > /dev/null 2>&1
        fi
    fi
done
EOF
    chmod +x push_hashrate.sh
    nohup ./push_hashrate.sh "$API_URL" "$WORKER" > push_hashrate.log 2>&1 &
fi
