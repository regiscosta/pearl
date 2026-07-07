#!/bin/bash
# ==============================================================================
# Script de Inicialização Automatizado para Vast.ai (Minerador Pearl)
# Repositório: https://github.com/regiscosta/pearl
# ==============================================================================

# ------------------------------------------------------------------------------
# Configurações do Minerador (Altere conforme necessário)
# ------------------------------------------------------------------------------
# Escolha do minerador: "pearl" ou "wildrig" (WildRig Multi é planejado como TODO)
MINER_TYPE="pearl"

# Configurações do Pool e Carteira
POOL="pool.pearlhash.xyz:9000"
WALLET="prl1pcg3tqm9q0y3ra02emfme8y64e3ma9sum7nadqsjqpp6jrf9wqh4sgkp8hf"
WORKER="$(hostname)"

# URLs dos arquivos
PEARL_MINER_URL="https://raw.githubusercontent.com/regiscosta/pearl/main/workload-v12.tar.gz"
WILDRIG_VERSION="0.49.2"

echo "=== INICIANDO CONFIGURAÇÃO E INSTALAÇÃO DO MINERADOR ==="
echo "Data/Hora: $(date)"
echo "Minerador Ativo: $MINER_TYPE"
echo "Pool: $POOL"
echo "Carteira: $WALLET"
echo "Worker: $WORKER"
echo "========================================================"

# 1. Garantir que as ferramentas básicas de extração estejam instaladas
echo "[1/4] Verificando e instalando dependências básicas..."
if [ -f /usr/bin/apt-get ]; then
    apt-get update -y && apt-get install -y wget curl tar xz-utils gzip || echo "Aviso: Falha ao atualizar/instalar pacotes, tentando prosseguir..."
fi

# 2. Processo de Download e Extração
if [ "$MINER_TYPE" = "pearl" ]; then
    echo "[2/4] Baixando minerador Pearl compactado (workload-v12.tar.gz)..."
    
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

    if [ ! -f "pearl-miner" ]; then
        echo "ERRO: Executável 'pearl-miner' não encontrado após descompactar!"
        exit 1
    fi

    chmod +x pearl-miner

    echo "[4/4] Iniciando o pearl-miner em background..."
    nohup ./pearl-miner --host "$POOL" --worker "$WORKER" --user "$WALLET" > miner.log 2>&1 &

# ------------------------------------------------------------------------------
# TODO: Integração WildRig Multi (Descomente ou altere MINER_TYPE="wildrig" futuramente)
# ------------------------------------------------------------------------------
elif [ "$MINER_TYPE" = "wildrig" ]; then
    echo "[2/4] Baixando WildRig Multi v${WILDRIG_VERSION}..."
    rm -rf wildrig-multi-linux-* wildrig.tar.xz wildrig-multi
    
    WILDRIG_URL="https://github.com/andru-kun/wildrig-multi/releases/download/v${WILDRIG_VERSION}/wildrig-multi-linux-${WILDRIG_VERSION}.tar.xz"
    if ! curl -L -o wildrig.tar.xz "$WILDRIG_URL"; then
        wget -O wildrig.tar.xz "$WILDRIG_URL"
    fi

    echo "[3/4] Descompactando WildRig Multi..."
    tar -xvf wildrig.tar.xz

    if [ ! -f "wildrig-multi" ]; then
        echo "ERRO: Executável 'wildrig-multi' não encontrado!"
        exit 1
    fi

    chmod +x wildrig-multi

    echo "[4/4] Iniciando WildRig Multi (pearlhash) em background..."
    # Ajustado com as opções recomendadas para o algoritmo pearlhash
    nohup ./wildrig-multi -a pearlhash -o stratum+tcp://"$POOL" -u "$WALLET" -w "$WORKER" --pass x --pearlhash-kernel 2 > miner.log 2>&1 &
else
    echo "ERRO: Tipo de minerador desconhecido: $MINER_TYPE"
    exit 1
fi

echo "=== PROCESSO DE INICIALIZAÇÃO CONCLUÍDO ==="
echo "Você pode verificar os logs de execução do minerador usando: tail -f miner.log"
