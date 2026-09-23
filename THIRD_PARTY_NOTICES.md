# Third-party notices

A distribuição Full do BottleForge inclui ou utiliza componentes de terceiros.

## Wine

Wine é um projeto independente de compatibilidade Windows. A build atualmente empacotada é Wine 11.8 Staging, usando a distribuição macOS do projeto Gcenx. A engine DXMT inclui um adapter winemac derivado do código Wine para expor a integração Metal necessária ao DXMT. Consulte `ThirdPartyLicenses/WINE-LICENSE.txt`.

## DXMT

DXMT fornece tradução Direct3D 10/11 para Metal. A build atualmente empacotada é DXMT 0.80. Consulte `ThirdPartyLicenses/DXMT-LICENSE.txt`.

## MoltenVK

MoltenVK fornece a camada Vulkan sobre Metal usada pela engine. Consulte `ThirdPartyLicenses/MOLTENVK-LICENSE.txt`.

## Laya

O modo de otimização automática usa `@receptron/laya` 0.1.2 (MIT) e o modelo Laya da Convai Innovations (Apache 2.0). Os pesos do modelo não são incluídos no DMG: são baixados no primeiro uso e armazenados no diretório de dados do BottleForge.

## Node.js e ONNX Runtime

O runtime local do Laya inclui Node.js arm64 e ONNX Runtime Node para inferência local. Os avisos e licenças distribuídos pelos respectivos pacotes acompanham o runtime empacotado.

Outras bibliotecas transitivas incluídas pela distribuição Wine ou pelo runtime Laya mantêm seus respectivos direitos e licenças upstream. Este projeto não reivindica autoria desses componentes.
