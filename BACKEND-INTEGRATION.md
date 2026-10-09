# Backend Integration — CloudStart Commerce V7

O frontend não executa pagamentos reais nem autenticação real.

## Pontos de integração

### Auth
Substituir o comportamento demonstrativo de `auth.js` por chamadas HTTPS ao serviço de autenticação.

### Produtos
Mover o catálogo de `store.js` para `GET /api/products`.

### Carrinho
O carrinho atual usa `localStorage` apenas para prototipação. Em produção, o servidor deve recalcular preços e disponibilidade.

### Checkout
`checkout.js` monta a intenção do pedido no cliente. Em produção:

1. Enviar itens e identificador do cliente ao backend.
2. Recalcular preços no servidor.
3. Criar intenção de pagamento no gateway.
4. Receber somente tokens/status do gateway.
5. Nunca persistir CVV ou número completo do cartão.

### Google
O botão atual é apenas demonstrativo. Implementar OAuth/OpenID Connect no backend e validar o token no servidor.

### Segurança
Nunca confiar em preço, desconto, estoque ou status de pagamento vindos do navegador.
