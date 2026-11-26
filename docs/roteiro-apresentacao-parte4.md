# Roteiro de apresentação — Parte 4: sistema distribuído e LLM

**Duração-alvo:** aproximadamente 10 minutos de fala, divididos entre quatro pessoas.  
**Demonstração:** execução ao vivo/local com Docker Compose, usando o terminal e os resultados do `complete-run.sh`. A fala acompanha o vídeo: pause nos pontos indicados, explique a evidência que está visível e retome o comando.  
**Importante:** o requisito pede execução ao vivo. O vídeo pode registrar a execução, mas a apresentação deve mostrar o sistema funcionando no ambiente de teste local, não somente slides ou uma gravação.

## Distribuição do tempo

| Parte | Pessoa | Tempo aproximado | Etapas do script |
|---|---|---:|---|
| 1. Docker e fluxo ponta a ponta | Pessoa 1 | 2 min 30 s | 0–1 |
| 2. SAGA e compensação | Pessoa 2 | 2 min 30 s | 2–4 |
| 3. CQRS, fluxo mobile e bancos | Pessoa 3 | 2 min 20 s | 5–7 |
| 4. RAG, LangChain e LLM resiliente | Pessoa 4 | 2 min 40 s | 8 |
| **Total** |  | **10 min** |  |

Os tempos incluem pausas curtas para deixar os resultados legíveis. O passo opcional que derruba o serviço de informações leva cerca de 30 segundos de espera; a indisponibilidade do Ollama pode levar mais tempo por causa de timeout e retry. Se o vídeo incluir esses cenários completos, a duração total pode passar de 10 minutos. A demonstração obrigatória de compensação da SAGA é a falha por falta de capacidade, que já evidencia a compensação efetiva.

---

## Parte 1 — Pessoa 1: Docker e fluxo ponta a ponta

### Abertura e Docker subindo — enquanto aparecem os containers

> “Olá, somos a equipe Nibble, e este é o 4Life, uma plataforma para aproximar doadores, comunidades e hemocentros. Estamos vendo o ambiente local subir no Docker; o Compose inicia os serviços, bancos e mensageria. Agora vamos acompanhar requisições reais passando pela arquitetura, antes de mostrar o frontend.”

### Pausar na etapa 0 — containers, health check, RabbitMQ e isolamento

> “Os containers estão em execução e o gateway respondeu ao health check. O gateway recebe as chamadas externas e as encaminha ao BFF correspondente, que conversa com os serviços de domínio.”

> “O RabbitMQ transporta eventos entre serviços, sem acesso direto aos bancos uns dos outros. O teste de isolamento confirma que cada serviço acessa apenas o banco do seu domínio.”

> “Uma rota pública de informações passa pelo BFF mobile e retorna o FAQ. Já a rota protegida do painel responde 401 sem JWT. Isso mostra que a autenticação é aplicada no caminho da requisição, antes de entregar os dados protegidos.”

### Retomar e pausar na etapa 1 — cadastro, login e comunidades

> “Agora o script cria um doador usando a rota pública do gateway. A chamada chega ao BFF web e é encaminhada ao serviço de doadores, que grava o cadastro no seu banco.”

> “Depois fazemos login. O gateway valida as credenciais e emite um JWT. Esse token acompanha as próximas chamadas protegidas. Com ele, criamos duas comunidades pela API web: o BFF web encaminha as operações ao serviço de comunidades. O identificador devolvido para cada comunidade será usado nas próximas etapas.”

> “Já percorremos gateway, BFF e serviços de domínio em execução. Agora usamos esses dados para mostrar uma Saga feliz e outra com falha provocada.”

---

## Parte 2 — Pessoa 2: SAGA feliz e falha com compensação

### Pausar na etapa 2 — resposta 202 e linha do tempo da SAGA feliz

> “Nesta etapa criamos uma mobilização pela comunidade. A API responde 202, que indica que a solicitação foi aceita e será processada de forma assíncrona. A resposta inclui os identificadores da mobilização e da Saga, além de um link para consultar o andamento.”

> “A linha do tempo mostra o orquestrador avançando pelos passos. Primeiro é criada a mobilização; depois a comunidade reserva a data no calendário; em seguida, o serviço de informações reserva a janela do hemocentro; por fim, a mobilização é confirmada. O resultado final é `CONCLUIDA`, e a mobilização aparece confirmada.”

