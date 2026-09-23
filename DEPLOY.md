# Deploy do BottleForge

O deploy é baseado em tags Git e GitHub Actions.

## Fluxo normal

1. Desenvolva e teste na branch `main`.
2. Faça commit de todas as alterações.
3. Execute:

```bash
./Scripts/release.sh v0.1.1-alpha
```

O script valida o Swift, envia a `main`, cria a tag e envia a tag ao GitHub.
A tag dispara `.github/workflows/release.yml`.
## O que o GitHub Actions faz

- baixa a release-base que contém os runtimes Wine/DXMT;
- extrai os runtimes sem armazená-los no Git;
- compila o BottleForge para Apple Silicon;
- injeta a tag em `BottleForgeReleaseTag` no `Info.plist`;
- assina a build de forma ad-hoc;
- gera `BottleForge-<tag>-macOS.dmg`;
- gera `SHA256SUMS.txt`;
- publica a GitHub Release e seus assets.

Enquanto os runtimes não forem versionados separadamente, a release-base é
`v0.1.0-alpha`, configurada em `RUNTIME_SOURCE_TAG` no workflow.
## Atualização dentro do app

O BottleForge consulta as Releases do repositório ao iniciar e quando volta
ao primeiro plano. Checagens automáticas são limitadas a uma a cada 15 minutos.

Quando encontra uma versão superior:

- mostra a release e as notas no app;
- baixa o DMG oficial do GitHub;
- valida o SHA-256 publicado no asset;
- valida a assinatura do novo `.app`;
- substitui a instalação atual;
- relança o BottleForge.

Builds alpha/beta/rc aceitam prereleases. Uma build estável ignora prereleases.
## Próxima otimização

Hoje cada DMG ainda contém os runtimes completos. Isso mantém a distribuição
simples, mas torna as atualizações grandes.

A evolução recomendada é separar:

- `BottleForge.app`: interface e lógica, pequeno e atualizado com frequência;
- `BottleForge Runtime`: Wine/DXMT/WineD3D, versionado e baixado apenas quando
  a versão do runtime mudar.

O updater atual foi isolado em `App/UpdateManager.swift` para permitir essa
migração sem alterar a interface de atualização.
