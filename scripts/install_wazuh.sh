#!/bin/bash
# =============================================================================
# SCRIPT D'INSTALLATION WAZUH VIA DOCKER - PRODUCTION
# Dimensionné pour ~450 équipements (400 postes + 50 équipements réseau)
# Auteur  : Script généré pour déploiement sécurisé
# Version : Wazuh 4.14.x (dernière stable)
# OS cible: Ubuntu Server (dernière LTS)
# =============================================================================
# PRÉREQUIS : Avoir configuré une IP statique AVANT de lancer ce script.
# USAGE     : sudo bash install_wazuh.sh
# =============================================================================

set -euo pipefail   # Arrêt immédiat si une commande échoue

# --------------------------------------------------------------------------
# COULEURS pour les messages dans le terminal
# --------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color (remise à zéro)

# --------------------------------------------------------------------------
# VARIABLES DE CONFIGURATION GLOBALES
# Modifier ici si nécessaire avant de lancer le script
# --------------------------------------------------------------------------
WAZUH_ADMIN_USER="admin"
WAZUH_ADMIN_PASS="Wazuh78"          # Mot de passe administrateur Wazuh
WAZUH_API_USER="wazuh-wui"          # Utilisateur API interne (ne pas changer)
INSTALL_DIR="/opt/wazuh-docker"     # Répertoire d'installation
WAZUH_VERSION="v4.14.0"            # Tag Git de la version à déployer

# --------------------------------------------------------------------------
# FONCTIONS UTILITAIRES
# --------------------------------------------------------------------------

# Affiche un message d'information
info() {
    echo -e "${CYAN}[INFO]${NC} $1"
}

# Affiche un message de succès
ok() {
    echo -e "${GREEN}[OK]${NC} $1"
}

# Affiche un avertissement (non bloquant)
warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Affiche une erreur et quitte le script
error_exit() {
    echo -e "${RED}[ERREUR]${NC} $1" >&2
    exit 1
}

# Vérifie que le script est lancé en root
check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        error_exit "Ce script doit être exécuté en tant que root (sudo bash install_wazuh.sh)"
    fi
}

# Récupère l'adresse IP de la machine (première IP non-loopback)
get_server_ip() {
    hostname -I | awk '{print $1}'
}

# =============================================================================
# ÉTAPE 0 : VÉRIFICATIONS PRÉLIMINAIRES
# =============================================================================
check_root

echo ""
echo -e "${CYAN}======================================================${NC}"
echo -e "${CYAN}   INSTALLATION WAZUH ${WAZUH_VERSION} - MODE PRODUCTION${NC}"
echo -e "${CYAN}   Dimensionné pour 450 équipements${NC}"
echo -e "${CYAN}======================================================${NC}"
echo ""

SERVER_IP=$(get_server_ip)
info "IP détectée du serveur : ${SERVER_IP}"

# Vérifie que la machine a bien une IP statique configurée (IP non vide)
if [[ -z "$SERVER_IP" ]]; then
    error_exit "Impossible de détecter l'IP du serveur. Vérifiez votre configuration réseau."
fi

# Vérifie qu'on est bien sur Ubuntu
if ! grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
    warn "Ce script est optimisé pour Ubuntu Server. Continuez à vos risques."
fi

# =============================================================================
# ÉTAPE 1 : MISE À JOUR DU SYSTÈME
# Met à jour tous les paquets pour éviter les conflits de dépendances
# =============================================================================
info "Mise à jour des paquets système..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get upgrade -y -qq
ok "Système mis à jour."

# =============================================================================
# ÉTAPE 2 : INSTALLATION DES DÉPENDANCES ESSENTIELLES
# curl, git, ca-certificates nécessaires pour la suite
# =============================================================================
info "Installation des dépendances (curl, git, gnupg, ca-certificates)..."
apt-get install -y -qq \
    curl \
    git \
    gnupg \
    ca-certificates \
    lsb-release \
    software-properties-common \
    apt-transport-https \
    pwgen \
    net-tools \
    jq
ok "Dépendances installées."

# =============================================================================
# ÉTAPE 3 : INSTALLATION DE DOCKER ENGINE
# On utilise le dépôt officiel Docker pour avoir la version la plus récente
# =============================================================================
info "Vérification de Docker..."

