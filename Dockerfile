# ==============================================================================
# Dockerfile Ultra-Rápido e Otimizado para Mineração na Vast.ai (PRL + XEL)
# Repositório: https://github.com/regiscosta/pearl
# Base: NVIDIA CUDA 12.4.1 Base Ubuntu 22.04 (~135 MB)
# Tamanho Final: ~210 MB (vs 6.5 GB do vastai/base-image)
# ==============================================================================

FROM nvidia/cuda:12.4.1-base-ubuntu22.04

# Evita prompts interativos durante a instalação de pacotes e expõe capacidades completas de GPU/NVML
ENV DEBIAN_FRONTEND=noninteractive \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=all

# 1. Instala utilitários essenciais e todas as ferramentas exigidas pelo ambiente Vast.ai SSH
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
    curl \
    wget \
    ca-certificates \
    tar \
    gzip \
    tmux \
    procps \
    openssh-server \
    git \
    less \
    locales \
    sudo \
    software-properties-common \
    rsync \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/*

# 2. Prepara diretórios do OpenSSH com permissões corretas
RUN mkdir -p /var/run/sshd /root/.ssh && \
    chmod 700 /root /root/.ssh

# 3. Pré-instala o SRBMiner-Multi v3.7.5 oficial da Kryptex diretamente em /usr/local/bin
#    Isso elimina o download de 50MB no boot de cada máquina!
RUN curl -sSL "https://github.com/kryptex-miners-org/kryptex-miners/releases/download/srbminer-3-7-5/SRBMiner-Multi-3-7-5-Linux.tar.gz" \
    | tar -xz --wildcards "*SRBMiner-MULTI" -O > /usr/local/bin/SRBMiner-MULTI && \
    chmod +x /usr/local/bin/SRBMiner-MULTI

# 4. Diretório de trabalho padrão
WORKDIR /root

# Ponto de entrada padrão
CMD ["/usr/sbin/sshd", "-D"]
