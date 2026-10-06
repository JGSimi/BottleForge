# BottleForge

BottleForge é um gerenciador nativo de bottles Wine para macOS, focado em jogos e launchers Windows.

> Alpha: esta versão ainda está em desenvolvimento e, por enquanto, é voltada para Macs Apple Silicon.

## Download

Baixe o arquivo `BottleForge-v0.1.0-alpha-macOS.dmg` na página **Releases** do repositório.

A build Full já inclui Wine, DXMT, WineD3D e as bibliotecas necessárias. Não é necessário instalar Homebrew, Wine ou DXMT separadamente.

## Instalação

1. Abra o `.dmg`.
2. Arraste **BottleForge** para **Aplicativos**.
3. Como esta alpha ainda não é notarizada pela Apple, abra o Terminal e execute:

```bash
xattr -dr com.apple.quarantine "/Applications/BottleForge.app"
```

4. Abra o BottleForge normalmente.

Use esse comando somente para o BottleForge baixado da página oficial de Releases deste repositório.

## Requisitos

- Mac com Apple Silicon
- macOS 14 ou superior
- Rosetta 2 para a engine Wine x86_64

## Recursos atuais

- Bottles isoladas e persistentes
- Wine 11.8 Staging
- DXMT 0.80 para Direct3D 10/11 -> Metal
- VKD3D-Proton + MoltenVK para Direct3D 12 -> Metal
- WineD3D como renderer alternativo
- Executar instaladores e programas `.exe`
- Detectar apps e jogos instalados em cada bottle e abrir com um clique
- Modo Auto por API gráfica detectada nos imports PE e DLLs locais (DXMT/MSync/D3D11/D3D12/WineD3D)
- Histórico persistente por bottle e jogo: após uma falha confirmada, a próxima abertura tenta outro perfil compatível
- Detecção de jogos em bibliotecas adicionais da Steam
- Perfil offline D3D12 para Elden Ring (AppID 1245620), iniciando o executável principal sem carregar o módulo EAC; modo online permanece indisponível no macOS/Wine
- Atualizações automáticas via GitHub Releases com validação SHA-256
- Correção automática da tela preta do Steam CEF no Apple Silicon
- Wine Config
- Acesso ao drive C: da bottle
- Encerramento dos processos Wine
- Dados das bottles em `~/Library/BottleForge/Bottles`

## Desenvolvimento

O app principal fica em `App/BottleForge.swift` e o sistema de atualização em `App/UpdateManager.swift`.

As engines não são versionadas no Git devido ao tamanho. A distribuição Full publicada em Releases contém os runtimes necessários dentro do próprio `.app`.

O modo Auto usa detecção local e não exige baixar um modelo. Sugestões Laya já armazenadas podem priorizar um perfil, desde que ele seja compatível com a API detectada; perfis que falharam continuam excluídos. O runtime Laya permanece disponível para desenvolvimento, com cache em `~/Library/BottleForge/AI/Laya`.

## Seleção e limites de compatibilidade

No Elden Ring, o requisito D3D12 prevalece sobre imports mistos de DLLs. O modo offline precisa do cliente Steam da mesma bottle em execução. Você pode abrir a Steam, entrar na conta e abrir o jogo pela lista do BottleForge mantendo a Steam aberta. O cliente usa seu perfil gráfico normal e o jogo recebe o perfil DirectX 12; ambos compartilham a engine e o MSync. Se a Steam estiver fechada, a primeira abertura inicia o cliente e verifica se `Steam.exe` apareceu antes de orientar o login e a nova abertura do jogo. Essa verificação confirma o processo, não a autenticação. Se o cliente não iniciar, o app mostra a falha com referência ao log. Se o jogo encerrar imediatamente, a tentativa não é gravada como perfil bem-sucedido. Use **Abrir logs de execução** para ver o comando, a configuração gráfica, a duração e o código de saída.

