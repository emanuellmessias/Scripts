#!/usr/bin/env bash
#===============================================================================
# upgrade-db-el9.sh   -   HOST: DB server (ex.: DC02SPMONBD01)
#
# Papel do host: MySQL (banco do Zabbix, remoto para o APP) + zabbix-agent2.
#   (O zabbix-server/zabbix-web deste host sao RESIDUAIS e estao inactive/disabled;
#    este script NAO os sobe nem os atualiza para 8.0.)
#
# O que faz:
#   1) DUMP OBRIGATORIO do banco 'zabbix' (alem do snapshot)
#   2) MySQL 8.0 -> 8.4 LTS via modulo AppStream (NUNCA 9.x)
#   3) zabbix-agent2 7.4 -> 8.0
#
# ORDEM NA JANELA DE MANUTENCAO (prod):
#   1. APP01 : systemctl stop zabbix-server     (congela escrita no banco)
#   2. BD01  : ./upgrade-db-el9.sh    <<< ESTE SCRIPT
#   3. APP01 : ./upgrade-app-el9.sh   (sobe server 8.0 e MIGRA o schema)
#   4. Proxy : ./upgrade-proxy-el9.sh
#
# ROLLBACK: restaurar o SNAPSHOT da VM (MySQL 8.4 nao permite downgrade).
#           O dump gerado aqui e uma rede extra: pode reimportar em um 8.0 limpo.
#
# Uso:
#   chmod +x upgrade-db-el9.sh
#   ./upgrade-db-el9.sh --check     # dry-run: so pre-flight, NAO altera nada
#   ./upgrade-db-el9.sh             # executa (pede confirmacoes)
#   ./upgrade-db-el9.sh --yes       # executa sem perguntas
#
# ATENCAO: preencha a senha do root do MySQL no placeholder abaixo ANTES de rodar.
#          NAO versione este arquivo com a senha real. Depois migre para .my.cnf.
#===============================================================================

set -Eeuo pipefail

#############################  SENHAS (PREENCHER)  #############################
#  >>> SUBSTITUA o placeholder pela senha real ANTES de executar. <<<
#  >>> Etapa 2 (seguranca): troque por /root/.my.cnf (mode 600) e remova daqui. <<<
MYSQL_ROOT_PASSWORD="__PREENCHER_SENHA_ROOT_MYSQL__"
###############################################################################
# Alternativa recomendada (etapa 2) - crie /root/.my.cnf com:
#   [client]
#   user=root
#   password=senha
#   chmod 600 /root/.my.cnf
# e troque a funcao mysql_root() abaixo para usar apenas:  mysql "$@"

ZABBIX_DB_NAME="zabbix"
MYSQL_TARGET_STREAM="mysql:8.4"
MYSQL_TARGET_MAJOR="8.4"
DUMP_DIR="/root"

MODE="run"
case "${1:-}" in
  --check) MODE="check" ;;
  --yes)   MODE="yes"   ;;
esac

LOG_FILE="/root/upgrade-db-$(date +%Y-%m-%d_%H%M).log"
exec > >(tee -a "$LOG_FILE") 2>&1

c_reset=$'\e[0m'; c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_blu=$'\e[36m'
log()  { echo "${c_blu}[$(date +%H:%M:%S)]${c_reset} $*"; }
ok()   { echo "${c_grn}[ OK ]${c_reset} $*"; }
warn() { echo "${c_ylw}[AVISO]${c_reset} $*"; }
die()  { echo "${c_red}[ERRO]${c_reset} $*"; echo "${c_red}>>> ABORTADO. Restaure o SNAPSHOT se o banco ja foi tocado. Log: $LOG_FILE${c_reset}"; exit 1; }
trap 'die "Falha inesperada na linha $LINENO."' ERR

confirm() {
  local msg="$1"
  [[ "$MODE" == "yes" ]] && { log "[--yes] pulando: $msg"; return 0; }
  echo; echo "${c_ylw}>>> $msg${c_reset}"
  read -r -p "    Digite 'sim' para continuar: " r; [[ "$r" == "sim" ]] || die "Confirmacao negada."
}
mysql_root() { mysql -u root -p"${MYSQL_ROOT_PASSWORD}" "$@"; }