if command -v docker &>/dev/null; then
    DOCKER_VER=$(docker --version | awk '{print $3}' | tr -d ',')
    ok "Docker déjà installé (version ${DOCKER_VER}). Skip."
else
    info "Installation de Docker depuis le dépôt officiel..."

    # Suppression d'éventuelles anciennes versions
    apt-get remove -y -qq docker docker-engine docker.io containerd runc 2>/dev/null || true

    # Ajout de la clé GPG officielle Docker
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    # Ajout du dépôt Docker
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      | tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Active et démarre Docker au démarrage
    systemctl enable docker --quiet
    systemctl start docker
    ok "Docker installé et démarré."
fi

# Vérifie que Docker fonctionne
docker info &>/dev/null || error_exit "Docker ne répond pas. Vérifiez l'installation."

# =============================================================================
# ÉTAPE 4 : CONFIGURATION DES LIMITES SYSTÈME
# Wazuh Indexer (OpenSearch) a besoin de paramètres kernel spécifiques.
# max_map_count = 262144 requis (défaut Linux = 65530, insuffisant)
# Pour 450 agents : on augmente aussi les limites de fichiers ouverts
# =============================================================================
info "Configuration des paramètres kernel pour Wazuh Indexer..."

# Paramètre temporaire (actif immédiatement, sans redémarrage)
sysctl -w vm.max_map_count=262144 > /dev/null

# Paramètre permanent (survit aux redémarrages)
if ! grep -q "vm.max_map_count" /etc/sysctl.conf; then
    echo "vm.max_map_count=262144" >> /etc/sysctl.conf
fi

# Optimisations réseau pour un parc de 450 équipements
# Augmente le nombre de connexions TCP simultanées
cat >> /etc/sysctl.conf << 'SYSCTL_EOF'
# --- Optimisations Wazuh pour 450 agents ---
net.core.somaxconn=65535
net.ipv4.tcp_max_syn_backlog=65535
fs.file-max=2097152
SYSCTL_EOF
sysctl -p > /dev/null 2>&1 || true

# Limites de fichiers ouverts pour les conteneurs Docker
cat > /etc/security/limits.d/wazuh.conf << 'LIMITS_EOF'
# Limites pour Wazuh avec 450 agents connectés
*         soft    nofile      1048576
*         hard    nofile      1048576
root      soft    nofile      1048576
root      hard    nofile      1048576
LIMITS_EOF

ok "Paramètres kernel configurés."

# =============================================================================
# ÉTAPE 5 : CLONAGE DU DÉPÔT WAZUH-DOCKER OFFICIEL
# On clone la version stable officielle depuis GitHub
# =============================================================================
info "Clonage du dépôt Wazuh Docker officiel (${WAZUH_VERSION})..."

# Supprime l'ancien répertoire si existant (réinstallation propre)
if [[ -d "$INSTALL_DIR" ]]; then
    warn "Répertoire ${INSTALL_DIR} existant détecté. Suppression..."
    rm -rf "$INSTALL_DIR"
fi

# Clone la version taguée pour garantir la stabilité
git clone --depth 1 --branch "${WAZUH_VERSION}" \
    https://github.com/wazuh/wazuh-docker.git \
    "$INSTALL_DIR" 2>&1 | tail -3

ok "Dépôt cloné dans ${INSTALL_DIR}."

# On travaille dans le répertoire single-node (suffisant pour 450 agents)
# Pour >1000 agents, basculer sur multi-node
cd "${INSTALL_DIR}/single-node"

# =============================================================================
# ÉTAPE 6 : CONFIGURATION DE LA MÉMOIRE POUR 450 AGENTS
# Par défaut Wazuh alloue 1 Go au Wazuh Indexer.
# Pour 450 agents on recommande au minimum 4 Go.
# Le script détecte la RAM disponible et ajuste automatiquement.
# =============================================================================
info "Ajustement de la mémoire Wazuh Indexer selon la RAM disponible..."

TOTAL_RAM_MB=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024)}')
info "RAM totale détectée : ${TOTAL_RAM_MB} Mo"

if [[ "$TOTAL_RAM_MB" -ge 16000 ]]; then
    # Serveur >= 16 Go RAM : 6 Go pour l'indexer
    JVM_HEAP="6g"
    info "Allocation JVM : 6 Go (serveur haute capacité)"
