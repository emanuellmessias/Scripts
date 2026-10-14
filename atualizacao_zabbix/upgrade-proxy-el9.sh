#!/usr/bin/env bash
#===============================================================================
# upgrade-proxy-el9.sh   -   HOST: Zabbix Proxy EL9 (ex.: DC02SPMON001)
#
# Papel do host: zabbix-proxy-mysql + MariaDB local + zabbix-agent2.
#   Detectado em prod: MariaDB 10.5.29  (INCOMPATIVEL com Zabbix 8.0!)
#   Zabbix 8.0 exige MariaDB 10.11.00 - 12.3.X.
#   DBHost=localhost DBName=zabbix_proxy DBUser=proxy_betta ProxyBufferMode=disk
#
# O que faz:
#   1) MariaDB 10.5 -> 10.11 LTS via modulo AppStream (se < 10.11)
#   2) zabbix-proxy-mysql + zabbix-agent2 7.4 -> 8.0
#   3) Garante que ProxyBufferMode=disk nao conflite com ProxyMemoryBuffer*
#      (com disk, essas duas opcoes IMPEDEM o proxy de iniciar)
#
# ORDEM: rodar DEPOIS do server (APP01) ja estar em 8.0
#        (server e proxy devem ser a MESMA major).
#
# ROLLBACK: restaurar SNAPSHOT do proxy (MariaDB nao permite downgrade).
#
# Uso (rodar em CADA proxy EL9):
#   ./upgrade-proxy-el9.sh --check
#   ./upgrade-proxy-el9.sh
#   ./upgrade-proxy-el9.sh --yes
#===============================================================================

set -Eeuo pipefail

#############################  SENHAS (PREENCHER)  #############################
#  >>> Senha do root da MariaDB local do proxy. <<<
MARIADB_ROOT_PASSWORD="__PREENCHER_SENHA_ROOT_MARIADB__"
###############################################################################
# Obs.: se o root da MariaDB usa auth via unix_socket (padrao em muitas instalacoes),
#       deixe a senha vazia ("") e o script tentara conectar via socket como root.

PROXY_DB_NAME="zabbix_proxy"
MARIADB_TARGET_STREAM="mariadb:10.11"
MARIADB_TARGET_MM="10.11"            # minimo aceitavel: 10.11
ZBX_RELEASE_RPM="https://repo.zabbix.com/zabbix/8.0/release/rhel/9/noarch/zabbix-release-latest.el9.noarch.rpm"
PROXY_CONF="/etc/zabbix/zabbix_proxy.conf"
PROXY_LOG="/var/log/zabbix/zabbix_proxy.log"

MODE="run"
case "${1:-}" in --check) MODE="check";; --yes) MODE="yes";; esac

LOG_FILE="/root/upgrade-proxy-$(date +%Y-%m-%d_%H%M).log"
exec > >(tee -a "$LOG_FILE") 2>&1

c_reset=$'\e[0m'; c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_blu=$'\e[36m'
log(){ echo "${c_blu}[$(date +%H:%M:%S)]${c_reset} $*"; }
ok(){ echo "${c_grn}[ OK ]${c_reset} $*"; }
warn(){ echo "${c_ylw}[AVISO]${c_reset} $*"; }
die(){ echo "${c_red}[ERRO]${c_reset} $*"; echo "${c_red}>>> ABORTADO. Restaure o SNAPSHOT do proxy. Log: $LOG_FILE${c_reset}"; exit 1; }
trap 'die "Falha inesperada na linha $LINENO."' ERR
confirm(){ local m="$1"; [[ "$MODE" == "yes" ]] && { log "[--yes] pulando: $m"; return 0; }; echo; echo "${c_ylw}>>> $m${c_reset}"; read -r -p "    Digite 'sim' para continuar: " r; [[ "$r" == "sim" ]] || die "Confirmacao negada."; }

# conecta na MariaDB: usa senha se preenchida, senao tenta socket (root)
mysql_root(){
  if [[ -n "$MARIADB_ROOT_PASSWORD" && "$MARIADB_ROOT_PASSWORD" != "__PREENCHER_SENHA_ROOT_MARIADB__" ]]; then
    mysql -u root -p"${MARIADB_ROOT_PASSWORD}" "$@"
  else
    mysql -u root "$@"
  fi
}

echo "================================================================"
echo " ZABBIX PROXY  |  MariaDB ->${MARIADB_TARGET_MM} + proxy 7.4 -> 8.0"
echo " host: $(hostname)  |  modo: $MODE  |  $(date)"
echo " Log: $LOG_FILE"
echo "================================================================"

