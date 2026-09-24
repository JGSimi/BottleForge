# Third-party notices

A distribuição Full do BottleForge inclui ou utiliza componentes de terceiros.

## Wine

Wine é um projeto independente de compatibilidade Windows. A build atualmente empacotada é Wine 11.8 Staging, usando a distribuição macOS do projeto Gcenx. A engine DXMT inclui um adapter winemac derivado do código Wine para expor a integração Metal necessária ao DXMT. Consulte `ThirdPartyLicenses/WINE-LICENSE.txt`.

## DXMT

DXMT fornece tradução Direct3D 10/11 para Metal. A build atualmente empacotada é DXMT 0.80. Consulte `ThirdPartyLicenses/DXMT-LICENSE.txt`.

## D3D12 / VKD3D-Proton macOS

Jogos Direct3D 12 podem usar o runtime `metalsharp/VKD3D-Proton-MacOS` v1.0: `d3d12.dll` + `d3d12core.dll` do VKD3D-Proton, `dxgi.dll` do DXVK-macOS e uma build customizada do MoltenVK. O runtime é baixado durante o build e verificado por SHA-256 antes de ser empacotado. Os componentes mantêm suas licenças upstream e o pacote inclui o README/SHA256SUMS do runtime.

## MoltenVK

MoltenVK fornece a camada Vulkan sobre Metal usada pela engine e pelo caminho D3D12. Consulte `ThirdPartyLicenses/MOLTENVK-LICENSE.txt`.

## Steam CEF compatibility

BottleForge inclui um pequeno wrapper MIT derivado de `notpop/steam-on-m1-wine` para iniciar o `steamwebhelper` com CEF em modo de processo único e renderização por software em Apple Silicon. Consulte `ThirdPartyLicenses/STEAM-ON-M1-WINE-LICENSE.txt`.

## Laya

O modo de otimização automática usa `@receptron/laya` 0.1.2 (MIT) e o modelo Laya da Convai Innovations (Apache 2.0). Os pesos do modelo não são incluídos no DMG: são baixados no primeiro uso e armazenados no diretório de dados do BottleForge.

## Node.js e ONNX Runtime

O runtime local do Laya inclui Node.js arm64 e ONNX Runtime Node para inferência local. Os avisos e licenças distribuídos pelos respectivos pacotes acompanham o runtime empacotado.

Outras bibliotecas transitivas incluídas pela distribuição Wine, pelo runtime D3D12 ou pelo runtime Laya mantêm seus respectivos direitos e licenças upstream. Este projeto não reivindica autoria desses componentes.