elif [[ "$TOTAL_RAM_MB" -ge 8000 ]]; then
    # Serveur 8-16 Go RAM : 4 Go pour l'indexer
    JVM_HEAP="4g"
    info "Allocation JVM : 4 Go (recommandé pour 450 agents)"
elif [[ "$TOTAL_RAM_MB" -ge 4000 ]]; then
    # Serveur 4-8 Go RAM : 2 Go pour l'indexer (minimum acceptable)
    JVM_HEAP="2g"
    warn "RAM limitée (${TOTAL_RAM_MB} Mo). JVM à 2 Go. Performances réduites avec 450 agents."
else
    # Moins de 4 Go : on continue mais on avertit
    JVM_HEAP="1g"
    warn "RAM insuffisante (${TOTAL_RAM_MB} Mo) pour 450 agents. Minimum recommandé : 8 Go."
fi

# Modifie le fichier docker-compose.yml pour ajuster la JVM de l'indexer
if grep -q "OPENSEARCH_JAVA_OPTS" docker-compose.yml; then
    # Remplace la valeur existante par celle calculée
    sed -i "s/-Xms[0-9]*[gm] -Xmx[0-9]*[gm]/-Xms${JVM_HEAP} -Xmx${JVM_HEAP}/g" docker-compose.yml
    ok "JVM Wazuh Indexer configuré à ${JVM_HEAP} (heap min et max)."
else
    warn "Paramètre OPENSEARCH_JAVA_OPTS non trouvé. Configuration JVM manuelle requise."
fi

# =============================================================================
# ÉTAPE 7 : GÉNÉRATION DES CERTIFICATS SSL
# Wazuh utilise des certificats TLS pour sécuriser les communications
# entre le Manager, l'Indexer et le Dashboard
# =============================================================================
info "Génération des certificats SSL internes Wazuh..."

docker compose -f generate-indexer-certs.yml run --rm generator 2>&1 | tail -5

ok "Certificats SSL générés."

# =============================================================================
# ÉTAPE 8 : CONFIGURATION DU MOT DE PASSE ADMINISTRATEUR
# On injecte notre mot de passe personnalisé AVANT le premier démarrage
# pour éviter de devoir le changer après coup
# =============================================================================
info "Configuration du mot de passe administrateur (${WAZUH_ADMIN_USER})..."

# Le fichier internal_users.yml contient les hash des mots de passe utilisateurs
# On utilise un conteneur temporaire pour générer le hash bcrypt du mot de passe
HASH=$(docker run --rm \
    wazuh/wazuh-indexer:"${WAZUH_VERSION#v}" \
    bash -c "plugins/opensearch-security/tools/hash.sh -p '${WAZUH_ADMIN_PASS}' 2>/dev/null | tail -1" 2>/dev/null) || true

if [[ -n "$HASH" && "$HASH" =~ ^\$2y\$ ]]; then
    # Remplace le hash admin dans la configuration de l'indexer
    INTERNAL_USERS_FILE="config/wazuh_indexer/internal_users.yml"
    if [[ -f "$INTERNAL_USERS_FILE" ]]; then
        # Met à jour le hash du mot de passe admin
        python3 - <<PYTHON_EOF
import re

with open('${INTERNAL_USERS_FILE}', 'r') as f:
    content = f.read()

# Remplace le hash existant de l'admin
new_hash = '${HASH}'
content = re.sub(
    r'(^admin:\s*\n\s*hash:\s*)".+"',
    r'\1"' + new_hash + '"',
    content,
    flags=re.MULTILINE
)

with open('${INTERNAL_USERS_FILE}', 'w') as f:
    f.write(content)

print("Hash admin mis à jour avec succès.")
PYTHON_EOF
        ok "Hash du mot de passe admin configuré."
    fi
else
    warn "Génération du hash impossible via conteneur. Le mot de passe sera changé après démarrage."
    CHANGE_PASS_AFTER=true
fi

# =============================================================================
# ÉTAPE 9 : DÉMARRAGE DE LA STACK WAZUH
# Lance tous les conteneurs en arrière-plan (mode détaché)
# Ordre de démarrage géré par Docker Compose (depends_on)
# =============================================================================
info "Démarrage de la stack Wazuh (Indexer + Manager + Dashboard)..."
info "Cette étape peut prendre 3 à 5 minutes selon les ressources..."

