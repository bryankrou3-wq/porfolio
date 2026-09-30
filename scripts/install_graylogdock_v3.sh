#!/usr/bin/env bash
# ============================================================
#  GRAYLOG FULL STACK - Installation automatisée
#  Stack : Graylog 7.1 + MongoDB 8.0 + OpenSearch 2.19
#  Auteur : Script pour Ubuntu 22.04 LTS
#  Usage  : sudo ./install_graylogdock.sh [IP1_OPTIONNELLE] [IP2_OPTIONNELLE]
# ============================================================

set -euo pipefail

# ─── COULEURS ────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ─── CONFIGURATION ───────────────────────────────────────────
GRAYLOG_VERSION="7.1.3"
MONGODB_VERSION="8.0"
OPENSEARCH_VERSION="2.19.0"

GRAYLOG_PORT="9000"
ADMIN_PASSWORD="admin123"

INSTALL_DIR="/opt/graylog"
DATA_DIR="/opt/graylog/data"

# IPs seront définies par detect_ip()
GRAYLOG_IP=""       # IP principale (1ère carte réseau)
GRAYLOG_IP2=""      # IP secondaire (2ème carte réseau, si présente)
ALL_IPS=()          # Tableau de toutes les IPs détectées

# ─── FONCTIONS UTILITAIRES ───────────────────────────────────
log_info()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
log_ok()      { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
log_section() {
    echo -e "\n${CYAN}══════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
}

# ─── DÉTECTION AUTOMATIQUE DES IPs (support multi-cartes réseau) ──────────
# Priorité : arguments CLI > toutes les cartes réseau non-loopback/non-docker
# Usage : sudo ./script.sh [IP1] [IP2]
detect_ip() {
    # Si des IPs sont passées en argument : on les utilise directement
    if [[ -n "${1:-}" ]]; then
        GRAYLOG_IP="$1"
        ALL_IPS+=("$1")
        log_ok "IP principale fournie en argument : $GRAYLOG_IP"
        if [[ -n "${2:-}" ]]; then
            GRAYLOG_IP2="$2"
            ALL_IPS+=("$2")
            log_ok "IP secondaire fournie en argument : $GRAYLOG_IP2"
        fi
        return
    fi

    log_info "Détection automatique des adresses IP (toutes les cartes réseau)..."

    # Parcourt TOUTES les interfaces non-loopback, non-docker, non-veth
    while IFS= read -r iface; do
        ip_addr=$(ip -4 addr show "$iface" 2>/dev/null \
            | awk '/inet / {gsub(/\/.*/, "", $2); print $2; exit}')
        if [[ -n "$ip_addr" ]]; then
            ALL_IPS+=("$ip_addr")
            log_ok "Interface '$iface' détectée → IP : $ip_addr"
        fi
    done < <(ip link show \
        | awk -F': ' '/^[0-9]+:/ {print $2}' \
        | grep -vE '^(lo|docker|veth|br-|virbr)')

    # Fallback : IP via la route par défaut
    if [[ ${#ALL_IPS[@]} -eq 0 ]]; then
        FALLBACK_IP=$(ip route get 8.8.8.8 2>/dev/null \
            | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
        if [[ -n "$FALLBACK_IP" ]]; then
            ALL_IPS+=("$FALLBACK_IP")
            log_warn "Fallback route par défaut → IP : $FALLBACK_IP"
        fi
    fi

    if [[ ${#ALL_IPS[@]} -eq 0 ]]; then
        log_error "Impossible de détecter une IP. Relancez avec : sudo $0 <IP1> [IP2]"
    fi

    # IP principale = première détectée
    GRAYLOG_IP="${ALL_IPS[0]}"

    # IP secondaire = deuxième détectée (si présente)
    if [[ ${#ALL_IPS[@]} -ge 2 ]]; then
        GRAYLOG_IP2="${ALL_IPS[1]}"
        log_info "Deux cartes réseau détectées → IP1: $GRAYLOG_IP | IP2: $GRAYLOG_IP2"
        log_info "Graylog écoutera sur TOUTES les interfaces (0.0.0.0)"
    else
        log_info "Une seule carte réseau → IP : $GRAYLOG_IP"
    fi
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Ce script doit être exécuté en tant que root (sudo ./install_graylogdock.sh)"
    fi
}

check_ubuntu() {
    log_info "Vérification du système d'exploitation..."
    if ! grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
        log_error "Ce script est conçu pour Ubuntu. OS détecté non compatible."
    fi
    OS_VERSION=$(grep VERSION_ID /etc/os-release | cut -d'"' -f2)
    log_ok "Ubuntu $OS_VERSION détecté"
}

check_architecture() {
    log_info "Vérification de l'architecture matérielle..."
    ARCH=$(uname -m)
    if [[ "$ARCH" != "x86_64" ]]; then
        log_error "Architecture non supportée : $ARCH. Seul x86_64 est supporté."
    fi
    log_ok "Architecture $ARCH compatible"
}

check_ram() {
    log_info "Vérification de la RAM disponible..."
    TOTAL_RAM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
    log_info "RAM totale détectée : ${TOTAL_RAM_MB} Mo"
    if [[ "$TOTAL_RAM_MB" -lt 3072 ]]; then
        log_warn "RAM faible (${TOTAL_RAM_MB} Mo). Graylog recommande 4 Go minimum."
        log_warn "Les heap sizes seront réduits automatiquement."
    else
        log_ok "RAM suffisante (${TOTAL_RAM_MB} Mo)"
    fi
}

# ─── CALCUL DYNAMIQUE DES HEAP SIZES ─────────────────────────
compute_heap_sizes() {
    TOTAL_RAM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)

    if [[ "$TOTAL_RAM_MB" -ge 8192 ]]; then
        OPENSEARCH_HEAP="2g"
        GRAYLOG_HEAP="2g"
    elif [[ "$TOTAL_RAM_MB" -ge 4096 ]]; then
        OPENSEARCH_HEAP="1g"
        GRAYLOG_HEAP="1g"
    else
        OPENSEARCH_HEAP="512m"
        GRAYLOG_HEAP="512m"
    fi

    log_info "Heap OpenSearch : $OPENSEARCH_HEAP | Heap Graylog : $GRAYLOG_HEAP"
}

# ─── SECTION 1 : MISE À JOUR DU SYSTÈME ──────────────────────
install_system_deps() {
    log_section "MISE À JOUR DU SYSTÈME & DÉPENDANCES"

    log_info "Mise à jour de la liste des paquets..."
    apt-get update -y

    log_info "Mise à niveau des paquets installés..."
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

    log_info "Installation des dépendances essentielles..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        apt-transport-https \
        software-properties-common \
        pwgen \
        openssl \
        ufw \
        net-tools \
        wget \
        git

    log_ok "Dépendances système installées"
}

# ─── SECTION 2 : INSTALLATION DOCKER ─────────────────────────
install_docker() {
    log_section "INSTALLATION DE DOCKER"

    if command -v docker &>/dev/null; then
        DOCKER_VER=$(docker --version | awk '{print $3}' | tr -d ',')
        log_ok "Docker déjà installé (v$DOCKER_VER) — vérification de Docker Compose..."
    else
        log_info "Ajout du dépôt officiel Docker..."
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
            | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg

        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
          https://download.docker.com/linux/ubuntu \
          $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
          | tee /etc/apt/sources.list.d/docker.list > /dev/null

        apt-get update -y

        log_info "Installation de Docker Engine..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y \
            docker-ce \
            docker-ce-cli \
            containerd.io \
            docker-buildx-plugin \
            docker-compose-plugin

        log_ok "Docker installé avec succès"
    fi

    log_info "Vérification de Docker Compose..."
    if ! docker compose version &>/dev/null; then
        log_error "Docker Compose plugin non disponible. Relancer le script."
    fi
    COMPOSE_VER=$(docker compose version --short)
    log_ok "Docker Compose v$COMPOSE_VER disponible"

    log_info "Activation et démarrage de Docker..."
    systemctl enable docker
    systemctl start docker
    log_ok "Docker actif et activé au démarrage"
}

# ─── SECTION 3 : CONFIGURATION SYSTÈME ───────────────────────
configure_system() {
    log_section "CONFIGURATION SYSTÈME"

    log_info "Configuration de vm.max_map_count pour OpenSearch..."
    sysctl -w vm.max_map_count=262144
    if ! grep -q "vm.max_map_count" /etc/sysctl.conf; then
        echo "vm.max_map_count=262144" >> /etc/sysctl.conf
    else
        sed -i 's/^vm.max_map_count=.*/vm.max_map_count=262144/' /etc/sysctl.conf
    fi
    log_ok "vm.max_map_count=262144 configuré (persistant)"

    log_info "Désactivation du swap pour OpenSearch..."
    swapoff -a || true
    sed -i '/swap/s/^/#/' /etc/fstab 2>/dev/null || true
    log_ok "Swap désactivé"
}

# ─── SECTION 4 : GÉNÉRATION DES SECRETS ──────────────────────
generate_secrets() {
    log_section "GÉNÉRATION DES SECRETS"

    log_info "Génération du password_secret (96 caractères)..."
    PASSWORD_SECRET=$(pwgen -N 1 -s 96)
    log_ok "password_secret généré"

    log_info "Hachage SHA256 du mot de passe admin..."
    ROOT_PASSWORD_SHA2=$(echo -n "$ADMIN_PASSWORD" | sha256sum | awk '{print $1}')
    log_ok "Hash SHA256 du mot de passe admin généré"
}

# ─── SECTION 5 : CRÉATION DE L'ARBORESCENCE ──────────────────
create_directories() {
    log_section "CRÉATION DE L'ARBORESCENCE"

    log_info "Création des répertoires de données..."
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$DATA_DIR/mongodb"
    mkdir -p "$DATA_DIR/opensearch"
    mkdir -p "$DATA_DIR/graylog/journal"
    mkdir -p "$DATA_DIR/graylog/config"

    log_info "Application des permissions pour OpenSearch..."
    chown -R 1000:1000 "$DATA_DIR/opensearch"
    chown -R 1100:1100 "$DATA_DIR/graylog"

    log_ok "Arborescence créée : $INSTALL_DIR"
}

# ─── SECTION 6 : FICHIER DOCKER COMPOSE ──────────────────────
# FIX : suppression de "version:" (dépréciée Compose v2, génère un warning)
# FIX : toutes les variables sont résolues par bash au moment de la génération
create_docker_compose() {
    log_section "CRÉATION DU FICHIER DOCKER COMPOSE"

    log_info "Génération de docker-compose.yml..."

    cat > "$INSTALL_DIR/docker-compose.yml" <<EOF
# ============================================================
#  Graylog Full Stack - Docker Compose
#  Graylog ${GRAYLOG_VERSION} | MongoDB ${MONGODB_VERSION} | OpenSearch ${OPENSEARCH_VERSION}
#  IP Graylog : ${GRAYLOG_IP}:${GRAYLOG_PORT}
# ============================================================

networks:
  graylog_net:
    driver: bridge
    ipam:
      config:
        - subnet: 172.20.0.0/24

volumes:
  mongodb_data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: ${DATA_DIR}/mongodb
  opensearch_data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: ${DATA_DIR}/opensearch
  graylog_journal:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: ${DATA_DIR}/graylog/journal

services:

  # ──────────────────────────────────────────────────────────
  #  MONGODB 8.0 - Base de données de configuration Graylog
  # ──────────────────────────────────────────────────────────
  mongodb:
    image: mongo:${MONGODB_VERSION}
    container_name: graylog_mongodb
    restart: unless-stopped
    networks:
      - graylog_net
    volumes:
      - mongodb_data:/data/db
    environment:
      MONGO_INITDB_DATABASE: graylog
    command: mongod --wiredTigerCacheSizeGB 0.5
    healthcheck:
      test: ["CMD", "mongosh", "--eval", "db.adminCommand('ping')"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 40s
    logging:
      driver: "json-file"
      options:
        max-size: "50m"
        max-file: "3"

  # ──────────────────────────────────────────────────────────
  #  OPENSEARCH 2.x - Moteur d'indexation des logs
  # ──────────────────────────────────────────────────────────
  opensearch:
    image: opensearchproject/opensearch:${OPENSEARCH_VERSION}
    container_name: graylog_opensearch
    restart: unless-stopped
    networks:
      - graylog_net
    volumes:
      - opensearch_data:/usr/share/opensearch/data
    environment:
      - cluster.name=graylog
      - node.name=opensearch-node1
      - discovery.type=single-node
      - bootstrap.memory_lock=true
      - "OPENSEARCH_JAVA_OPTS=-Xms${OPENSEARCH_HEAP} -Xmx${OPENSEARCH_HEAP}"
      - DISABLE_INSTALL_DEMO_CONFIG=true
      - DISABLE_SECURITY_PLUGIN=true
    ulimits:
      memlock:
        soft: -1
        hard: -1
      nofile:
        soft: 65536
        hard: 65536
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:9200/_cluster/health || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 10
      start_period: 60s
    logging:
      driver: "json-file"
      options:
        max-size: "50m"
        max-file: "3"

  # ──────────────────────────────────────────────────────────
  #  GRAYLOG 7.1 - Serveur de centralisation des logs
  # ──────────────────────────────────────────────────────────
  graylog:
    image: graylog/graylog:${GRAYLOG_VERSION}
    container_name: graylog_server
    restart: unless-stopped
    depends_on:
      mongodb:
        condition: service_healthy
      opensearch:
        condition: service_healthy
    networks:
      - graylog_net
    volumes:
      - graylog_journal:/usr/share/graylog/data/journal
    environment:
      # ── Secrets ──────────────────────────────────────────
      - GRAYLOG_PASSWORD_SECRET=${PASSWORD_SECRET}
      - GRAYLOG_ROOT_PASSWORD_SHA2=${ROOT_PASSWORD_SHA2}
      # ── HTTP ─────────────────────────────────────────────
      - GRAYLOG_HTTP_BIND_ADDRESS=0.0.0.0:9000
      - GRAYLOG_HTTP_EXTERNAL_URI=http://10.22.32.6:${GRAYLOG_PORT}/
      # ── Base de données ───────────────────────────────────
      - GRAYLOG_MONGODB_URI=mongodb://mongodb:27017/graylog
      # ── OpenSearch ────────────────────────────────────────
      - GRAYLOG_ELASTICSEARCH_HOSTS=http://opensearch:9200
      # ── Timezone & locale ─────────────────────────────────
      - GRAYLOG_ROOT_TIMEZONE=Europe/Paris
      - TZ=Europe/Paris
      # ── Performance ───────────────────────────────────────
      - "GRAYLOG_SERVER_JAVA_OPTS=-Xms${GRAYLOG_HEAP} -Xmx${GRAYLOG_HEAP} -server -XX:+UseG1GC -XX:MaxGCPauseMillis=200"
    ports:
      # Interface web (liée exclusivement à enp2s0 - 10.22.32.6)
      - "10.22.32.6:${GRAYLOG_PORT}:9000"
      # Syslog UDP (équipements réseau)
      - "0.0.0.0:514:514/udp"
      # Syslog TCP
      - "0.0.0.0:514:514/tcp"
      # GELF TCP (applications)
      - "0.0.0.0:12201:12201/tcp"
      # GELF UDP
      - "0.0.0.0:12201:12201/udp"
      # Beats (Filebeat, Winlogbeat...)
      - "0.0.0.0:5044:5044/tcp"
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:9000/api/system/lbstatus || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 15
      start_period: 120s
    logging:
      driver: "json-file"
      options:
        max-size: "100m"
        max-file: "5"
EOF

    log_ok "docker-compose.yml créé : $INSTALL_DIR/docker-compose.yml"
}

# ─── SECTION 7 : FICHIER .ENV ─────────────────────────────────
create_env_file() {
    log_section "CRÉATION DU FICHIER .ENV"

    cat > "$INSTALL_DIR/.env" <<EOF
# Graylog Stack - Variables d'environnement
# Généré automatiquement le $(date '+%Y-%m-%d %H:%M:%S')

GRAYLOG_VERSION=${GRAYLOG_VERSION}
MONGODB_VERSION=${MONGODB_VERSION}
OPENSEARCH_VERSION=${OPENSEARCH_VERSION}

# Carte réseau principale
GRAYLOG_IP=${GRAYLOG_IP}
# Carte réseau secondaire (vide si une seule carte)
GRAYLOG_IP2=${GRAYLOG_IP2}
GRAYLOG_PORT=${GRAYLOG_PORT}

PASSWORD_SECRET=${PASSWORD_SECRET}
ROOT_PASSWORD_SHA2=${ROOT_PASSWORD_SHA2}

OPENSEARCH_HEAP=${OPENSEARCH_HEAP}
GRAYLOG_HEAP=${GRAYLOG_HEAP}
EOF

    chmod 600 "$INSTALL_DIR/.env"
    log_ok "Fichier .env créé et sécurisé (chmod 600)"
}

# ─── SECTION 8 : SERVICE SYSTEMD ─────────────────────────────
create_systemd_service() {
    log_section "CRÉATION DU SERVICE SYSTEMD"

    cat > /etc/systemd/system/graylog-stack.service <<EOF
[Unit]
Description=Graylog Stack (Graylog + MongoDB + OpenSearch)
Documentation=https://docs.graylog.org
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${INSTALL_DIR}
ExecStartPre=/bin/bash -c 'sysctl -w vm.max_map_count=262144'
ExecStart=/usr/bin/docker compose up -d --remove-orphans
ExecStop=/usr/bin/docker compose down
ExecReload=/usr/bin/docker compose restart
TimeoutStartSec=300
TimeoutStopSec=120
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable graylog-stack.service
    log_ok "Service systemd graylog-stack créé et activé au démarrage"
}

# ─── SECTION 9 : CONFIGURATION DU PARE-FEU ───────────────────
# FIX : SSH autorisé AVANT l'activation de UFW pour ne pas se couper
configure_firewall() {
    log_section "CONFIGURATION DU PARE-FEU (UFW)"

    # Sécurité critique : SSH en premier, avant tout le reste
    log_info "Pré-autorisation SSH (port 22) avant activation UFW..."
    ufw allow 22/tcp comment "SSH" 2>/dev/null || true

    UFW_STATUS=$(ufw status 2>/dev/null | head -1 || echo "Status: inactive")
    if echo "$UFW_STATUS" | grep -qi "active"; then
        log_info "UFW déjà actif, mise à jour des règles..."
    else
        log_info "Activation de UFW..."
        ufw --force enable
    fi

    log_info "Autorisation de l'interface web Graylog (port 9000)..."
    ufw allow 9000/tcp comment "Graylog Web UI"

    log_info "Autorisation Syslog UDP/TCP (port 514)..."
    ufw allow 514/udp comment "Syslog UDP"
    ufw allow 514/tcp comment "Syslog TCP"

    log_info "Autorisation GELF TCP/UDP (port 12201)..."
    ufw allow 12201/tcp comment "GELF TCP"
    ufw allow 12201/udp comment "GELF UDP"

    log_info "Autorisation Beats (port 5044)..."
    ufw allow 5044/tcp comment "Beats (Filebeat/Winlogbeat)"

    ufw reload
    log_ok "Pare-feu configuré. Ports ouverts : 22, 9000, 514, 12201, 5044"
    ufw status numbered
}

# ─── SECTION 10 : DÉMARRAGE DE LA STACK ──────────────────────
start_stack() {
    log_section "DÉMARRAGE DE LA STACK GRAYLOG"

    log_info "Pull des images Docker (peut prendre plusieurs minutes)..."
    cd "$INSTALL_DIR"
    docker compose pull

    log_info "Démarrage des conteneurs..."
    docker compose up -d

    log_ok "Conteneurs démarrés"
}

# ─── SECTION 11 : VÉRIFICATION DES SERVICES ──────────────────
# FIX : MongoDB 8.0 embarque mongosh ; ajout fallback mongo pour compatibilité
# FIX : OpenSearch vérifié via docker exec (pas besoin d'exposer le port 9200)
wait_and_verify() {
    log_section "VÉRIFICATION ET ATTENTE DE DISPONIBILITÉ"

    # ── MongoDB ───────────────────────────────────────────────
    log_info "Attente de démarrage de MongoDB..."
    RETRIES=0
    until docker exec graylog_mongodb bash -c \
        "mongosh --eval \"db.adminCommand('ping')\" --quiet 2>/dev/null \
         || mongo --eval \"db.adminCommand('ping')\" --quiet 2>/dev/null" &>/dev/null; do
        RETRIES=$((RETRIES + 1))
        if [[ $RETRIES -ge 20 ]]; then
            log_error "MongoDB n'a pas démarré après 60 secondes. Vérifiez : docker logs graylog_mongodb"
        fi
        echo -n "."
        sleep 3
    done
    echo ""
    log_ok "MongoDB opérationnel"

    # ── OpenSearch ────────────────────────────────────────────
    log_info "Attente de démarrage d'OpenSearch..."
    RETRIES=0
    until docker exec graylog_opensearch \
        curl -sf http://localhost:9200/_cluster/health &>/dev/null; do
        RETRIES=$((RETRIES + 1))
        if [[ $RETRIES -ge 30 ]]; then
            log_error "OpenSearch n'a pas démarré après 90 secondes. Vérifiez : docker logs graylog_opensearch"
        fi
        echo -n "."
        sleep 3
    done
    echo ""
    log_ok "OpenSearch opérationnel"

    # ── Graylog ───────────────────────────────────────────────
    log_info "Attente de démarrage de Graylog (peut prendre 2-3 minutes)..."
    RETRIES=0
    until curl -sf "http://127.0.0.1:${GRAYLOG_PORT}/api/system/lbstatus" &>/dev/null; do
        RETRIES=$((RETRIES + 1))
        if [[ $RETRIES -ge 40 ]]; then
            log_warn "Graylog n'est pas encore accessible. Il peut encore démarrer en arrière-plan."
            log_warn "Vérifiez : docker logs graylog_server"
            break
        fi
        echo -n "."
        sleep 5
    done
    echo ""

    log_info "Statut des conteneurs Docker :"
    docker compose -f "$INSTALL_DIR/docker-compose.yml" ps
}

# ─── SECTION 12 : RÉSUMÉ FINAL ───────────────────────────────
print_summary() {
    log_section "INSTALLATION TERMINÉE - RÉSUMÉ"

    echo -e ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║         GRAYLOG STACK - INSTALLATION RÉUSSIE         ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
    echo -e ""
    echo -e "  ${CYAN}Interface Web :${NC}  http://10.22.32.6:${GRAYLOG_PORT}  (enp2s0 uniquement)"
    echo -e "  ${CYAN}Utilisateur   :${NC}  admin"
    echo -e "  ${CYAN}Mot de passe  :${NC}  ${ADMIN_PASSWORD}"
    echo -e ""
    echo -e "  ${CYAN}Répertoire    :${NC}  ${INSTALL_DIR}"
    echo -e "  ${CYAN}Données       :${NC}  ${DATA_DIR}"
    echo -e "  ${CYAN}Service       :${NC}  systemctl {start|stop|restart|status} graylog-stack"
    echo -e ""
    echo -e "  ${YELLOW}Ports ouverts :${NC}"
    echo -e "    • 9000/tcp   → Interface web Graylog (enp2s0 / 10.22.32.6 uniquement)"
    echo -e "    • 514/udp    → Syslog UDP  (équipements réseau)"
    echo -e "    • 514/tcp    → Syslog TCP  (équipements réseau)"
    echo -e "    • 12201/tcp  → GELF TCP    (applications)"
    echo -e "    • 12201/udp  → GELF UDP    (applications)"
    echo -e "    • 5044/tcp   → Beats       (Filebeat / Winlogbeat)"
    echo -e ""
    echo -e "  ${YELLOW}Commandes utiles :${NC}"
    echo -e "    docker compose -f ${INSTALL_DIR}/docker-compose.yml logs -f"
    echo -e "    docker compose -f ${INSTALL_DIR}/docker-compose.yml ps"
    echo -e "    systemctl status graylog-stack"
    echo -e ""
    echo -e "  ${YELLOW}Configuration équipements réseau (Syslog) :${NC}"
    echo -e "    Pointez vos équipements vers ${GRAYLOG_IP}:514 (UDP ou TCP)"
    if [[ -n "$GRAYLOG_IP2" ]]; then
    echo -e "    ou vers ${GRAYLOG_IP2}:514 (carte réseau 2)"
    fi
    echo -e "    Créez ensuite un Input Syslog dans l'interface web Graylog"
    echo -e ""
    echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
    echo -e ""

    log_info "Secrets sauvegardés dans : ${INSTALL_DIR}/.env (chmod 600)"
    log_warn "Pensez à changer le mot de passe admin après la première connexion !"
}

# ─── POINT D'ENTRÉE PRINCIPAL ─────────────────────────────────
main() {
    clear
    echo -e "${CYAN}"
    echo "  ╔══════════════════════════════════════════════════════╗"
    echo "  ║    INSTALLATION GRAYLOG STACK - DÉMARRAGE           ║"
    echo "  ║    Graylog ${GRAYLOG_VERSION} + MongoDB ${MONGODB_VERSION} + OpenSearch ${OPENSEARCH_VERSION}  ║"
    echo "  ╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    check_root
    check_ubuntu
    check_architecture
    check_ram
    compute_heap_sizes
    detect_ip "${1:-}" "${2:-}"   # Passe les IPs CLI si fournies (jusqu'à 2)
    install_system_deps
    install_docker
    configure_system
    generate_secrets
    create_directories
    create_docker_compose
    create_env_file
    create_systemd_service
    configure_firewall
    start_stack
    wait_and_verify
    print_summary
}

main "$@"
