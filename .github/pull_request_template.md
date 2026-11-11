## Objetivo

<!-- O problema que isso resolve. Sintoma observável, não a solução. -->

## O que mudou

<!-- As decisões, não o diff. Por que esta abordagem e não a óbvia. -->

## Verificação

<!-- O que você rodou e o que voltou. Cole a saída se couber em três linhas.
     Teste novo: diga qual comportamento ele trava. -->

## Risco e rollback

<!-- O que quebra se isso estiver errado, e como você percebe. Se for "nada",
     escreva o motivo. -->

## Antes do merge

- [ ] `helm template` do chart alterado renderiza (o CI cobre, mas confira o
      diff dos manifestos)
- [ ] Mudou `requests`/`limits` ou réplicas → a soma continua dentro da
      `ResourceQuota` do namespace; `CAPACIDADE.md` atualizado
- [ ] Nada acima

---

O merge na `main` **é aplicado no cluster sem aprovação manual** — o ArgoCD lê
daqui com `selfHeal` e `prune` ligados. Rollback é reverter o commit, ou o
History na UI do Argo.