#============================ FASE 0 - PRE-FLIGHT ============================
log "FASE 0 - Pre-flight (somente leitura)"
[[ $EUID -eq 0 ]] || die "Rode como root."
grep -qiE 'Oracle Linux|AlmaLinux|Red Hat|Rocky' /etc/os-release || die "SO nao e EL9 compativel."
. /etc/os-release; [[ "${VERSION_ID%%.*}" == "9" ]] || die "Script para EL9. Detectado: $VERSION_ID (hosts EL8 serao tratados a parte)."
ok "SO: $NAME $VERSION_ID"
for b in dnf rpm systemctl mysql; do command -v "$b" >/dev/null || die "Faltou comando: $b"; done

[[ -f "$PROXY_CONF" ]] || die "Nao achei $PROXY_CONF (este host e proxy mesmo?)."
PBUFMODE="$(grep -E '^ProxyBufferMode=' "$PROXY_CONF" | cut -d= -f2 || true)"
ok "ProxyBufferMode=${PBUFMODE:-nao-definido}  DBName=$(grep -E '^DBName=' "$PROXY_CONF"|cut -d= -f2)"

# versao atual da MariaDB
MDB_VER="$(mysql_root -N -B -e 'SELECT VERSION();' 2>/dev/null | head -1)" || die "Sem conexao na MariaDB (ajuste MARIADB_ROOT_PASSWORD ou verifique auth socket)."
MDB_MM="$(echo "$MDB_VER" | grep -oE '^[0-9]+\.[0-9]+')"
ok "MariaDB atual: $MDB_VER (serie $MDB_MM)"

command -v zabbix_proxy >/dev/null && ok "Zabbix proxy atual: $(zabbix_proxy -V | head -1)" || die "zabbix_proxy nao instalado aqui."

# modulo mariadb 10.11 disponivel?
if ! dnf module list mariadb 2>/dev/null | grep -qE '10\.11'; then
  warn "Modulo mariadb:10.11 nao apareceu no AppStream. Confira 'dnf module list mariadb'."
fi

if [[ "$MODE" == "check" ]]; then echo; ok "DRY-RUN concluido. Nada alterado."; exit 0; fi

# precisa atualizar a MariaDB?
NEED_MDB="no"
# compara 10.5 < 10.11 numericamente (major.minor)
awk "BEGIN{exit !($MDB_MM < $MARIADB_TARGET_MM)}" && NEED_MDB="yes" || true
if [[ "$NEED_MDB" == "yes" ]]; then
  warn "MariaDB $MDB_VER NAO e suportada pelo Zabbix 8.0 (exige >= ${MARIADB_TARGET_MM}). Sera atualizada."
else
  ok "MariaDB $MDB_VER ja atende o Zabbix 8.0 (>= ${MARIADB_TARGET_MM})."
fi

echo "----------------------------------------------------------------"
echo " PLANO: (se preciso) MariaDB ${MDB_MM} -> ${MARIADB_TARGET_MM} -> proxy 7.4 -> 8.0"
echo "----------------------------------------------------------------"
confirm "VOCE JA TIROU O SNAPSHOT deste proxy?"

#============================ FASE 1 - PARAR SERVICOS =======================
log "FASE 1 - Parar proxy e agent2"
systemctl stop zabbix-proxy  2>/dev/null && ok "zabbix-proxy parado." || true
systemctl stop zabbix-agent2 2>/dev/null && ok "zabbix-agent2 parado." || true

BKP="/opt/zabbix-proxy-backup-$(date +%Y-%m-%d_%H%M)"; mkdir -p "$BKP"
cp -a /etc/zabbix "$BKP/" 2>/dev/null || true
rpm -qa | grep -E '^(zabbix|mariadb)' | sort > "$BKP/pacotes-antes.txt" || true
ok "Backup de configs: $BKP"

