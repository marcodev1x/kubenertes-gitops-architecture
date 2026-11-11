# Capacidade — cabendo em 12GB 📐

Este documento é a conta por trás dos números que estão nos
`apps/<serviço>/values-production.yaml`. Se você mudar um `requests` lá, mude a
linha correspondente aqui — é o único jeito de a `ResourceQuota` continuar
fazendo sentido.

> **Premissa da máquina:** VPS de **12 GB / 4 vCPU** (teto de 16 GB).
> Dos 12 GB, o kernel e as reservas do sistema comem uma fatia; a conta usa
> **~11,2 GiB úteis**.

---

## 1. Quem come o quê

### Fora do namespace `audita` (não entra na quota)

| Componente | RAM (requests) | CPU (requests) | Por quê |
|---|---:|---:|---|
| Sistema + k3s (apiserver, kubelet, containerd, etcd embutido) | ~1,20 GiB | ~400m | Piso da máquina |
| CoreDNS + metrics-server + local-path | ~0,15 GiB | ~50m | `metrics-server` é obrigatório: sem ele **nenhum HPA funciona** |
| istiod | 384 Mi | 150m | Plano de controle da malha |
| istio-ingressgateway | 128 Mi | 75m | Única porta de entrada (80/443) |
| ArgoCD | ~0,70 GiB | ~300m | repo-server + controller + redis + server |
| **Subtotal** | **~2,54 GiB** | **~975m** | |

### Dentro do namespace `audita` — medido, não estimado

Os números abaixo saem de `helm template` em todos os charts, somando os
`requests` de cada container **mais o sidecar** de quem está na malha. Para
reproduzir:

```bash
for c in apps/*/; do
  helm template "$(basename $c)" "$c" -f "$c/values.yaml" \
    $([ -f "$c/values-production.yaml" ] && echo -f "$c/values-production.yaml")
  echo ---
done > /tmp/all.yaml
```

| Grupo | RAM mín. | CPU mín. | RAM máx. | CPU máx. |
|---|---:|---:|---:|---:|
| Aplicações (15 serviços) | 3 104 Mi | 1 170m | 7 520 Mi | 2 845m |
| Sidecars do Istio | 1 056 Mi | 550m | 2 544 Mi | 1 325m |
| Kafka + Redis | 512 Mi | 250m | 512 Mi | 250m |
| Observabilidade | 832 Mi | 140m | 832 Mi | 140m |
| **Total** | **5 504 Mi ≈ 5,38 GiB** | **2 110m** | **11 408 Mi ≈ 11,14 GiB** | **4 560m** |
| Pods | **28** | | **59** | |

**"Mín." é o piso dos HPAs; "máx." é todo autoscaler no teto ao mesmo tempo.**
Repare que o máximo (11,14 GiB) não cabe na VPS — e é exatamente para isso que
existe a `ResourceQuota`.

### Aplicações, serviço a serviço

| Serviço | mín→máx | RAM/pod (app+sidecar) | RAM mín. | RAM máx. |
|---|---:|---:|---:|---:|
| audita-web | 2 → 4 | 304 Mi | 608 Mi | 1 216 Mi |
| bids | 2 → 5 | 304 Mi | 608 Mi | 1 520 Mi |
| client | 2 → 6 | 208 Mi | 416 Mi | 1 248 Mi |
| api-gateway | 2 → 6 | 176 Mi | 352 Mi | 1 056 Mi |
| billings | 2 → 4 | 176 Mi | 352 Mi | 704 Mi |
| agents | 1 → 3 | 304 Mi | 304 Mi | 912 Mi |
| api-auth-gateway | 2 → 4 | 144 Mi | 288 Mi | 576 Mi |
| webhooks | 2 → 4 | 144 Mi | 288 Mi | 576 Mi |
| cdn | 1 → 3 | 176 Mi | 176 Mi | 528 Mi |
| audita-landing | 1 → 2 | 176 Mi | 176 Mi | 352 Mi |
| mailer | 1 → 3 | 112 Mi | 112 Mi | 336 Mi |
| automations | 1 → 3 | 112 Mi | 112 Mi | 336 Mi |
| coupons | 1 → 3 | 112 Mi | 112 Mi | 336 Mi |
| certificates | 1 → 3 | 112 Mi | 112 Mi | 336 Mi |
| whitelabel | 1 → 2 | 112 Mi | 112 Mi | 224 Mi |
| pncp | **1 → 1** | 144 Mi | 144 Mi | 144 Mi |

