#!/usr/bin/env bash
#===============================================================================
# upgrade-app-el9.sh   -   HOST: App + Frontend (ex.: DC02SPMONAPP01)
#
# Papel do host: zabbix-server + zabbix-web (Apache/httpd) + PHP.
#   O banco e REMOTO (DBHost=172.22.3.3). Nao-HA (HANodeName vazio).
#
# O que faz:
#   1) Testa ALCANCE ao banco remoto e confirma que ja esta em MySQL 8.4
#   2) Backup de /etc/zabbix, zabbix.conf, PHP
#   3) Repo Zabbix 8.0 + PHP 8.0 -> 8.2
#   4) zabbix-server-mysql + zabbix-web-mysql + apache-conf -> 8.0
#   5) Sobe o server -> MIGRA O SCHEMA do banco (acontece AQUI, nao no DB host)
#
# PRE-REQUISITO: rodar ANTES o ./upgrade-db-el9.sh no DB (MySQL ja em 8.4).
#
# ORDEM NA JANELA:
#   1. APP01 : systemctl stop zabbix-server
#   2. BD01  : ./upgrade-db-el9.sh
#   3. APP01 : ./upgrade-app-el9.sh   <<< ESTE SCRIPT
#   4. Proxy : ./upgrade-proxy-el9.sh
#
# ROLLBACK: restaurar SNAPSHOT do APP e do DB (o schema migrado nao volta).
#
# Uso:
#   ./upgrade-app-el9.sh --check   # dry-run
#   ./upgrade-app-el9.sh           # executa
#   ./upgrade-app-el9.sh --yes     # sem perguntas
#===============================================================================

set -Eeuo pipefail

#############################  SENHAS (PREENCHER)  #############################
#  >>> Senha do usuario 'zabbix' do MySQL (o DBPassword do zabbix_server.conf). <<<
#  >>> So e usada aqui para TESTAR a conexao ao banco remoto antes do upgrade.  <<<
ZABBIX_DB_PASSWORD="__PREENCHER_SENHA_ZABBIX__"
###############################################################################

PHP_TARGET_STREAM="php:8.2"
ZBX_TARGET_MAJOR="8.0"
ZBX_RELEASE_RPM="https://repo.zabbix.com/zabbix/8.0/release/rhel/9/noarch/zabbix-release-latest.el9.noarch.rpm"
ZBX_CONF="/etc/zabbix/zabbix_server.conf"
ZBX_LOG="/var/log/zabbix/zabbix_server.log"

MODE="run"
case "${1:-}" in --check) MODE="check";; --yes) MODE="yes";; esac

LOG_FILE="/root/upgrade-app-$(date +%Y-%m-%d_%H%M).log"
exec > >(tee -a "$LOG_FILE") 2>&1

c_reset=$'\e[0m'; c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_blu=$'\e[36m'
log(){ echo "${c_blu}[$(date +%H:%M:%S)]${c_reset} $*"; }
ok(){ echo "${c_grn}[ OK ]${c_reset} $*"; }
warn(){ echo "${c_ylw}[AVISO]${c_reset} $*"; }
die(){ echo "${c_red}[ERRO]${c_reset} $*"; echo "${c_red}>>> ABORTADO. Restaure os SNAPSHOTs (APP e DB) se o schema ja foi tocado. Log: $LOG_FILE${c_reset}"; exit 1; }
trap 'die "Falha inesperada na linha $LINENO."' ERR
confirm(){ local m="$1"; [[ "$MODE" == "yes" ]] && { log "[--yes] pulando: $m"; return 0; }; echo; echo "${c_ylw}>>> $m${c_reset}"; read -r -p "    Digite 'sim' para continuar: " r; [[ "$r" == "sim" ]] || die "Confirmacao negada."; }

echo "================================================================"
echo " APP+FRONTEND  |  Zabbix 7.4 -> ${ZBX_TARGET_MAJOR} + PHP -> 8.2"
echo " host: $(hostname)  |  modo: $MODE  |  $(date)"
echo " Log: $LOG_FILE"
echo "================================================================"

#============================ FASE 0 - PRE-FLIGHT ============================
log "FASE 0 - Pre-flight (somente leitura)"
[[ $EUID -eq 0 ]] || die "Rode como root."
[[ "$ZABBIX_DB_PASSWORD" != "__PREENCHER_SENHA_ZABBIX__" ]] || die "Preencha ZABBIX_DB_PASSWORD no topo do script."
grep -qiE 'Oracle Linux|AlmaLinux|Red Hat|Rocky' /etc/os-release || die "SO nao e EL9 compativel."
. /etc/os-release; [[ "${VERSION_ID%%.*}" == "9" ]] || die "Script para EL9. Detectado: $VERSION_ID"
ok "SO: $NAME $VERSION_ID"
for b in dnf rpm systemctl mysql; do command -v "$b" >/dev/null || die "Faltou comando: $b"; done

