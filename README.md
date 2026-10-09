# CloudStart Commerce V7

Frontend estático e profissional para prototipação do CloudStart.

## Objetivo

Demonstrar uma jornada de e-commerce B2B para infraestrutura de TI, inspirada em padrões comuns de grandes lojas online: busca global, navegação por categorias, filtros, favoritos, quick view, carrinho lateral, checkout dedicado, conta e confirmação de pedido.

## Estrutura

- `index.html` — vitrine e catálogo.
- `checkout.html` — checkout completo.
- `confirmation.html` — confirmação do pedido demonstrativo.
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
- Busca e filtros por categoria.
- Ordenação por preço e nome.
- Favoritos.
- Quick view dos produtos.
- Calculadora de infraestrutura.
- Recomendações por porte.
- Login, cadastro e botão Google demonstrativos.
- Fallback local para imagens externas que não carregarem.
- Estrutura preparada para integração com backend.

## Como executar

Abra `index.html` diretamente no navegador. Não precisa de Node.js, npm ou servidor local.

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

Preços e pedidos desta versão são demonstrativos. Nenhum pagamento real é processado.