O `pncp` é o único sem HPA. O motivo está em `apps/pncp/values-production.yaml`
e vale repetir: o rate limiter de 2,5 s vive na memória do processo, então cada
réplica é uma cópia independente do limite contra `pncp.gov.br`.

### Sidecars — a linha fácil de esquecer

| | |
|---|---|
| Pods na malha | 23 no mínimo (kafka, redis e observabilidade estão fora) |
| Request por proxy | 48 Mi / 25m |
| **Total no mínimo** | **1 104 Mi / 575m** |

> O padrão do Istio é **100m / 128Mi por proxy**. Com 23 pods seriam 2,88 GiB só
> de sidecar — um quarto da VPS antes de a primeira aplicação subir. Os 48 Mi
> vêm das anotações `sidecar.istio.io/proxyMemory` em cada Deployment, e o
> recurso `Sidecar` em `apps/mesh/templates/policy.yaml` corta a configuração
> que cada proxy carrega na memória.

---

## 2. O fechamento

| | RAM | CPU |
|---|---:|---:|
| Fora do namespace (SO, k3s, istiod, gateway, ArgoCD) | ~2,55 GiB | ~975m |
| Namespace `audita`, no mínimo | 5,49 GiB | 2 155m |
| **Total reservado em repouso** | **≈8,04 GiB** | **≈3 130m** |
| Disponível | 11,2 GiB | 4 000m |
| **Folga** | **≈3,2 GiB (28%)** | **≈870m (22%)** |

Com a quota **cheia** (7 GiB), o nó chega a **9,54 GiB dos 11,2 GiB** — restam
~1,6 GiB, que é o mínimo saudável para page cache.

A folga não é gordura. Ela paga por três coisas:

1. **Escala.** ~1,6 GiB e ~890m de espaço na quota: cerca de **9 pods a mais**
   (aplicação + sidecar) antes de a `ResourceQuota` travar.
2. **Rollout.** Todo Deployment usa `maxSurge: 1, maxUnavailable: 0` — durante
   uma atualização existe um pod a mais no ar. É o preço de não ter janela sem
   atendimento.
3. **Page cache.** Kafka e o driver do Mongo dependem do cache do kernel. Uma
   VPS com 100% da RAM reservada tem I/O muito pior do que uma com 75%.

> **Onde investir se sobrar dinheiro:** mais vCPU, não mais RAM. A RAM tem 29%
> de folga; a CPU, 23% — e é a CPU que trava primeiro quando dois HPAs sobem
> juntos. Sair de 4 para 6 vCPU rende mais do que ir de 12 para 16 GB.

---

## 2.1. Staging no mesmo nó

Medido com `helm template` nos 18 charts, somando `requests` mais sidecar:

| | RAM | CPU | Pods |
|---|---:|---:|---:|
| 16 serviços em 1 réplica | 1 392 Mi | 620m | 16 |
| 16 sidecars | 768 Mi | 400m | — |
| kafka + redis próprios | 320 Mi | 120m | 2 |
| **Total `audita-staging`** | **2 480 Mi (2,42 GiB)** | **850m** | **18** |

A quota do namespace é 3Gi / 1500m — o medido mais o pod extra do rollout.

**Kafka e Redis são próprios, não compartilhados.** Os tópicos têm o mesmo nome
nos dois ambientes (`CLIENT_CREATED`, `CERTIFICATES_EXPIRING_ALERT`) e as chaves
do Redis não têm prefixo por ambiente (`auth:<token>`). Um staging apontado para
o broker de produção manda e-mail de verdade para cliente de verdade na primeira
publicação; apontado para o Redis de produção, invalida sessão de pagante ao
testar troca de plano.