Os requisitos D3D12 estão na [página oficial do Elden Ring](https://en.bandainamcoent.eu/elden-ring/elden-ring), e a dependência do cliente Steam está na [documentação de inicialização do Steamworks](https://partner.steamgames.com/doc/sdk/api#initialization_and_shutdown).

O BottleForge examina as tabelas de imports normais e atrasados do executável e até 64 DLLs locais. D3D10/11 priorizam DXMT, D3D9 e APIs legadas usam WineD3D, e D3D12 em executáveis x64 usa VKD3D quando o runtime está disponível. A flag `-force-d3d11` só é candidata para Unity com evidência de D3D11. Na Steam, as opções do jogo seguem `-applaunch <AppID>`.

Isso amplia a compatibilidade, mas não permite garantir **qualquer jogo**: drivers Windows, anti-cheat, recursos gráficos ausentes e requisitos do hardware continuam impondo limites. Imports também não revelam todas as APIs carregadas dinamicamente, e a seleção do executável principal da Steam é uma heurística. A tradução D3D10/11 está descrita no [projeto DXMT](https://github.com/3Shain/dxmt), e as flags do Unity na [documentação oficial](https://docs.unity.com/en-us/engine/6000.6/manual/unity-editor/command-line-arguments/player).

Se o perfil escolhido exigir outro renderer ou outro estado de MSync, use **Encerrar** na bottle antes de abrir o jogo: a Steam já em execução mantém o ambiente antigo. O app não encerra automaticamente outros jogos para trocar o perfil. As DLLs D3D12 são preparadas com staging e backup dos arquivos anteriores em `prefix/BottleForgeRuntime/original-system32`; DXMT e WineD3D usam overrides builtin para não carregar o DXGI nativo de outra tentativa.

Falhas confirmadas por código de saída ficam em `~/Library/BottleForge/Compatibility/<bottle-id>`. A Steam é monitorada por seus processos filhos; falta de telemetria não conta como falha de renderer. Jogos encerrados pelo botão **Encerrar** não penalizam o perfil. Não há reinício automático de jogos após crashes. Quando os perfis se esgotarem, consulte `~/Library/BottleForge/Logs` e use **Redefinir perfis de compatibilidade** para tentar novamente após corrigir dependências ou configurações. Alterações do executável, runtime ou configuração da bottle invalidam o histórico correspondente.

Para validar o algoritmo e compilar o app sem baixar os runtimes:

```bash
zsh Scripts/test-compatibility.sh
zsh Scripts/test-launcher.sh
xcrun swiftc -parse-as-library -typecheck App/*.swift
mkdir -p build
xcrun swiftc -parse-as-library -target arm64-apple-macos14.0 App/*.swift -o build/BottleForge
```

## Logs de execução

O botão **Logs de execução** fica na barra inferior da janela principal, mesmo sem uma bottle selecionada. Ele permite abrir a pasta, consultar o último log e **Exportar diagnóstico…** para salvar um arquivo de texto com a versão do BottleForge, o modelo do Mac, o macOS e o log da última abertura na bottle selecionada. Depois de reproduzir uma falha, envie esse arquivo para análise. Logs grandes são limitados às últimas 2 MiB; o arquivo original continua disponível na pasta.

## Releases e atualização

O app verifica automaticamente novas GitHub Releases. O processo de deploy
está documentado em `DEPLOY.md` e pode ser disparado com:

```bash
./Scripts/release.sh v0.1.1-alpha
```

O app procura **releases publicadas com DMG**, não commits na `main`. Fazer merge de um PR não publica uma versão instalável. Use **Atualizações** no rodapé para abrir o resultado da consulta, incluindo erros de rede; verificações automáticas acontecem na abertura e ao voltar ao primeiro plano. A instalação depende do botão **Atualizar agora**.

O updater valida tamanho e SHA-256 (digest do GitHub ou `SHA256SUMS.txt`), assinatura, identidade e versão do app. A nova cópia é preparada antes de solicitar o encerramento do BottleForge. A versão anterior permanece disponível para restauração se a substituição falhar. Resultados e logs persistem em `~/Library/BottleForge/Updates`; a tela de atualização permite abri-los.

Para testar consulta, integridade e instalação com um DMG de teste assinado, sem baixar engines:

```bash
zsh Scripts/test-updates.sh
```

Os testes de instalação usam apps descartáveis em uma pasta temporária e cobrem sucesso, rejeição de versão incorreta e rollback após corrupção da cópia preparada.

## Estado do projeto

A engine DXMT usa Wine 11.8 Staging como base, com o adapter winemac necessário para criar superfícies Metal e DXMT 0.80 oficial. Jogos D3D12 podem usar o runtime VKD3D-Proton macOS v1.0 sobre MoltenVK. O renderer WineD3D usa a mesma base Wine sem o overlay DXMT.

## Terceiros

BottleForge não contém código proprietário da CodeWeavers. A distribuição Full inclui componentes open source de terceiros, incluindo Wine, DXMT e MoltenVK, cada um sob sua licença original. Veja `THIRD_PARTY_NOTICES.md` e `ThirdPartyLicenses/`.