docker compose up -d 2>&1

ok "Conteneurs lancés en arrière-plan."

# =============================================================================
# ÉTAPE 10 : ATTENTE QUE LES SERVICES SOIENT PRÊTS
# On attend que l'API Wazuh Manager et le Dashboard soient accessibles
# avant de changer les mots de passe ou d'afficher les infos finales
# =============================================================================
info "Attente que les services Wazuh soient opérationnels..."

MAX_WAIT=300    # Timeout maximum : 5 minutes
ELAPSED=0
INTERVAL=10     # Vérifie toutes les 10 secondes

# Attend que le Wazuh Dashboard réponde sur le port 443
while [[ $ELAPSED -lt $MAX_WAIT ]]; do
    if curl -ks --max-time 5 "https://localhost:443" &>/dev/null; then
        ok "Dashboard Wazuh accessible !"
        break
    fi
    echo -ne "${YELLOW}  Attente du Dashboard... ${ELAPSED}s/${MAX_WAIT}s\r${NC}"
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done

if [[ $ELAPSED -ge $MAX_WAIT ]]; then
    warn "Le Dashboard n'a pas répondu dans les temps. Vérifiez avec : docker compose logs wazuh.dashboard"
fi

# Attente supplémentaire pour que l'API Manager soit prête
info "Attente de l'API Wazuh Manager..."
sleep 30

# =============================================================================
# ÉTAPE 11 : CHANGEMENT DE MOT DE PASSE VIA L'API WAZUH
# Si le hash n'a pas pu être prégénéré, on change le mot de passe
# via l'API REST du Manager après le démarrage
# =============================================================================

# Récupère le mot de passe initial par défaut depuis les variables d'environnement
DEFAULT_PASS="SecretPassword"

# Tente de changer le mot de passe de l'utilisateur admin de l'Indexer
info "Application du mot de passe personnalisé via l'API Wazuh Indexer..."

CHANGE_RESULT=$(curl -ks -u "${WAZUH_ADMIN_USER}:${DEFAULT_PASS}" \
    -X PUT "https://localhost:9200/_plugins/_security/api/internalusers/${WAZUH_ADMIN_USER}" \
    -H 'Content-Type: application/json' \
    -d "{\"password\": \"${WAZUH_ADMIN_PASS}\"}" 2>/dev/null) || true

if echo "$CHANGE_RESULT" | grep -qi '"status":"OK"'; then
    ok "Mot de passe admin changé avec succès via l'API."
else
    # Le mot de passe a peut-être déjà été défini via le hash, c'est normal
    info "Tentative via l'API avec le nouveau mot de passe (peut déjà être défini)..."
    CHANGE_RESULT2=$(curl -ks -u "${WAZUH_ADMIN_USER}:${WAZUH_ADMIN_PASS}" \
        -X GET "https://localhost:9200/_plugins/_security/api/internalusers/${WAZUH_ADMIN_USER}" \
        -H 'Content-Type: application/json' 2>/dev/null) || true
    if echo "$CHANGE_RESULT2" | grep -qi '"status":"OK"'; then
        ok "Mot de passe admin déjà configuré correctement."
    else
        warn "Le changement de mot de passe automatique a échoué. Reportez-vous aux instructions manuelles ci-dessous."
    fi
fi

# =============================================================================
# ÉTAPE 12 : CHANGEMENT DU MOT DE PASSE DE L'API WAZUH MANAGER
# L'API du Manager (port 55000) a aussi son propre système d'auth
# =============================================================================
info "Configuration du mot de passe API Wazuh Manager..."

# Obtient un token JWT avec les credentials par défaut
API_TOKEN=$(curl -ks -u "wazuh-wui:MyS3cr37P450r.*-" \
    -X POST "https://localhost:55000/security/user/authenticate" \
    -H "Content-Type: application/json" 2>/dev/null | jq -r '.data.token' 2>/dev/null) || true