**Observabilidade não é duplicada.** O VictoriaMetrics já faz scrape de todo pod
anotado em qualquer namespace (o ClusterRole dele é cluster-wide) e o `mesh`
vale para a malha inteira. Duplicar custaria ~1 GiB para ver o mesmo gráfico
duas vezes — por isso o ApplicationSet de staging exclui os dois charts.

### Cabe em 12 GB?

Não com a produção podendo escalar.

| Cenário | Conta | 11,2 GiB úteis (12 GB) | ~15 GiB úteis (16 GB) |
|---|---|---:|---:|
| Produção no mínimo + staging | 2,55 + 5,49 + 2,42 | **10,46 GiB** — sobra 0,74 | sobra 4,5 |
| Produção no teto da quota + staging | 2,55 + 7,00 + 3,00 | **12,55 GiB** — não cabe | sobra 2,45 |

Em 12 GB, mesmo com tudo no piso restam 0,74 GiB — menos da metade do 1,6 GiB
que este documento fixa como mínimo de page cache, e o primeiro HPA que subir
deixa um pod em `Pending`. **Staging pede 16 GB.**

Se for para insistir nos 12 GB, o corte na ordem certa:

1. **Desligar `istio-injection` no namespace de staging** — devolve 768 Mi de
   uma vez. Custo: staging perde mTLS e balanceamento L7 de gRPC, ou seja,
   passa a testar um sistema que não é o de produção.
2. **Tirar `audita-landing` do staging** — a página de marketing não faz parte
   do fluxo que se testa. Devolve 144 Mi.
3. **Subir o staging só quando for usar.** `kubectl scale --replicas=0` no
   namespace inteiro entre um teste e outro devolve os 2,42 GiB e o ArgoCD não
   desfaz enquanto o `ignoreDifferences` de `/spec/replicas` estiver lá.

---

## 3. O que impede o autoscaler de derrubar a máquina

Três camadas, da mais específica para a mais geral:

| Camada | Onde | Protege de |
|---|---|---|
| `limits` por container | `values-production.yaml` de cada chart | Um serviço com vazamento comendo a máquina |
| `GOMEMLIMIT` (~80% do limite) | `env` no deployment | O GC do Go só acordar quando já é tarde e virar OOMKill |
| `ResourceQuota` do namespace | `base/resourcequota.yaml` | **Vários HPAs escalando juntos** |

A terceira é a que responde a "não quero usar toda a RAM da VPS". Sem ela, os
limites individuais estão todos corretos e a soma ainda estoura: 15 autoscalers
não se coordenam entre si. Com ela, o pod nº 46 simplesmente fica em `Pending`
com uma mensagem de quota excedida — o sistema **degrada em vez de quebrar**, e
você vê o problema no `kubectl get pods` em vez de num nó morto.

**Teste isso de propósito antes de precisar:**

```bash
kubectl -n audita describe resourcequota audita     # quanto já foi consumido
kubectl -n audita scale deploy/bids --replicas=12   # deve travar antes de chegar lá
kubectl -n audita get pods | grep Pending
```

---

## 4. Réplicas, balanceamento e o que elas realmente compram

**Sim, o Kubernetes balanceia — mas não em gRPC.**

Um `Service` ClusterIP distribui por **conexão** (L4, via kube-proxy). Em HTTP/1
isso funciona porque cada requisição tende a abrir uma conexão. gRPC é HTTP/2:
o cliente abre **uma** conexão longa e multiplexa todas as chamadas nela. Ela
cai num pod, e é nesse pod que fica.

O `private-kit` dial com `grpc.NewClient("bids:9090")` e o balanceador padrão
`pick_first` (`connectors/services.go:53`). Sem malha, subir `bids` para 2
réplicas dá **duas réplicas e uma fila**: um pod recebe tudo, o outro fica de
enfeite.

É por isso que o Istio se paga aqui. O sidecar termina o HTTP/2 e distribui por
**requisição** (L7), com a política declarada na `DestinationRule` de cada
serviço:

