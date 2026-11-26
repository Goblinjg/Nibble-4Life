#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ${1:-} == --help ]]; then
  cat <<'USO'
Uso: bash scripts/demo-parte4.sh [--subir]
  --subir      Gera o .env se necessário e executa docker compose up -d --build.
  SEM_PAUSA=1  Executa sem pausas e pula os cenários opcionais de indisponibilidade.
  BASE_URL     URL do gateway. Padrão: http://localhost:8080.
  MODO=k8s     Usa Kubernetes. INGRESS_IP permite resolver o host 4life.test.
USO
  exit 0
fi

MODO="${MODO:-compose}"
if [[ $MODO == k8s ]]; then BASE="${BASE_URL:-http://4life.test}"; else BASE="${BASE_URL:-http://localhost:${GATEWAY_PORT:-8080}}"; fi
RESOLVE=()
if [[ -n ${INGRESS_IP:-} ]]; then HOST=${BASE#*://}; HOST=${HOST%%/*}; RESOLVE=(--resolve "${HOST}:80:${INGRESS_IP}"); fi

titulo() { printf '\n\033[1;35m━━ %s\033[0m\n' "$*"; }
passo()  { printf '\033[1;34m▸ %s\033[0m\n' "$*"; }
info()   { printf '  %s\n' "$*"; }
pausa()  { [[ ! -t 0 || -n ${SEM_PAUSA:-} ]] || read -rp $'\n  [Enter para continuar] ' _; }
pergunta_sn() { local r; [[ ! -t 0 || -n ${SEM_PAUSA:-} ]] && return 1; read -rp "  $1 [s/N] " r; [[ $r == [sS] ]]; }
api()    { curl -fsS --connect-timeout 5 --max-time 180 "${RESOLVE[@]}" "$@"; }
json()   { api -H 'content-type: application/json' "$@"; }

falha() { printf '  ERRO: %s\n' "$*" >&2; exit 1; }
status_http() { curl -sS --connect-timeout 5 --max-time 30 "${RESOLVE[@]}" -o /dev/null -w '%{http_code}' "$@"; }
uuid() { jq -er "$1 | strings | select(test(\"^[0-9a-fA-F-]{36}$\"))"; }

# parar/iniciar um componente (compose ou k8s)
parar() {
  if [[ $MODO == k8s ]]; then kubectl -n 4life scale deployment "$1" --replicas=0 > /dev/null
  else docker compose stop "$1" > /dev/null 2>&1; fi
}
iniciar() {
  if [[ $MODO == k8s ]]; then kubectl -n 4life scale deployment "$1" --replicas="${2:-1}" > /dev/null && kubectl -n 4life rollout status deployment "$1" --timeout=120s > /dev/null
  else docker compose start "$1" > /dev/null 2>&1; fi
}
psql_em() { # banco, SQL e opções de psql
  local banco=$1 sql=$2
  shift 2
  if [[ $MODO == k8s ]]; then kubectl -n 4life exec "$banco-db-0" -- psql -X -v ON_ERROR_STOP=1 -U "$banco" -d "$banco" "$@" -c "$sql"
  else docker compose exec -T "$banco-db" psql -X -v ON_ERROR_STOP=1 -U "$banco" -d "$banco" "$@" -c "$sql"; fi
}

interromper() {
  if [[ $MODO == k8s ]]; then
    replicas_originais=$(kubectl -n 4life get deployment "$1" -o 'jsonpath={.spec.replicas}')
  fi
  componente_parado=$1
  parar "$1"
}

componente_parado=
replicas_originais=1
restaurar() {
  if [[ -n $componente_parado ]]; then
    printf '\nRestaurando %s…\n' "$componente_parado" >&2
    iniciar "$componente_parado" "$replicas_originais" || return 1
    componente_parado=
  fi
}
trap restaurar EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

saga() {
  local consulta estado anterior= detalhe i
  for ((i=0; i<120; i++)); do
    consulta=$(api "$BASE/api/web/mobilizacoes/$1/saga" -H "$AUTH")
    estado=$(jq -er .estado <<< "$consulta")
    detalhe=$(jq -r '"\(.estado) / passo \(.passo)"' <<< "$consulta")
    if [[ $detalhe != "$anterior" ]]; then info "$detalhe"; anterior=$detalhe; fi
    [[ $estado == CONCLUIDA || $estado == COMPENSADA || $estado == FALHOU ]] && break
    sleep 0.5
  done
  jq -r '.historico[] | "    \(.em)  \(.etapa)  \(.descricao)"' <<< "$consulta"
  api "$BASE/api/web/mobilizacoes/$1" -H "$AUTH" | jq -r '"  mobilização: \(.estado)\(if .motivoCancelamento then " — " + .motivoCancelamento else "" end)"'
  [[ $estado == "$2" ]] || falha "saga $1: esperado $2, observado $estado"
}

evidencias_saga() {
  local banco
  passo "Outbox dos três participantes — tipo, ID e confirmação do RabbitMQ"
  for banco in mobilizacoes comunidades informacoes; do
    info "$banco-db"
    psql_em "$banco" "SELECT tipo, id AS evento_id, publicado_em
      FROM outbox WHERE agregado_id IN ('$1', '$2') ORDER BY criado_em"
  done
  if [[ $MODO == compose ]]; then
    passo "Logs dos containers para a saga $1"
    docker compose logs --no-color mobilizacoes-service comunidades-service informacoes-service |
      awk -v saga="$1" 'index($0, saga) && /"sagaId"/ { print }'
  fi
}

for cmd in curl jq; do
  command -v "$cmd" >/dev/null || falha "instale $cmd para executar a demonstração"
done
case "$MODO" in
  compose) docker compose version >/dev/null || falha "Docker Compose v2 é necessário" ;;
  k8s) command -v kubectl >/dev/null || falha "kubectl é necessário" ;;
  *) falha "MODO deve ser compose ou k8s" ;;
