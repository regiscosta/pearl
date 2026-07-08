#!/bin/bash
# ==============================================================================
# Script de Inicialização Automatizado para Vast.ai (Minerador Pearl)
# Repositório: https://github.com/regiscosta/pearl
# ==============================================================================

# Captura o modo passado por parâmetro (padrão: "default")
# "default" -> inicia o pearl-miner
# "fallback" -> inicia o wildrig-multi (plano de fallback)
MODE="${1:-default}"

# Configurações do Pool e Carteira
POOL="pool.pearlhash.xyz:9000"
WALLET="prl1pcg3tqm9q0y3ra02emfme8y64e3ma9sum7nadqsjqpp6jrf9wqh4sgkp8hf"

# Determina o nome do worker preferencialmente pelo VAST_CONTAINERLABEL
if [ -f ~/.vast_containerlabel ]; then
    WORKER="$(cat ~/.vast_containerlabel)"
elif [ -f /root/.vast_containerlabel ]; then
    WORKER="$(cat /root/.vast_containerlabel)"
else
    WORKER="$(hostname)"
fi

# URLs dos arquivos
PEARL_MINER_URL="https://raw.githubusercontent.com/regiscosta/pearl/main/workload-v12.tar.gz"
WILDRIG_VERSION="0.49.2"

# Mapeia o modo para o tipo de minerador correspondente
if [ "$MODE" = "fallback" ]; then
    MINER_TYPE="wildrig"
else
    MINER_TYPE="pearl"
fi

echo "=== INICIANDO CONFIGURAÇÃO E INSTALAÇÃO ==="
echo "Data/Hora: $(date)"
echo "Modo: $MODE ($MINER_TYPE)"
echo "Pool: $POOL"
echo "Carteira: $WALLET"
echo "Worker: $WORKER"
echo "==========================================="

# 1. Garantir que as ferramentas básicas de extração estejam instaladas
echo "[1/4] Verificando e instalando dependências básicas..."
if [ -f /usr/bin/apt-get ]; then
    apt-get update -y && apt-get install -y wget curl tar xz-utils gzip || echo "Aviso: Falha ao atualizar/instalar pacotes, tentando prosseguir..."
fi

# 2. Processo de Download e Extração
if [ "$MINER_TYPE" = "pearl" ]; then
    echo "[2/4] Preparando carga de trabalho padrão..."
    
    # Limpeza de arquivos antigos se existirem
    rm -rf pearl-miner pearl-miner-v12 workload-v12.tar.gz
    
    # Tenta baixar com curl e falha para wget
    if ! curl -L -o workload-v12.tar.gz "$PEARL_MINER_URL"; then
        echo "Curl falhou, tentando wget..."
        wget -O workload-v12.tar.gz "$PEARL_MINER_URL"
    fi

    echo "[3/4] Descompactando workload-v12.tar.gz..."
    tar -xzvf workload-v12.tar.gz

    # Tratar nome do executável (renomear se necessário para consistência)
    if [ -f "pearl-miner-v12" ]; then
        mv pearl-miner-v12 pearl-miner
    elif [ -f "workload" ]; then
        mv workload pearl-miner
    fi

    # Remover arquivo compactado para economizar espaço em disco
    rm -f workload-v12.tar.gz

    if [ ! -f "pearl-miner" ]; then
        echo "ERRO: Carga de trabalho padrão não encontrada após descompactar!"
        exit 1
    fi

    chmod +x pearl-miner

    echo "[4/4] Iniciando carga de trabalho em background..."
    nohup ./pearl-miner --host "$POOL" --worker "$WORKER" --user "$WALLET" > miner.log 2>&1 &

# ------------------------------------------------------------------------------
# Módulo de Fallback (WildRig Multi)
# ------------------------------------------------------------------------------
elif [ "$MINER_TYPE" = "wildrig" ]; then
    echo "[2/4] Preparando carga de trabalho alternativa..."
    rm -rf wildrig-multi-linux-* wildrig.tar.gz wildrig-multi
    
    WILDRIG_URL="https://github.com/andru-kun/wildrig-multi/releases/download/${WILDRIG_VERSION}/wildrig-multi-linux-${WILDRIG_VERSION}.tar.gz"
    if ! curl -L -o wildrig.tar.gz "$WILDRIG_URL"; then
        wget -O wildrig.tar.gz "$WILDRIG_URL"
    fi

    echo "[3/4] Descompactando carga de trabalho alternativa..."
    tar -xzvf wildrig.tar.gz

    if [ ! -f "wildrig-multi" ]; then
        echo "ERRO: Carga alternativa não encontrada!"
        exit 1
    fi

    chmod +x wildrig-multi

    # Limpeza de arquivos compactados e templates desnecessários da release
    rm -f wildrig.tar.gz mine_*.sh mine_*.bat config.json README.md

    echo "[4/4] Iniciando carga alternativa em background..."
    # Ajustado com as opções recomendadas para o algoritmo pearlhash
    nohup ./wildrig-multi -a pearlhash -o stratum+tcp://"$POOL" -u "$WALLET" -w "$WORKER" --pass x --pearlhash-kernel 2 > miner.log 2>&1 &
else
    echo "ERRO: Tipo de minerador desconhecido: $MINER_TYPE"
    exit 1
fi

echo "=== PROCESSO DE INICIALIZAÇÃO CONCLUÍDO ==="

if [ -n "$API_URL" ]; then
    echo "Iniciando script de push de hashrate em background..."
    # Cria um script temporário para o loop e o executa em segundo plano
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

while true; do
    sleep 30
    
    # Extrai hashrate do miner.log
    if [ -f miner.log ]; then
        # Tenta extrair hashrate do formato pearl-miner: "Hashrate Total = 114.35 TH/s"
        HASHRATE=$(grep -a "Hashrate Total" miner.log | tail -n 1 | sed -E 's/.*Hashrate Total\s*=\s*([0-9.]+).*/\1/')
        
        # Se falhar, tenta formato alternativo (WildRig): "hashrate: 114.35 TH/s"
        if [ -z "$HASHRATE" ]; then
            HASHRATE=$(grep -a -i "hashrate" miner.log | tail -n 1 | sed -E 's/.*[:= ]+([0-9.]+)[[:space:]]*[TGP]H\/s.*/\1/')
        fi
        
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