[[ -f "$ZBX_CONF" ]] || die "Nao achei $ZBX_CONF (este host e o server mesmo?)."
DBHOST="$(grep -E '^DBHost=' "$ZBX_CONF" | cut -d= -f2)"
DBNAME="$(grep -E '^DBName=' "$ZBX_CONF" | cut -d= -f2)"
DBUSER="$(grep -E '^DBUser=' "$ZBX_CONF" | cut -d= -f2)"
HANODE="$(grep -E '^HANodeName=' "$ZBX_CONF" | cut -d= -f2 || true)"
ok "Config server: DBHost=$DBHOST DBName=$DBNAME DBUser=$DBUSER HANodeName='${HANODE:-}'"
[[ -z "${HANODE:-}" ]] || warn "HANodeName definido ('$HANODE'): ambiente pode ser HA. Confirme que TODOS os nos server estao parados antes de migrar o schema."

command -v zabbix_server >/dev/null && ok "Zabbix server atual: $(zabbix_server -V | head -1)" || die "zabbix_server nao instalado aqui."

# testa alcance + versao do banco REMOTO (o upgrade do app exige MySQL ja em 8.4)
log "Testando conexao ao banco remoto $DBHOST ..."
REMOTE_VER="$(mysql -h "$DBHOST" -u "$DBUSER" -p"${ZABBIX_DB_PASSWORD}" "$DBNAME" -N -B -e 'SELECT VERSION();' 2>/dev/null | head -1)" \
  || die "Nao conectei em $DBHOST como $DBUSER. (rede/firewall/senha/GRANT?) Resolva antes."
ok "Banco remoto responde: $REMOTE_VER"
case "$REMOTE_VER" in
  8.4.*|9.*) ok "Banco remoto compativel com Zabbix 8.0 ($REMOTE_VER)." ;;
  8.0.*) die "Banco remoto ainda em $REMOTE_VER. Rode ./upgrade-db-el9.sh no DB ($DBHOST) ANTES deste." ;;
  *) warn "Versao de banco inesperada: $REMOTE_VER (siga com atencao)." ;;
esac

PHP_CUR="$(rpm -q --qf '%{VERSION}' php-common 2>/dev/null || echo ausente)"
ok "PHP atual: $PHP_CUR"
FE="apache"; systemctl is-active --quiet httpd || warn "httpd nao esta ativo (frontend Apache)."
ok "Frontend: Apache (httpd)"

if [[ "$MODE" == "check" ]]; then echo; ok "DRY-RUN concluido. Nada alterado."; exit 0; fi

echo "----------------------------------------------------------------"
echo " PLANO: backup -> repo 8.0 -> PHP 8.2 -> install server/web 8.0 -> MIGRA SCHEMA"
echo "----------------------------------------------------------------"
confirm "VOCE JA TIROU O SNAPSHOT do APP (e o DB ja esta em 8.4)?"

#============================ FASE 1 - PARAR + BACKUP =======================
log "FASE 1 - Parar servicos e backup de configs"
systemctl stop zabbix-server 2>/dev/null && ok "zabbix-server parado." || true
systemctl stop httpd         2>/dev/null && ok "httpd parado." || true
BKP="/opt/zabbix-backup-$(date +%Y-%m-%d_%H%M)"; mkdir -p "$BKP"
cp -a /etc/zabbix "$BKP/" 2>/dev/null || true
cp -a /etc/httpd/conf.d/zabbix.conf "$BKP/" 2>/dev/null || true
cp -a /etc/php.ini /etc/php.d "$BKP/" 2>/dev/null || true
cp -a /usr/share/zabbix "$BKP/" 2>/dev/null || true
rpm -qa | grep -E '^(zabbix|php|httpd)' | sort > "$BKP/pacotes-antes.txt" || true
ok "Backup de configs: $BKP"

#============================ FASE 2 - REPO + PHP + PACOTES ==================
log "FASE 2 - Repo Zabbix 8.0 + PHP + pacotes"
rpm -Uvh --force "$ZBX_RELEASE_RPM"; dnf clean all; ok "Repo Zabbix 8.0 configurado."