echo "================================================================"
echo " DB SERVER  |  MySQL 8.0 -> ${MYSQL_TARGET_MAJOR} + agent2 7.4 -> 8.0"
echo " host: $(hostname)  |  modo: $MODE  |  $(date)"
echo " Log: $LOG_FILE"
echo "================================================================"

#============================ FASE 0 - PRE-FLIGHT ============================
log "FASE 0 - Pre-flight (somente leitura)"
[[ $EUID -eq 0 ]] || die "Rode como root."
[[ "$MYSQL_ROOT_PASSWORD" != "__PREENCHER_SENHA_ROOT_MYSQL__" ]] || die "Preencha MYSQL_ROOT_PASSWORD no topo do script."
grep -qiE 'Oracle Linux|AlmaLinux|Red Hat|Rocky' /etc/os-release || die "SO nao e EL9 compativel."
. /etc/os-release; [[ "${VERSION_ID%%.*}" == "9" ]] || die "Este script e para EL9. Versao detectada: $VERSION_ID"
ok "SO: $NAME $VERSION_ID"

for b in dnf rpm systemctl mysql mysqldump; do command -v "$b" >/dev/null || die "Faltou comando: $b"; done

systemctl is-active --quiet mysqld || die "mysqld nao esta ativo."
MYSQL_VER="$(mysql_root -N -B -e 'SELECT VERSION();' 2>/dev/null | head -1)" || die "Sem conexao no MySQL (confira a senha root)."
ok "MySQL atual: $MYSQL_VER"

TAB="$(mysql_root -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${ZABBIX_DB_NAME}';")" || die "Nao consultei o banco."
[[ "$TAB" -gt 100 ]] || die "Banco '${ZABBIX_DB_NAME}' com $TAB tabelas (esperado >100)."
ok "Banco '${ZABBIX_DB_NAME}' integro: $TAB tabelas."

# server residual deve estar parado (seguranca anti dois-servers)
if systemctl is-active --quiet zabbix-server 2>/dev/null; then
  die "zabbix-server (residual) esta ATIVO neste DB host. Pare/desabilite antes (deveria estar inactive/disabled)."
fi
ok "zabbix-server residual: inativo (correto)."

rpm -qa | grep -q '^zabbix-agent2' && ok "zabbix-agent2 presente: $(rpm -q --qf '%{VERSION}\n' zabbix-agent2)" || warn "zabbix-agent2 nao encontrado."

DB_SIZE="$(du -sh /var/lib/mysql 2>/dev/null | awk '{print $1}')"
FREE_MB="$(df -Pm /root | awk 'NR==2{print $4}')"
ok "Tamanho do datadir: ${DB_SIZE:-?}  |  Livre em /root p/ dump: ${FREE_MB} MB"

if [[ "$MODE" == "check" ]]; then
  echo; ok "DRY-RUN concluido. Nada foi alterado."; exit 0
fi

# ja esta em 8.4? (idempotencia)
case "$MYSQL_VER" in
  ${MYSQL_TARGET_MAJOR}.*) ok "MySQL ja esta em $MYSQL_VER."; SKIP_MYSQL="yes" ;;
  8.0.*) SKIP_MYSQL="no" ;;
  *) die "MySQL em versao inesperada: $MYSQL_VER." ;;
esac

echo "----------------------------------------------------------------"
echo " PLANO: dump do banco -> (se preciso) MySQL 8.0->8.4 -> agent2 ->8.0"
echo "----------------------------------------------------------------"
confirm "VOCE JA TIROU O SNAPSHOT da VM do BD? (requisito mesmo com dump)"

#============================ FASE 1 - DUMP OBRIGATORIO ======================
log "FASE 1 - Dump do banco (rede de seguranca adicional ao snapshot)"
DUMP_FILE="${DUMP_DIR}/${ZABBIX_DB_NAME}_pre-upgrade_$(date +%Y-%m-%d_%H%M).sql"
log "Gerando dump em: $DUMP_FILE (pode demorar conforme o tamanho ${DB_SIZE:-?})..."
mysqldump -u root -p"${MYSQL_ROOT_PASSWORD}" \
  --single-transaction --routines --triggers --events --quick \
  "${ZABBIX_DB_NAME}" > "$DUMP_FILE"