> “A Saga coordena serviços e bancos diferentes por eventos publicados na outbox e transportados pelo RabbitMQ, sem uma transação compartilhada entre os bancos.”

### Retomar e pausar na etapa 3 — falha provocada e compensação

> “Agora provocamos a falha exigida no trabalho. A primeira mobilização já reservou a capacidade do hemocentro de Lavras nessa data. O script cria uma segunda mobilização, por outra comunidade, para o mesmo hemocentro e no mesmo dia. Esse hemocentro atende uma mobilização por dia.”

> “O passo de reserva do calendário da comunidade consegue ser concluído, mas o passo seguinte, que tenta reservar a janela no hemocentro, é recusado porque não há capacidade disponível. A Saga não deixa a reserva anterior esquecida: executa a compensação C2 para liberar a data no calendário e C1 para cancelar a mobilização.”

> “O estado final é `COMPENSADA`. As consultas aos bancos confirmam o efeito: permanece a reserva da Saga concluída, mas a reserva da Saga que falhou foi removida. A compensação aparece nos dados e no histórico.”

### Etapa 4 — cenário opcional de timeout, se aparecer no vídeo

> “Como cenário extra, o script para o `informacoes-service`: a Saga registra o timeout e compensações pendentes. Quando o serviço volta, processa as mensagens e termina a compensação.”

---

## Parte 3 — Pessoa 3: CQRS, fluxo mobile e bancos separados

### Pausar na etapa 5 — escrita refletida no modelo de leitura

> “Aqui demonstramos CQRS. A consulta do painel da comunidade lê um documento pronto do modelo de leitura, identificado pela fonte `modelo-de-leitura`. Guardamos a versão atual e o total de membros antes de fazer uma nova escrita.”

> “Em seguida, cadastramos uma nova doadora e ela entra na comunidade pelo fluxo mobile. Essa escrita atualiza o modelo normalizado e publica um evento na outbox. O consumidor do evento atualiza a projeção usada pelo painel.”

> “A projeção é assíncrona, então a primeira leitura pode mostrar a versão anterior. Após a espera, a versão aumenta e a nova integrante aparece: é a consistência eventual entre escrita e leitura.”

### Pausar na etapa 6 — fluxo mobile e respostas HTTP

> “A tela inicial mobile reúne usuário, comunidades, mobilizações e uma dica por meio do BFF mobile.”

> “Depois registramos interesse na mobilização. A primeira chamada retorna 201 porque o interesse foi criado. A segunda retorna 409 porque o mesmo interesse já existe. Por fim, a remoção retorna 204. Esses códigos mostram que a API está executando regras reais do domínio, incluindo a prevenção de duplicidade.”

### Pausar na etapa 7 — um banco por serviço

> “Agora o script consulta a estrutura de cada banco: doadores, comunidades, mobilizações e informações. Cada serviço é dono das tabelas do seu domínio. O serviço de informações também mantém ali os dados de hemocentros, as reservas usadas pela Saga e os vetores do RAG.”

> “Com o teste de isolamento, isso evidencia database per service: os serviços se comunicam por APIs e mensagens, sem compartilhar tabelas.”

---

## Parte 4 — Pessoa 4: RAG, LangChain e LLM como serviço resiliente

### Pausar na etapa 8 — status da ingestão

> “O último bloco mostra o assistente de dúvidas do 4Life. Ele tem uma função ligada ao domínio: responder dúvidas sobre doação, impedimentos e regras da plataforma usando conhecimento próprio do projeto, além de consultar dados reais dos hemocentros.”

> “A base inclui dez documentos do 4Life e conteúdos do FAQ, divididos em 41 trechos. No pipeline, os documentos são divididos em partes, transformados em embeddings pelo modelo multilíngue `bge-m3`, armazenados no pgvector e recuperados por similaridade. Os três trechos mais relevantes são enviados ao modelo `qwen2.5:0.5b` para produzir a resposta. O status confirma que a ingestão terminou e que a base está pronta.”

### Pausar na pergunta com RAG e fontes

> “Nesta pergunta sobre tatuagem, a resposta aparece com a origem `llm`, o tempo gasto e os trechos recuperados, incluindo seus títulos e similaridades. Assim conseguimos ver tanto a resposta quanto parte da evidência usada para formulá-la.”

