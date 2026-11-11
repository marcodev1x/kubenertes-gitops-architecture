# Atlas Search — o índice que o produto depende

O `bids_search` **não é opcional**. Duas telas param sem ele, e param em
silêncio: a busca de `/licenses` e o boletim diário, que casa as palavras-chave
do cliente com o acervo.

Ele vive só no Atlas — não é um índice de MongoDB comum e **não existe em
MongoDB self-hosted**. É por isso que o banco fica no Atlas e não sobe junto na
VPS. O JSON ao lado é a definição versionada: um cluster novo nasce sem ela, e
sem ela a agregação devolve zero resultados sem erro nenhum.

## Aplicar

Pela CLI do Atlas, apontando para o cluster do ambiente:

```bash
atlas auth login
atlas clusters search indexes create --clusterName <cluster> --file bids_search.json
```

Conferir depois:

```bash
atlas clusters search indexes list --clusterName <cluster> --db bids --collection bids
```

O índice leva alguns minutos para ficar `STEADY`. Antes disso a busca responde
vazio, o que na tela é indistinguível de "não há licitações".

## O que cada campo faz

| Campo | Papel |
|---|---|
| `title`, `object`, `description` | Os três caminhos que a busca percorre. Cada um em três análises: portuguesa (stemming), `exact` (frase literal, com boost 5) e `radical` (edge-gram, para `capinagem` encontrar `capina`) |
| `uf`, `cityibge`, `modalitycode` | `token` — filtro exato, sem análise |
| `publicationdate`, `proposalclosingdate` | `date` — a ordenação e o corte de prazo |
| `estimatedvalue` | `number` — faixas de valor |

`dynamic: false` de propósito: a coleção tem dezenas de campos vindos do PNCP e
indexar tudo multiplicaria o custo do índice sem nada em troca.

## Se mudar

Mexer nos analisadores muda o resultado da busca **e** do boletim, que usam o
mesmo índice (`bids/store/bids.go`). Rode a coleta e confira uma palavra-chave
conhecida antes de considerar a mudança boa.
