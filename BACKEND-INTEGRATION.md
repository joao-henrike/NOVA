# Integração futura com Backend

O frontend foi desenhado para enviar um pedido para:

`POST /api/orders`

Exemplo conceitual:

```json
{
  "items": [
    {
      "productId": "server-r550",
      "quantity": 1
    }
  ],
  "companySize": "medium",
  "payment": {
    "method": "pix"
  },
  "customer": {
    "name": "Cliente",
    "email": "cliente@empresa.com"
  }
}
```

## Regra importante

Não confie no preço enviado pelo frontend.

O backend deve consultar o produto pelo `productId`, obter o preço oficial e recalcular tudo:

`subtotal -> desconto -> impostos/frete -> total`

O frontend serve como interface e experiência do usuário.

## Pagamento

Para produção, use um gateway como Stripe, Mercado Pago, Pagar.me ou Adyen.

O fluxo recomendado é:

1. Frontend cria pedido.
2. Backend valida itens.
3. Backend cria cobrança no gateway.
4. Gateway retorna dados necessários para o checkout.
5. Usuário conclui o pagamento.
6. Gateway chama webhook do backend.
7. Backend valida a assinatura do webhook.
8. Pedido muda para `paid`, `failed`, `cancelled` etc.

Nunca implemente armazenamento próprio de número de cartão ou CVV.