# valida que o dump nao ficou vazio/corrompido
[[ -s "$DUMP_FILE" ]] || die "Dump ficou vazio!"
tail -5 "$DUMP_FILE" | grep -qi 'Dump completed' || die "Dump nao terminou com 'Dump completed' (incompleto!)."
ok "Dump OK: $(du -h "$DUMP_FILE" | awk '{print $1}')  ($DUMP_FILE)"

#============================ FASE 2 - MYSQL 8.0 -> 8.4 ======================
if [[ "$SKIP_MYSQL" == "no" ]]; then
  log "FASE 2 - MySQL 8.0 -> ${MYSQL_TARGET_MAJOR} (modulo AppStream)"
  systemctl stop mysqld
  dnf -y module reset mysql
  dnf -y module enable "$MYSQL_TARGET_STREAM"
  dnf -y distro-sync

  MYSQLD_VER="$(mysqld --version 2>/dev/null | grep -oE 'Ver [0-9]+\.[0-9]+\.[0-9]+' | awk '{print $2}')"
  case "$MYSQLD_VER" in
    ${MYSQL_TARGET_MAJOR}.*) ok "Binario mysqld agora: $MYSQLD_VER" ;;
    *) die "Apos distro-sync o mysqld esta em '$MYSQLD_VER' (esperado ${MYSQL_TARGET_MAJOR}.x)." ;;
  esac

  log "Subindo MySQL ${MYSQL_TARGET_MAJOR} (upgrade do dicionario de dados automatico)..."
  systemctl start mysqld
  sleep 5
  systemctl is-active --quiet mysqld || { journalctl -u mysqld -n 30 --no-pager; die "mysqld nao subiu."; }
  MYSQL_VER="$(mysql_root -N -B -e 'SELECT VERSION();' | head -1)"
  case "$MYSQL_VER" in ${MYSQL_TARGET_MAJOR}.*) ok "MySQL em execucao: $MYSQL_VER" ;; *) die "VERSION()=$MYSQL_VER inesperado." ;; esac
else
  log "FASE 2 - PULADA (MySQL ja em 8.4)."
fi

#============================ FASE 3 - AGENT2 7.4 -> 8.0 =====================
log "FASE 3 - zabbix-agent2 7.4 -> 8.0"
rpm -Uvh --force "https://repo.zabbix.com/zabbix/8.0/release/rhel/9/noarch/zabbix-release-latest.el9.noarch.rpm"
dnf clean all
systemctl stop zabbix-agent2 2>/dev/null || true
confirm "Confirma o 'dnf install zabbix-agent2' (versao deve ser 8.0.x)?"
dnf -y install zabbix-agent2 'zabbix-agent2-plugin-*'
systemctl start zabbix-agent2 && ok "zabbix-agent2 iniciado: $(rpm -q --qf '%{VERSION}\n' zabbix-agent2)" || warn "falha ao subir agent2."

#============================ VALIDACAO FINAL ===============================
log "VALIDACAO FINAL"
echo "----------------------------------------------------------------"
echo "MySQL                 : $(mysql_root -N -B -e 'SELECT VERSION();' | head -1)"
echo "zabbix-agent2         : $(rpm -q --qf '%{VERSION}\n' zabbix-agent2 2>/dev/null)"
echo "Servicos              :"; systemctl is-active mysqld zabbix-agent2
echo "Dump                  : $DUMP_FILE"
echo "----------------------------------------------------------------"
ok "DB server concluido. PROXIMO PASSO: rodar ./upgrade-app-el9.sh no APP01 (sobe o server 8.0 e migra o schema)."
echo "${c_ylw}>>> LEMBRETE: remover a senha chumbada deste script e migrar para /root/.my.cnf (etapa 2).${c_reset}"