#============================ FASE 2 - MARIADB 10.5 -> 10.11 =================
if [[ "$NEED_MDB" == "yes" ]]; then
  log "FASE 2 - MariaDB ${MDB_MM} -> ${MARIADB_TARGET_MM} (modulo AppStream)"
  systemctl stop mariadb
  dnf -y module reset mariadb
  dnf -y module enable "$MARIADB_TARGET_STREAM"
  dnf -y distro-sync
  systemctl start mariadb
  sleep 5
  systemctl is-active --quiet mariadb || { journalctl -u mariadb -n 30 --no-pager; die "mariadb nao subiu apos distro-sync."; }
  # mariadb-upgrade aplica ajustes de tabelas de sistema entre series
  log "Rodando mariadb-upgrade..."
  if [[ -n "$MARIADB_ROOT_PASSWORD" && "$MARIADB_ROOT_PASSWORD" != "__PREENCHER_SENHA_ROOT_MARIADB__" ]]; then
    mariadb-upgrade -u root -p"${MARIADB_ROOT_PASSWORD}" || mysql_upgrade -u root -p"${MARIADB_ROOT_PASSWORD}" || warn "mariadb-upgrade retornou aviso."
  else
    mariadb-upgrade -u root || mysql_upgrade -u root || warn "mariadb-upgrade retornou aviso."
  fi
  MDB_VER="$(mysql_root -N -B -e 'SELECT VERSION();' | head -1)"
  MDB_MM="$(echo "$MDB_VER" | grep -oE '^[0-9]+\.[0-9]+')"
  awk "BEGIN{exit !($MDB_MM >= $MARIADB_TARGET_MM)}" || die "MariaDB ainda em $MDB_VER (esperado >= ${MARIADB_TARGET_MM})."
  ok "MariaDB agora: $MDB_VER"
else
  log "FASE 2 - PULADA (MariaDB ja >= ${MARIADB_TARGET_MM})."
fi

#============================ FASE 3 - PROXY 7.4 -> 8.0 =====================
log "FASE 3 - zabbix-proxy + agent2 7.4 -> 8.0"
rpm -Uvh --force "$ZBX_RELEASE_RPM"; dnf clean all

# com ProxyBufferMode=disk, ProxyMemoryBuffer* IMPEDE o start -> comentar se existirem ativos
if [[ "${PBUFMODE,,}" == "disk" ]]; then
  if grep -qE '^[[:space:]]*ProxyMemoryBuffer(Size|Age)=' "$PROXY_CONF"; then
    warn "ProxyBufferMode=disk + ProxyMemoryBuffer* ativo -> comentando essas linhas (senao o proxy nao inicia)."
    sed -i -E 's/^([[:space:]]*ProxyMemoryBuffer(Size|Age)=)/#\1/' "$PROXY_CONF"
  fi
fi

echo; log "Previa da transacao (confira 8.0.x):"
echo "----------------------------------------------------------------"
dnf --assumeno install zabbix-proxy-mysql zabbix-sql-scripts zabbix-selinux-policy zabbix-agent2 'zabbix-agent2-plugin-*' || true
echo "----------------------------------------------------------------"
confirm "Confirma o 'dnf install' do proxy/agent2 8.0 acima?"
dnf -y install zabbix-proxy-mysql zabbix-sql-scripts zabbix-selinux-policy zabbix-agent2 'zabbix-agent2-plugin-*'
ok "Pacotes do proxy 8.0 instalados."

#============================ FASE 4 - START + VALIDACAO ====================
log "FASE 4 - Subindo proxy (o schema do proxy e migrado no 1o start)"
systemctl daemon-reload || true
systemctl start zabbix-proxy
sleep 8
if systemctl is-active --quiet zabbix-proxy; then
  ok "zabbix-proxy ativo."
else
  journalctl -u zabbix-proxy -n 20 --no-pager
  tail -40 "$PROXY_LOG" 2>/dev/null || true
  die "zabbix-proxy NAO subiu. Veja o log acima (schema? ProxyMemoryBuffer*? binario mysql vs sqlite?)."
fi
systemctl start zabbix-agent2 && ok "zabbix-agent2 iniciado." || warn "falha ao subir agent2."

echo "----------------------------------------------------------------"
echo "MariaDB       : $(mysql_root -N -B -e 'SELECT VERSION();' | head -1)"
echo "zabbix_proxy  : $(zabbix_proxy -V | head -1)"
echo "Servicos      :"; systemctl is-active mariadb zabbix-proxy zabbix-agent2
echo "Ultimas linhas do proxy:"; tail -8 "$PROXY_LOG" 2>/dev/null || true
echo "----------------------------------------------------------------"
ok "Proxy concluido. Backup: $BKP"
echo "${c_ylw}>>> Confira no server (APP01) se o proxy voltou a comunicar (Administration > Proxies).${c_reset}"
echo "${c_ylw}>>> LEMBRETE: remover a senha chumbada e migrar para env/.my.cnf (etapa 2).${c_reset}"