esac
case "${1:-}" in
  --subir)
    [[ $MODO == compose ]] || falha "--subir está disponível no Compose"
    [[ -f .env ]] || bash scripts/gerar-env.sh
    docker compose up -d --build
    ;;
  '') ;;
  *) falha "opção desconhecida: $1 (veja --help)" ;;
esac

titulo "0. Infraestrutura e comunicação"
if [[ $MODO == compose ]]; then
  docker compose ps -a
  if [[ -z ${BASE_URL:-} ]]; then
    porta_publicada=$(docker compose port gateway 8080)
    BASE="http://localhost:${porta_publicada##*:}"
  fi
else
  kubectl -n 4life get pods,svc
fi
for ((i=0; i<60; i++)); do
  gateway=$(curl -fsS --max-time 3 "${RESOLVE[@]}" "$BASE/health" 2>/dev/null) && break
  sleep 2
done
jq -e '.status == "ok"' <<< "${gateway:-}" >/dev/null || falha "gateway indisponível em $BASE"
jq -c . <<< "$gateway"
if [[ $MODO == compose ]]; then
  bash scripts/teste-isolamento.sh
  passo "RabbitMQ — filas, mensagens pendentes e consumidores"
  docker compose exec -T rabbitmq rabbitmqctl list_queues name messages_ready messages_unacknowledged consumers
fi
passo "Rota pública via BFF mobile → informações"
api "$BASE/api/mobile/info/faq" | jq '{total: length, exemplo: .[0]}'
codigo=$(status_http "$BASE/api/web/painel")
[[ $codigo == 401 ]] || falha "painel sem JWT respondeu HTTP $codigo (esperado 401)"
info "GET /api/web/painel sem JWT → HTTP $codigo"
pausa

