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
- Wine 11.17 Staging
- DXMT 0.80 para Direct3D 10/11 -> Metal
- WineD3D como renderer alternativo
- Executar instaladores e programas `.exe`
- Wine Config
- Acesso ao drive C: da bottle
- Encerramento dos processos Wine
- Dados das bottles em `~/Library/BottleForge/Bottles`

## Desenvolvimento

O código do aplicativo fica em `App/BottleForge.swift`.

As engines não são versionadas no Git devido ao tamanho. A distribuição Full publicada em Releases contém os runtimes necessários dentro do próprio `.app`.

## Estado do projeto

A engine custom baseada no source aberto do CrossOver/Wine, incluindo suporte a MSync, ainda está em desenvolvimento. A alpha usa Wine 11.17 Staging como engine bootstrap.

## Terceiros

BottleForge não contém código proprietário da CodeWeavers. A distribuição Full inclui componentes open source de terceiros, incluindo Wine, DXMT e MoltenVK, cada um sob sua licença original. Veja `THIRD_PARTY_NOTICES.md` e `ThirdPartyLicenses/`.