> “O script também compara a resposta sem recuperação. Na avaliação documentada, foram testadas oito perguntas, incluindo critérios gerais e regras próprias do 4Life. No Compose, o resultado foi 8 de 8 corretas com RAG e 0 de 8 sem RAG. No Kubernetes, foi 7 de 8 com RAG e 0 de 8 sem RAG.”

> “O RAG melhora o resultado, mas não elimina erros: no Kubernetes houve uma resposta problemática apesar da recuperação do trecho correto. Por isso a avaliação também analisa as respostas, não só a pontuação automática.”

### Pausar na repetição e no cache

> “Quando repetimos uma pergunta, o campo `origem` indica `cache`. O cache reduz o trabalho do modelo para perguntas repetidas. A documentação registra respostas em cache em poucos milissegundos, enquanto perguntas novas com RAG levaram em média cerca de 3,14 segundos no resultado salvo.”

### Pausar na chamada da tool

> “A chain integra tools. Nesta pergunta, o modelo chama `verificar_disponibilidade`, que consulta o hemocentro e as reservas reais feitas pela Saga. Assim, a resposta considera dados operacionais, além dos textos recuperados.”

> “Uma chain é suficiente porque o fluxo é conhecido e basta uma rodada de decisão sobre tools; um agente acrescentaria chamadas e latência sem necessidade.”

### Resiliência, latência e custo — conclusão da parte técnica

> “O LLM é uma dependência falível. Temos timeout e retry com backoff, circuit breaker, cache e fallback sem LLM, que usa busca textual e dados do domínio. O script permite parar o Ollama, mas retries podem levar dezenas de segundos.”

> “A latência fica registrada em `duracaoMs`. Na avaliação salva, a média foi de aproximadamente 3,14 segundos com RAG e 2,24 segundos sem RAG. Como executamos o modelo localmente, não há custo por token de um provedor externo; o custo variável considerado é o consumo de energia.”

> “Como estimativa ilustrativa, se a máquina consumir em média 50 watts adicionais durante uma operação de 3,14 segundos e a energia custar R$ 1 por quilowatt-hora, isso equivale a aproximadamente R$ 0,000044 por operação, ou R$ 4,36 para 100 mil operações. Essa conta é uma hipótese de escala: não inclui consumo ocioso nem o custo do equipamento, e deve ser atualizada com a potência e a tarifa efetivamente medidas.”

> “Com isso, mostramos o sistema rodando, o fluxo completo entre gateway, BFF e serviços, as duas execuções da Saga, a compensação real, a atualização do modelo CQRS, os bancos separados e a integração de LLM com RAG, tool e mecanismos de resiliência. Agora vamos para a demonstração do frontend.”

---

## Evidências para deixar visíveis no vídeo

- `docker compose ps`, resposta do health check, teste de isolamento, filas e consumidores do RabbitMQ.
- Cadastro, emissão do JWT, criação das duas comunidades e resposta 202 da mobilização.
- Linha do tempo `CONCLUIDA` da Saga feliz e `COMPENSADA` da Saga com falta de capacidade.
- Consultas às reservas em `comunidades-db` e `informacoes-db`, mostrando que a reserva da Saga falha foi desfeita.
- Escrita de entrada na comunidade, versão anterior do painel e versão atualizada com a nova integrante.
- Respostas do fluxo mobile: 201, 409 e 204.
- Bancos e tabelas separados, mais o resultado do teste de isolamento.
- Status da ingestão RAG, resposta com fontes, comparação sem recuperação, avaliação de oito perguntas, cache e tool.
- Latência observada em `duracaoMs` e estimativa de custo com suas hipóteses declaradas.

## Referências do projeto

- Execução demonstrativa: [`scripts/complete-run.sh`](../scripts/complete-run.sh)
- Guia de requisitos e demonstração: [`parte4.md`](parte4.md)
- Resultados e análise da avaliação: [`llm/avaliacao-rag.md`](llm/avaliacao-rag.md)
- Resultados brutos do Compose: [`llm/avaliacao-rag-resultados.json`](llm/avaliacao-rag-resultados.json)
- Implementação e resiliência do assistente: [`llm/README.md`](llm/README.md)