HEMO_LAVRAS=33333333-3333-4333-8333-333333333331
# Consulta o banco para escolher dois dias livres, inclusive se a demo já rodou antes.
DATAS=$(psql_em informacoes "
  SELECT d::date FROM generate_series(CURRENT_DATE + 60, CURRENT_DATE + 730, '1 day') d
  WHERE NOT EXISTS (SELECT FROM reservas_hemocentro
    WHERE hemocentro_id = '$HEMO_LAVRAS' AND data = d::date)
  ORDER BY random() LIMIT 2" -At)
DIA=$(sed -n '1p' <<< "$DATAS")
DIA2=$(sed -n '2p' <<< "$DATAS")
[[ -n $DIA && -n $DIA2 ]] || falha "não encontrei duas datas livres para a demonstração"
DEMO_ID="$(date +%s)-$RANDOM"

titulo "1. Fluxo ponta a ponta: cliente → Ingress/gateway → BFF → serviços de domínio ($MODO, $BASE)"
EMAIL="demo-$(date +%s)-$RANDOM@4life.local"
passo "cadastro (POST /api/web/cadastro → bff-web → doadores-service)"
json "$BASE/api/web/cadastro" -d "{\"nome\":\"Demo Parte 4\",\"email\":\"$EMAIL\",\"senha\":\"senha-demo-123\",\"cidade\":\"Lavras\",\"uf\":\"MG\",\"tipoSanguineo\":\"O-\"}" | jq -c '{id, nome, email}'
passo "login (POST /auth/login → gateway assina o JWT)"
TOKEN=$(json "$BASE/auth/login" -d "{\"email\":\"$EMAIL\",\"senha\":\"senha-demo-123\"}" | jq -er '.token | strings | select(length > 0)')
AUTH="authorization: Bearer $TOKEN"; info "JWT emitido"
passo "criar comunidade (bff-web → comunidades-service; quem cria vira admin)"
COM_A=$(json "$BASE/api/web/comunidades" -H "$AUTH" -d '{"nome":"Doadores da Demo","cidade":"Lavras","uf":"MG"}' | uuid .id)
COM_B=$(json "$BASE/api/web/comunidades" -H "$AUTH" -d '{"nome":"Outra Comunidade da Demo","cidade":"Lavras","uf":"MG"}' | uuid .id)
info "comunidades: $COM_A e $COM_B"
pausa

titulo "2. SAGA orquestrada — caminho feliz (T1 → T2 → T3 → T4)"
passo "POST /api/web/comunidades/{id}/mobilizacoes em $DIA no ponto de coleta de Lavras"
R=$(json "$BASE/api/web/comunidades/$COM_A/mobilizacoes" -H "$AUTH" -w '\n%{http_code}' \
  -d "{\"titulo\":\"Mobilização feliz\",\"dataHora\":\"${DIA}T09:00:00-03:00\",\"hemocentroId\":\"$HEMO_LAVRAS\",\"vagas\":10}")
info "HTTP $(tail -1 <<< "$R") — $(head -1 <<< "$R" | jq -c '{estado, sagaId, _links}')"
[[ $(tail -1 <<< "$R") == 202 ]] || falha "a criação da mobilização não retornou HTTP 202"
MOB_OK=$(head -1 <<< "$R" | uuid .id)
SAGA_OK=$(head -1 <<< "$R" | uuid .sagaId)
saga "$MOB_OK" CONCLUIDA
evidencias_saga "$SAGA_OK" "$MOB_OK"
pausa

titulo "3. SAGA — FALHA PROVOCADA com compensação (hemocentro sem capacidade)"
info "Outra comunidade pede o MESMO hemocentro no MESMO dia. Lavras atende 1 mobilização por dia:"
info "T2 (reservar data) dá certo, T3 (reservar janela) é recusado → C2 libera a data → C1 cancela."
MOB_FALHA=$(json "$BASE/api/web/comunidades/$COM_B/mobilizacoes" -H "$AUTH" \
  -d "{\"titulo\":\"Mobilização sem capacidade\",\"dataHora\":\"${DIA}T14:00:00-03:00\",\"hemocentroId\":\"$HEMO_LAVRAS\"}" | uuid .id)
SAGA_FALHA=$(api "$BASE/api/web/mobilizacoes/$MOB_FALHA/saga" -H "$AUTH" | uuid .sagaId)
saga "$MOB_FALHA" COMPENSADA
evidencias_saga "$SAGA_FALHA" "$MOB_FALHA"
passo "prova da compensação nos bancos (reservas do dia $DIA)"
psql_em comunidades "SELECT comunidade_id, data, saga_id FROM reservas_calendario WHERE saga_id IN ('$SAGA_OK', '$SAGA_FALHA')"
psql_em informacoes "SELECT hemocentro_id, data, saga_id FROM reservas_hemocentro WHERE saga_id IN ('$SAGA_OK', '$SAGA_FALHA')"
for par in comunidades:reservas_calendario informacoes:reservas_hemocentro; do
  banco=${par%%:*}
  tabela=${par#*:}
  reservas=$(psql_em "$banco" "SELECT saga_id FROM $tabela WHERE saga_id IN ('$SAGA_OK', '$SAGA_FALHA')" -At)
  [[ $reservas == "$SAGA_OK" ]] || falha "reservas inesperadas em $banco.$tabela"
done
info "Compensação conferida: só ficou a reserva da saga concluída."
pausa

titulo "4. SAGA — timeout provocado (informacoes-service fora do ar)"
if pergunta_sn "Derrubar o informacoes-service agora e esperar o timeout da saga (~30 s)?"; then
  interromper informacoes-service; info "informacoes-service PARADO"
  MOB_TO=$(json "$BASE/api/web/comunidades/$COM_A/mobilizacoes" -H "$AUTH" \
    -d "{\"titulo\":\"Mobilização com timeout\",\"dataHora\":\"${DIA2}T09:00:00-03:00\",\"hemocentroId\":\"$HEMO_LAVRAS\"}" | uuid .id)
  info "mobilização criada; aguardando o prazo do passo T3…"; sleep 33
  api "$BASE/api/web/mobilizacoes/$MOB_TO/saga" -H "$AUTH" | jq -r '"  saga \(.estado), compensações pendentes: \(.compensacoesPendentes | join(" → "))"'
  passo "religando o informacoes-service: ele processa a fila (reserva + C3) e a saga termina a compensação"
  restaurar
  saga "$MOB_TO" COMPENSADA
fi
pausa

titulo "5. CQRS — painel da comunidade (modelo de leitura) refletindo uma escrita"
passo "GET /api/web/comunidades/{id} lê o documento pronto da projeção (1 consulta, sem N+1)"
ANTES=$(api "$BASE/api/web/comunidades/$COM_A" -H "$AUTH")
jq -c '{fonte, versao, atualizadoEm, totalMembros, membros: [.membros[].nome], totalMobilizacoes, proximas: [.proximasMobilizacoes[].titulo]}' <<< "$ANTES"
passo "ESCRITA: um novo doador entra na comunidade (modelo normalizado + evento na outbox)"
E2="membro-$DEMO_ID@4life.local"
json "$BASE/api/web/cadastro" -d "{\"nome\":\"Nova Integrante\",\"email\":\"$E2\",\"senha\":\"senha-demo-123\",\"cidade\":\"Lavras\",\"uf\":\"MG\"}" > /dev/null
T2=$(json "$BASE/auth/login" -d "{\"email\":\"$E2\",\"senha\":\"senha-demo-123\"}" | jq -er '.token | strings | select(length > 0)')
AUTH_MOBILE="authorization: Bearer $T2"
codigo=$(status_http "$BASE/api/mobile/comunidades/$COM_A/entrar" -X POST -H "$AUTH_MOBILE")
[[ $codigo == 201 ]] || falha "entrada na comunidade respondeu HTTP $codigo"
info "POST /entrar → HTTP $codigo"
passo "leitura imediata (pode ainda estar na versão anterior: consistência eventual)"
api "$BASE/api/web/comunidades/$COM_A" -H "$AUTH" | jq -c '{versao, totalMembros, membros: [.membros[].nome]}'
passo "Aguardando a projeção refletir o evento de entrada e a mobilização confirmada"
VERSAO=$(jq -er .versao <<< "$ANTES")
TOTAL=$(jq -er .totalMembros <<< "$ANTES")
projetado=false
for ((i=0; i<60; i++)); do
  PAINEL=$(api "$BASE/api/web/comunidades/$COM_A" -H "$AUTH")
  if jq -e --argjson v "$VERSAO" --argjson n "$TOTAL" '
    .fonte == "modelo-de-leitura" and .versao > $v and .totalMembros == ($n + 1)
    and .totalMobilizacoes == 1 and any(.membros[]; .nome == "Nova Integrante")
  ' <<< "$PAINEL" >/dev/null; then
    projetado=true
    break
  fi
  sleep 0.5
done
jq -c '{fonte, versao, atualizadoEm, totalMobilizacoes, totalMembros, membros: [.membros[].nome]}' <<< "$PAINEL"
[[ $projetado == true ]] || falha "o painel não refletiu a escrita no prazo"
pausa

titulo "6. Fluxo mobile — participante → BFF → serviços"
api "$BASE/api/mobile/inicio" -H "$AUTH_MOBILE" |
  jq '{usuario: .usuario.nome, mobilizacoes: (.proximasMobilizacoes | length), comunidades: (.minhasComunidades | length), dica: .dica.titulo}'
for esperado in 201 409; do
  codigo=$(status_http "$BASE/api/mobile/mobilizacoes/$MOB_OK/interesse" -X POST -H "$AUTH_MOBILE")
  info "POST /interesse → HTTP $codigo (esperado $esperado)"
  [[ $codigo == "$esperado" ]] || falha "resultado inesperado ao registrar interesse"
done
codigo=$(status_http "$BASE/api/mobile/mobilizacoes/$MOB_OK/interesse" -X DELETE -H "$AUTH_MOBILE")
[[ $codigo == 204 ]] || falha "remoção de interesse respondeu HTTP $codigo"
info "DELETE /interesse → HTTP $codigo"
pausa

titulo "7. Database per service — cada serviço com o seu banco"
for s in doadores comunidades mobilizacoes informacoes; do
  passo "$s-db"
  psql_em "$s" "SELECT string_agg(tablename, ', ' ORDER BY tablename) AS tabelas FROM pg_tables WHERE schemaname = 'public'" -At
done
info "isolamento de rede: ./scripts/$([[ $MODO == k8s ]] && echo k8s-)teste-isolamento.sh"
pausa

titulo "8. LLM — assistente com RAG + tool (LangChain + Ollama)"
passo "Status do assistente — aguardando a ingestão da base vetorial"
for ((i=0; i<150; i++)); do
  STATUS=$(api "$BASE/api/web/info/assistente/status")
  if jq -e '.ingestao.status == "pronta"' <<< "$STATUS" >/dev/null; then break; fi
  if (( i % 5 == 0 )); then jq -c '{ingestao: .ingestao.status}' <<< "$STATUS"; fi
  sleep 2
done
jq '{modelo, modeloEmbeddings, ingestao, circuitos, politica}' <<< "$STATUS"
jq -e '.ingestao.status == "pronta"' <<< "$STATUS" >/dev/null ||
  falha "base RAG ainda indisponível; no Compose, confira docker compose logs ollama-modelos informacoes-service"

perguntar() {
  local entrada
  entrada=$(jq -cn --arg pergunta "$1" --argjson rag "${2:-true}" --argjson cache "${3:-true}" \
    '{pergunta: $pergunta, usarRag: $rag, usarCache: $cache}')
  RESPOSTA=$(json "$BASE/api/web/assistente/perguntar" -H "$AUTH" -d "$entrada")
  jq '{origem, duracaoMs, resposta, fontes: [.fontes[]? | {titulo, similaridade}], ferramentas, aviso}' <<< "$RESPOSTA"
}

pendencias=()
PERGUNTA="Segundo o FAQ do 4Life, é preciso estar em jejum para doar sangue?"
passo "Com RAG e sem cache — fontes recuperadas pelo pgvector"
perguntar "$PERGUNTA" true false
jq -e '.origem == "llm" and (.fontes | length > 0)' <<< "$RESPOSTA" >/dev/null ||
  pendencias+=("geração com fontes RAG")
passo "Repetição literal — cache por chave (sem recuperação)"
PERGUNTA_CACHE="$PERGUNTA (referência $DEMO_ID)"
perguntar "$PERGUNTA_CACHE" false true
perguntar "$PERGUNTA_CACHE" false true
jq -e '.origem == "cache"' <<< "$RESPOSTA" >/dev/null || pendencias+=("cache por chave")
passo "Mesma pergunta sem recuperação e sem cache"
perguntar "$PERGUNTA" false false
jq -e '.origem == "llm" and (.fontes | length == 0)' <<< "$RESPOSTA" >/dev/null ||
  pendencias+=("geração sem RAG")
passo "Tool LangChain — disponibilidade do hemocentro reservado na saga"
perguntar "O hemocentro de Lavras tem vaga para mobilização no dia $DIA?" true false
jq -e '.origem == "llm" and any(.ferramentas[]?; .nome == "verificar_disponibilidade")' <<< "$RESPOSTA" >/dev/null ||
  pendencias+=("tool verificar_disponibilidade")
if pergunta_sn "Derrubar o Ollama para mostrar timeout/retry → circuit breaker → fallback?"; then
  interromper ollama; info "Ollama PARADO"
  for q in "Posso doar depois de tomar vacina?" "Quanto tempo depois de uma cirurgia posso doar?" "Quem tem piercing pode doar?" "Qual o horário do hemocentro de Varginha?"; do
    perguntar "$q" false false
    jq -e '.origem == "fallback"' <<< "$RESPOSTA" >/dev/null || pendencias+=("fallback para: $q")
    api "$BASE/api/web/info/assistente/status" | jq -c '{circuitos: (.circuitos | map_values(.estado))}'
  done
  CIRCUITOS=$(api "$BASE/api/web/info/assistente/status")
  jq -e '.circuitos.llm.estado == "ABERTO"' <<< "$CIRCUITOS" >/dev/null ||
    pendencias+=("circuit breaker do LLM aberto")
  restaurar; info "Ollama religado (o circuito testa de novo depois de 30 s e fecha se o provedor responder)"
fi

titulo "Fim da demonstração"
if (( ${#pendencias[@]} > 0 )); then
  printf '  Evidência não observada: %s\n' "${pendencias[@]}" >&2
  exit 1
fi
info "Fluxos executados com evidência no terminal."
