# Backend Integration — CloudStart Commerce V7

O frontend não possui fluxo de pagamento nem autenticação real.

## Pontos de integração

### Auth
Substituir o comportamento demonstrativo de `auth.js` por chamadas HTTPS ao serviço de autenticação.

### Produtos
Mover o catálogo de `store.js` para `GET /api/products`.

### Carrinho
O carrinho atual usa `localStorage` apenas para prototipação. Em produção, o servidor deve recalcular preços e disponibilidade.

### Google
O botão atual é apenas demonstrativo. Implementar OAuth/OpenID Connect no backend e validar o token no servidor.

### Segurança
Nunca confiar em preço, desconto ou estoque vindos do navegador.


## Comportamentos demonstrativos adicionados no V8

- Busca, filtros, favoritos e comparador usam dados locais do catálogo.
- O orçamento é preparado no navegador e impresso/salvo em PDF; não é uma proposta comercial assinada.
- Login, cadastro e Google são demonstrativos; o site gera apenas orçamentos locais.
- Dados do carrinho, tema e favoritos ficam no `localStorage`; não armazenar dados sensíveis ali.