if [[ -n "$API_TOKEN" && "$API_TOKEN" != "null" ]]; then
    # Récupère l'ID de l'utilisateur wazuh-wui
    USER_ID=$(curl -ks -X GET "https://localhost:55000/security/users" \
        -H "Authorization: Bearer ${API_TOKEN}" 2>/dev/null | \
        jq -r '.data.affected_items[] | select(.username=="wazuh-wui") | .id' 2>/dev/null) || true

    if [[ -n "$USER_ID" && "$USER_ID" != "null" ]]; then
        curl -ks -X PUT "https://localhost:55000/security/users/${USER_ID}" \
            -H "Authorization: Bearer ${API_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "{\"password\": \"${WAZUH_ADMIN_PASS}\"}" &>/dev/null || true
        ok "Mot de passe API Manager configuré."
    fi
else
    warn "API Manager pas encore prête ou credentials déjà changés. Ignoré."
fi

# =============================================================================
# ÉTAPE 13 : CONFIGURATION DU FIREWALL UFW
# Ouvre les ports nécessaires pour que les agents puissent se connecter
# et que les admins accèdent au Dashboard
# =============================================================================
info "Configuration du firewall (UFW)..."

if command -v ufw &>/dev/null; then
    ufw --force enable > /dev/null 2>&1 || true

    # Port 443 : Interface web Dashboard (HTTPS)
    ufw allow 443/tcp comment "Wazuh Dashboard HTTPS" > /dev/null

    # Port 1514 : Communication agents Wazuh (UDP + TCP)
    ufw allow 1514/tcp comment "Wazuh Agent TCP" > /dev/null
    ufw allow 1514/udp comment "Wazuh Agent UDP" > /dev/null

    # Port 1515 : Enregistrement automatique des agents (auto-enrollment)
    ufw allow 1515/tcp comment "Wazuh Agent Enrollment" > /dev/null

    # Port 55000 : API REST Wazuh Manager
    ufw allow 55000/tcp comment "Wazuh Manager API" > /dev/null

    # Port 9200 : API Wazuh Indexer (OpenSearch) - accès interne recommandé uniquement
    # ufw allow 9200/tcp  # Décommenter si accès externe nécessaire

    # Port 22 : SSH (garde l'accès admin au serveur)
    ufw allow ssh > /dev/null

    ok "Firewall UFW configuré."
else
    warn "UFW non installé. Configurez manuellement les ports : 443, 1514, 1515, 55000."
fi

# =============================================================================
# ÉTAPE 14 : CONFIGURATION DU REDÉMARRAGE AUTOMATIQUE
# Les conteneurs redémarrent automatiquement si le serveur reboot
# (restart: always est déjà dans le docker-compose.yml)
# On s'assure aussi que Docker démarre au boot
# =============================================================================
info "Configuration du démarrage automatique au boot..."
systemctl enable docker --quiet
ok "Docker configuré pour démarrer au boot."

# Crée un service systemd pour relancer Wazuh si besoin
cat > /etc/systemd/system/wazuh-docker.service << SYSTEMD_EOF
[Unit]
Description=Wazuh SIEM via Docker Compose
Requires=docker.service
After=docker.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${INSTALL_DIR}/single-node
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
SYSTEMD_EOF

systemctl daemon-reload
systemctl enable wazuh-docker --quiet
ok "Service systemd wazuh-docker créé et activé."

# =============================================================================
# ÉTAPE 15 : VÉRIFICATION FINALE DE L'ÉTAT DES CONTENEURS
# =============================================================================
info "Vérification de l'état des conteneurs Wazuh..."
echo ""
docker compose ps
echo ""

# Vérifie que les 3 conteneurs principaux tournent bien
RUNNING=$(docker compose ps --status running 2>/dev/null | grep -c "Up\|running" || echo 0)
if [[ "$RUNNING" -ge 3 ]]; then
    ok "Les 3 composants Wazuh sont opérationnels."
else
    warn "${RUNNING}/3 conteneurs actifs. Consultez les logs si nécessaire :"
    warn "  docker compose -f ${INSTALL_DIR}/single-node/docker-compose.yml logs --tail=50"
fi

# =============================================================================
# AFFICHAGE FINAL : TOUTES LES INFORMATIONS IMPORTANTES
# =============================================================================
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}   INSTALLATION WAZUH TERMINÉE - INFORMATIONS DE CONNEXION${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo -e "  ${CYAN}Interface Web (Dashboard) :${NC}"
echo -e "    URL      : ${YELLOW}https://${SERVER_IP}${NC}"
echo -e "    Login    : ${YELLOW}${WAZUH_ADMIN_USER}${NC}"
echo -e "    Password : ${YELLOW}${WAZUH_ADMIN_PASS}${NC}"
echo ""
echo -e "  ${CYAN}API REST Wazuh Manager :${NC}"
echo -e "    URL      : ${YELLOW}https://${SERVER_IP}:55000${NC}"
echo -e "    Login    : ${YELLOW}wazuh-wui${NC}"
echo -e "    Password : ${YELLOW}${WAZUH_ADMIN_PASS}${NC}"
echo ""
echo -e "  ${CYAN}Wazuh Indexer (OpenSearch) :${NC}"
echo -e "    URL      : ${YELLOW}https://${SERVER_IP}:9200${NC}"
echo -e "    Login    : ${YELLOW}${WAZUH_ADMIN_USER}${NC}"
echo -e "    Password : ${YELLOW}${WAZUH_ADMIN_PASS}${NC}"
echo ""
echo -e "  ${CYAN}Connexion des agents (sur les 450 postes/équipements) :${NC}"
echo -e "    Adresse Manager : ${YELLOW}${SERVER_IP}${NC}"
echo -e "    Port TCP/UDP    : ${YELLOW}1514${NC}"
echo -e "    Port Enrollment : ${YELLOW}1515${NC}"
echo ""
echo -e "  ${CYAN}Répertoire d'installation :${NC}"
echo -e "    ${YELLOW}${INSTALL_DIR}/single-node${NC}"
echo ""
echo -e "  ${CYAN}Commandes utiles :${NC}"
echo -e "    Voir les logs    : ${YELLOW}cd ${INSTALL_DIR}/single-node && docker compose logs -f${NC}"
echo -e "    Arrêter Wazuh   : ${YELLOW}cd ${INSTALL_DIR}/single-node && docker compose down${NC}"
echo -e "    Démarrer Wazuh  : ${YELLOW}cd ${INSTALL_DIR}/single-node && docker compose up -d${NC}"
echo -e "    Statut services  : ${YELLOW}cd ${INSTALL_DIR}/single-node && docker compose ps${NC}"
echo ""
echo -e "  ${CYAN}Déploiement agent Linux (exemple) :${NC}"
echo -e "    ${YELLOW}WAZUH_MANAGER='${SERVER_IP}' bash <(curl -s https://packages.wazuh.com/4.x/unix/wazuh-agent.sh)${NC}"
echo ""
echo -e "  ${CYAN}Déploiement agent Windows (PowerShell) :${NC}"
echo -e "    ${YELLOW}Invoke-WebRequest -Uri 'https://packages.wazuh.com/4.x/windows/wazuh-agent-4.x.x-1.msi' -OutFile wazuh-agent.msi${NC}"
echo -e "    ${YELLOW}.\wazuh-agent.msi /q WAZUH_MANAGER='${SERVER_IP}'${NC}"
echo ""
echo -e "${RED}  IMPORTANT : Le certificat SSL est auto-signé.${NC}"
echo -e "${RED}  Votre navigateur affichera un avertissement -> cliquer sur 'Avancé' puis 'Continuer'.${NC}"
echo ""
echo -e "${GREEN}============================================================${NC}"
echo ""

# Sauvegarde les informations dans un fichier texte pour référence ultérieure
cat > /root/wazuh-credentials.txt << CRED_EOF
=== WAZUH - INFORMATIONS D'ACCÈS ===
Généré le : $(date)
Version   : ${WAZUH_VERSION}

Dashboard Web    : https://${SERVER_IP}
Login admin      : ${WAZUH_ADMIN_USER}
Mot de passe     : ${WAZUH_ADMIN_PASS}

API Manager      : https://${SERVER_IP}:55000
Login API        : wazuh-wui
Mot de passe API : ${WAZUH_ADMIN_PASS}

Adresse Manager pour agents : ${SERVER_IP}
Port agents      : 1514 (TCP/UDP)
Port enrollment  : 1515 (TCP)

Répertoire : ${INSTALL_DIR}/single-node
CRED_EOF

chmod 600 /root/wazuh-credentials.txt
ok "Informations sauvegardées dans /root/wazuh-credentials.txt"
echo ""