```yaml
trafficPolicy:
  loadBalancer:
    simple: LEAST_REQUEST     # o pod com menos chamadas pendentes agora
```

`LEAST_REQUEST` em vez de `ROUND_ROBIN` porque o custo das chamadas é desigual:
um `GetBid` com agregação no Mongo demora muito mais que um `GetFavorite`.
Round-robin entregaria a próxima chamada pesada a um pod já ocupado.

> **Alternativa sem Istio**, se um dia a malha ficar cara demais para a VPS:
> `Service` headless + `grpc.WithDefaultServiceConfig` com `round_robin` e
> resolver `dns:///`. Custa 0 MB e resolve o balanceamento de gRPC. O que você
> perde é mTLS, roteamento na borda, outlier detection e métricas L7 de graça.

**O que 2 réplicas num nó só dão e não dão:**

| Dá | Não dá |
|---|---|
| Rollout sem janela de indisponibilidade | Resiliência a falha do nó — as duas réplicas estão na mesma máquina |
| Sobrevivência a crash/OOM de um pod | Mais throughput de disco ou de rede |
| Distribuição real de carga (com a malha) | Alta disponibilidade de verdade |
| Ejetar um pod doente (outlier detection) | |

Redundância de máquina só vem com um segundo nó. Os
`topologySpreadConstraints` já estão nos charts com `ScheduleAnyway`: hoje não
fazem nada, e no dia em que houver um segundo nó as réplicas se espalham
sozinhas, sem tocar em chart nenhum.

---

## 5. Decisões que valem revisar depois

| Decisão | Hoje | Quando mudar |
|---|---|---|
| `pncp` travado em 1 réplica | O rate limiter de 2,5 s vive na memória do processo; 2 réplicas dobram a taxa contra `pncp.gov.br` | Mover o limitador para o Redis. Só então ligar HPA |
| HPA por CPU, nunca por memória | O heap do Go não encolhe: a métrica sobe e não desce, e o HPA fica preso no máximo. Com `GOMEMLIMIT` é pior, porque o processo trabalha de propósito perto do teto | Se aparecer métrica customizada (fila do Kafka, requisições em voo), ela é o sinal certo — principalmente para o `agents` |
| `agents` escala mal | O pod passa a vida bloqueado esperando a OpenAI, com CPU perto de zero — CPU quase não dispara o HPA | Métrica de fila, ou mover a análise para consumo assíncrono via Kafka |
| Kafka e Redis fora da malha | Protocolo TCP, nada a ganhar com L7; economiza ~96 Mi | Se precisar de mTLS até o broker |
| `audita-landing` em Node | 128 Mi de request para servir página quase estática | `next build && next export` + `nginx:alpine` devolve ~130 Mi |
| Observabilidade com 4 Gi + 6 Gi de disco | `local-path` grava em `/var/lib/rancher` no disco da VPS | Vigie o disco: 10 Gi de série temporal + log cresce sozinho |
| ArgoCD completo | ~700 Mi | Desligar `dex` (SSO) e `notifications` devolve ~200 Mi |

---

## 6. Ordem de subida

A ordem importa: cada passo é pré-requisito do seguinte.

```
1. ./scripts/bootstrap-k3s.sh        k3s SEM Traefik (o Istio ocupa 80/443) + ArgoCD
2. kubectl -n cert-manager create secret generic cloudflare-api-token ...
3. ./scripts/bootstrap-istio.sh      cert-manager, ClusterIssuer, istiod, ingressgateway
4. kubectl apply -f base/            namespace com istio-injection, quota, limits, config
5. kubectl -n audita create secret generic audita ...    (ou Sealed Secrets)
6. kubectl apply -f argocd/root-app.yaml                 o ArgoCD assume daqui
```

O passo 3 tem que vir antes do 6: os charts de `apps/*` criam `Gateway`,
`VirtualService` e `DestinationRule`. Sem os CRDs do Istio no cluster, o ArgoCD
falha a sincronizar quase tudo e você perde meia hora achando que o problema é
outro.
