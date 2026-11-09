# CloudStart Commerce V8 — Front-end aprimorado

Frontend estático e profissional para prototipação do CloudStart.

## Objetivo

Demonstrar uma jornada de e-commerce B2B para infraestrutura de TI, inspirada em padrões comuns de grandes lojas online: busca global, navegação por categorias, filtros, favoritos, quick view, carrinho lateral, checkout dedicado, conta e confirmação de pedido.

## Estrutura

- `index.html` — vitrine e catálogo.
- `checkout.html` — checkout completo.
- `confirmation.html` — confirmação do pedido demonstrativo.
- `quote.html` / `quote.js` — orçamento com impressão ou salvamento em PDF via navegador.
- `login.html` / `register.html` — autenticação demonstrativa.
- `store.js` — catálogo, carrinho, tema e favoritos.
- `app.js` — comportamento da loja.
- `checkout.js` — comportamento do checkout.
- `auth.js` — login/cadastro/Google demonstrativos.
- `assets/images/` — imagens locais de fallback.

## Funcionalidades

- Carrinho lateral com abertura/fechamento confiável.
- Quantidade, remoção e subtotal.
- Persistência do carrinho via `localStorage`.
- Checkout dedicado.
- Pix, crédito, débito e boleto.
- Tema claro/escuro em todas as telas.
- Busca textual combinada com categoria, faixa de preço, favoritos e ordenação.
- Comparador de até três equipamentos com tabela de especificações.
- Filtro para exibir somente favoritos.
- Estados vazios, skeletons de carregamento e mensagens de feedback.
- Favoritos.
- Quick view dos produtos.
- Calculadora de infraestrutura com limites de entrada.
- Geração de orçamento imprimível / salvar como PDF pelo navegador.
- Menu de categorias responsivo e atalho Ctrl/Cmd + K para a busca.
- Validação demonstrativa de cadastro, confirmação de senha e campos de cartão.
- Checkout condicional por método de pagamento; dados completos de cartão não são gravados no localStorage.
- Recomendações por porte.
- Login, cadastro e botão Google demonstrativos.
- Fallback local para imagens externas que não carregarem.
- Estrutura preparada para integração com backend.

## Como executar

Abra `index.html` diretamente no navegador. Não precisa de Node.js, npm ou servidor local.

O PDF é gerado usando a função de impressão do navegador: clique em “Salvar como PDF / Imprimir” e escolha “Salvar como PDF”. Não há biblioteca externa.

As fotos de fabricantes/editoriais são carregadas por URL quando houver internet. Se uma URL não responder, o produto troca automaticamente para uma imagem local de fallback, evitando cards quebrados.

## Integração futura

Sugestões de endpoints:

- `POST /api/auth/login`
- `POST /api/auth/register`
- `POST /api/auth/google`
- `GET /api/products`
- `GET /api/products/:id`
- `POST /api/orders`
- `POST /api/payments/intents`
- `POST /api/quotes`

## Catálogo e política de preços

O catálogo utiliza modelos identificáveis de Dell, HPE, Cisco, Fortinet e MikroTik, além de serviços CloudStart e itens Ubiquiti. Os valores são estimativas em reais para demonstração comercial, não cotações nem ofertas vinculantes. Configuração (CPU, RAM, discos, PoE, licenças), garantia, impostos, frete, estoque, câmbio e canal de distribuição podem alterar o preço final. A equipe comercial deve validar disponibilidade e preço antes de qualquer pedido.

Referências públicas consultadas em novembro de 2026:

- Cisco Catalyst 9200: Xtech — https://xtech.com.br/Switch-Cisco-Catalyst-9200-24-Port-Data-Only-C9200-24t-E/p/52915/ e FoxTI — https://www.foxti.com.br/collections/pecas-cisco-catalyst-9200
- Servidores HPE / Dell: TI24h — https://www.ti24h.com.br/ e InforPró — https://www.inforpro.com.br/produtos/servidores
- MikroTik CRS326-24G-2S+RM: fabricante — https://mikrotik.com/product/CRS326-24G-2SplusRM (preço sugerido oficial em dólar, convertido apenas como referência)
- FortiGate 60F: valores estimados para appliance; licenças FortiGuard/FortiCare devem ser cotadas separadamente.

As fotografias são carregadas de endereços públicos de fabricantes/revendedores e exigem conexão com a internet. Se uma imagem externa falhar, o catálogo utiliza o SVG local correspondente.

Preços e pedidos desta versão são demonstrativos. Nenhum pagamento real é processado.
