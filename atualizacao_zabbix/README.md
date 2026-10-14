# Atualização Zabbix 7.4 → 8.0 (Oracle Linux / AlmaLinux 9)

Scripts de upgrade do parque Zabbix para a versão **8.0 LTS**, incluindo o
upgrade dos bancos de dados exigidos pela 8.0:

- **MySQL** 8.0 → **8.4 LTS** (requisito do Zabbix 8.0: MySQL 8.4.0–9.7.x)
- **MariaDB** 10.5 → **10.11 LTS** (requisito do Zabbix 8.0: MariaDB 10.11–12.3.x)
- **PHP** 8.0 → **8.2** (requisito do frontend 8.0: PHP 8.2–8.5)

Todos os upgrades de banco/PHP usam **módulos do AppStream** (`dnf module`),
que é o método nativo do EL9 e não corre risco de pular para versões
*innovation* (ex.: MySQL 9.x).

> ⚠️ **Somente EL9.** Hosts EL8 devem ser tratados à parte (repositório
> `.../rhel/8/...` e versões diferentes de PHP/MySQL/MariaDB no AppStream).

---

## Arquitetura alvo (parque de produção)

| Host             | Papel                         | Componentes                                  |
|------------------|-------------------------------|----------------------------------------------|
| **BD**  (ex. DC02SPMONBD01)  | Banco                 | `mysql-server` + `zabbix-agent2`             |
| **APP** (ex. DC02SPMONAPP01) | Server + Frontend     | `zabbix-server` + `zabbix-web` + Apache/PHP  |
| **PROXY** (ex. DC02SPMON001) | Proxy                 | `zabbix-proxy-mysql` + MariaDB + `zabbix-agent2` |

O banco é **remoto** para o APP (`DBHost` aponta para o IP do BD). Ambiente
**não-HA** (`HANodeName` vazio).

---

## Ordem de execução (OBRIGATÓRIA — mesma janela de manutenção)

```
1. APP : systemctl stop zabbix-server        # congela a escrita no banco
2. BD  : ./upgrade-db-el9.sh                  # MySQL 8.0 -> 8.4 (+ dump) + agent2 -> 8.0
3. APP : ./upgrade-app-el9.sh                 # server+web 7.4 -> 8.0 (MIGRA O SCHEMA) + PHP 8.2
4. PROXY (cada um): ./upgrade-proxy-el9.sh    # MariaDB 10.5 -> 10.11 + proxy 7.4 -> 8.0
```

Observações importantes:

- O **schema do banco do Zabbix é migrado no passo 3**, quando o `zabbix-server`
  8.0 sobe pela primeira vez — **não** no passo 2. Por isso o BD vai primeiro
  (só troca a engine), mas quem mexe no schema é o server no APP.
- `server` e `proxy` **devem ser a mesma major**. Durante a janela, um server
  8.0 não comunica com proxies 7.4; atualize os proxies na mesma janela.

---

## Scripts

| Script                   | Host  | Resumo                                                                 |
|--------------------------|-------|------------------------------------------------------------------------|
| `upgrade-db-el9.sh`      | BD    | Dump obrigatório → MySQL 8.0→8.4 (AppStream) → agent2→8.0. Trava anti dois-servers. |
| `upgrade-app-el9.sh`     | APP   | Testa alcance ao banco remoto e exige MySQL já em 8.4 → PHP 8.0→8.2 → server+web 7.4→8.0 → migra schema. |
| `upgrade-proxy-el9.sh`   | PROXY | MariaDB 10.5→10.11 (crítico!) → proxy+agent2 7.4→8.0. Trata `ProxyBufferMode=disk` vs `ProxyMemoryBuffer*`. |

### Características comuns

- **Sem senha no código.** As senhas ficam em placeholders `__PREENCHER_*__` no
  topo de cada script; preencha **antes** de executar. O script **aborta** se o
  placeholder não for substituído.
- **`--check` (dry-run).** Roda apenas o pré-flight (distro, conexão ao banco,
  versões, alcance de rede) **sem alterar nada**. Use antes da janela.
- **Idempotente.** Pula o bloco de MySQL/MariaDB/PHP se já estiver na versão alvo.
- **Aborta em qualquer erro** (`set -Eeuo pipefail` + trap) e sempre aponta o
  snapshot como recuperação.
- **Log por host** em `/root/upgrade-*-AAAA-MM-DD_HHMM.log`.

---

## Uso

```bash
chmod +x upgrade-*.sh

# 1) VALIDE primeiro, fora da janela (não altera nada):
./upgrade-db-el9.sh --check
./upgrade-app-el9.sh --check
./upgrade-proxy-el9.sh --check

# 2) Preencha as senhas nos placeholders __PREENCHER_*__ do script correspondente

# 3) Na janela, na ordem acima:
./upgrade-db-el9.sh            # pede confirmação de snapshot e da transação dnf
#   ou  ./upgrade-db-el9.sh --yes   (sem perguntas)
```

Mantenha uma **segunda sessão SSH** com `tail -f /var/log/zabbix/zabbix_server.log`
(no APP) durante a migração de schema.

---

## Recuperação (rollback)

- **MySQL 8.4 e MariaDB 10.11 NÃO permitem downgrade.** A volta é **restaurar o
  snapshot da VM**.
- O `upgrade-db-el9.sh` ainda gera um **dump** (`/root/zabbix_pre-upgrade_*.sql`)
  como rede extra: pode ser reimportado em um MySQL 8.0 limpo.

---

## Pontos de atenção

1. **PHP** — o passo `dnf module reset/enable/install php:8.2` é o mais sensível a
   variações de ambiente; acompanhe o log.
2. **`log_bin_trust_function_creators`** — o `upgrade-app-el9.sh` tenta ligar essa
   variável no banco remoto durante a migração de schema. Se o usuário `zabbix`
   não tiver `SUPER`, ligue manualmente no **BD**:
   `SET GLOBAL log_bin_trust_function_creators=1;`
3. **Proxy com `ProxyBufferMode=disk`** — `ProxyMemoryBufferSize/Age` ativos
   impedem o proxy de iniciar; o script comenta essas linhas automaticamente.
4. **Root da MariaDB via socket** — se a root da MariaDB do proxy usa
   `unix_socket`, deixe `MARIADB_ROOT_PASSWORD=""` que o script conecta via socket.

---

## Etapa 2 — remover senhas dos scripts (pós-upgrade)

Depois do upgrade, migre a autenticação para fora do script:

```ini
# /root/.my.cnf  (chmod 600)
[client]
user=root
password=SUA_SENHA
```

e ajuste a função `mysql_root()` para usar apenas `mysql "$@"` (há um comentário
indicando o ponto exato em cada script). **Nunca** versione os scripts com a
senha real preenchida.