PHP_MM="$(rpm -q --qf '%{VERSION}' php-common 2>/dev/null | cut -d. -f1,2 || echo 0.0)"
case "$PHP_MM" in
  8.2|8.3|8.4|8.5) ok "PHP ja em $PHP_MM; sem troca." ;;
  *) log "Migrando PHP $PHP_MM -> ${PHP_TARGET_STREAM}..."
     dnf -y module reset php
     dnf -y module enable "$PHP_TARGET_STREAM"
     dnf -y module install "$PHP_TARGET_STREAM"
     dnf -y install php-mysqlnd php-bcmath php-gd php-mbstring php-xml php-ldap php-fpm
     ok "PHP migrado: $(rpm -q --qf '%{VERSION}\n' php-common | head -1)" ;;
esac

# prepara o banco remoto para o upgrade de schema (funcoes/triggers)
log "Habilitando log_bin_trust_function_creators no banco remoto durante o upgrade..."
mysql -h "$DBHOST" -u "$DBUSER" -p"${ZABBIX_DB_PASSWORD}" -e "SET GLOBAL log_bin_trust_function_creators=1;" 2>/dev/null \
  || warn "nao consegui setar a variavel remota (o usuario 'zabbix' pode nao ter SUPER). Se o upgrade do schema falhar criando funcao, ligue no DB: SET GLOBAL log_bin_trust_function_creators=1;"

ZBX_PKGS="zabbix-server-mysql zabbix-web-mysql zabbix-apache-conf zabbix-sql-scripts zabbix-selinux-policy"
echo; log "Previa da transacao (confira ${ZBX_TARGET_MAJOR}.x):"
echo "----------------------------------------------------------------"
dnf --assumeno install $ZBX_PKGS || true
echo "----------------------------------------------------------------"
confirm "Confirma o 'dnf install' dos pacotes Zabbix ${ZBX_TARGET_MAJOR} acima?"
dnf -y install $ZBX_PKGS
ok "Pacotes Zabbix ${ZBX_TARGET_MAJOR} instalados."

#============================ FASE 3 - START + MIGRA SCHEMA ==================
log "FASE 3 - Subindo zabbix-server (migracao de schema no 1o start; NAO interrompa)"
systemctl daemon-reload || true
systemctl start zabbix-server
DEADLINE=$(( $(date +%s) + 900 ))   # ate 15 min (banco de prod pode ser grande)
MIG="no"
while [[ $(date +%s) -lt $DEADLINE ]]; do
  grep -qiE 'database upgrade fully completed|current database version matches required' "$ZBX_LOG" 2>/dev/null && { MIG="ok"; break; }
  grep -qiE 'database upgrade failed|cannot upgrade database|\[Z3005\]|\[Z3002\]'          "$ZBX_LOG" 2>/dev/null && { MIG="fail"; break; }
  sleep 5
done
case "$MIG" in
  ok)   ok "Migracao de schema concluida." ;;
  fail) tail -50 "$ZBX_LOG"; die "Migracao de schema FALHOU (ver log). Restaure SNAPSHOTs do APP e do DB." ;;
  *)    warn "Nao confirmei a conclusao em 15 min. Verifique manualmente:"; tail -50 "$ZBX_LOG" ;;
esac
systemctl restart httpd && ok "httpd reiniciado." || warn "falha no httpd."

#============================ VALIDACAO FINAL ===============================
log "VALIDACAO FINAL"
echo "----------------------------------------------------------------"
echo "zabbix_server : $(zabbix_server -V | head -1)"
echo "PHP           : $(php -v 2>/dev/null | head -1 || echo 'cli ausente')"
echo "dbversion     :"; mysql -h "$DBHOST" -u "$DBUSER" -p"${ZABBIX_DB_PASSWORD}" "$DBNAME" -e "SELECT mandatory,optional FROM dbversion;" 2>/dev/null || warn "nao li dbversion."
echo "Servicos      :"; systemctl is-active zabbix-server httpd
echo "----------------------------------------------------------------"
# desliga a variavel ligada so para o upgrade
mysql -h "$DBHOST" -u "$DBUSER" -p"${ZABBIX_DB_PASSWORD}" -e "SET GLOBAL log_bin_trust_function_creators=0;" 2>/dev/null || true
ok "App/Frontend concluido. Backup: $BKP"
echo "${c_ylw}>>> Navegador: limpe COOKIES e CACHE e abra o frontend (deve mostrar ${ZBX_TARGET_MAJOR}).${c_reset}"
echo "${c_ylw}>>> PROXIMO: rodar ./upgrade-proxy-el9.sh em cada proxy EL9.${c_reset}"
echo "${c_ylw}>>> LEMBRETE: remover a senha chumbada e migrar para env/.my.cnf (etapa 2).${c_reset}"
